'use strict';

/**
 * 打印代理自更新：按环境 COS 清单轮询；仅比对版本。
 * 用户确认后才下载安装包并拉起安装程序。
 */
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const POLL_MS = 10 * 60 * 1000;
const COS_HOST = 'lvpai-1454232822.cos.ap-guangzhou.myqcloud.com';

function resolveChannel(rootDir) {
  const override = String(process.env.LVPAI_UPDATE_MANIFEST_URL || '').trim();
  if (override) {
    return { env: 'override', manifestUrl: override };
  }
  const envName = String(process.env.LVPAI_UPDATE_ENV || '').trim().toLowerCase();
  if (envName === 'local' || envName === 'test' || envName === 'prd') {
    return {
      env: envName,
      manifestUrl: `https://${COS_HOST}/print-desktop/${envName}/latest.json`,
    };
  }
  const channelPath = path.join(rootDir, 'electron', 'update-channel.json');
  if (fs.existsSync(channelPath)) {
    const raw = JSON.parse(fs.readFileSync(channelPath, 'utf8'));
    const env = String(raw.env || '').trim().toLowerCase() || 'local';
    const manifestUrl = String(raw.manifestUrl || '').trim()
      || `https://${COS_HOST}/print-desktop/${env}/latest.json`;
    return { env, manifestUrl };
  }
  return {
    env: 'local',
    manifestUrl: `https://${COS_HOST}/print-desktop/local/latest.json`,
  };
}

function readLocalVersion(rootDir) {
  const pkg = JSON.parse(fs.readFileSync(path.join(rootDir, 'package.json'), 'utf8'));
  const versionName = String(pkg.version || '').trim();
  const versionCode = Number(pkg.versionCode);
  if (!Number.isInteger(versionCode) || versionCode < 1) {
    throw new Error('package.json 缺少合法 versionCode');
  }
  if (!versionName) {
    throw new Error('package.json 缺少 version');
  }
  return { versionCode, versionName };
}

function requireHttps(url) {
  if (!String(url).toLowerCase().startsWith('https://')) {
    throw new Error('更新地址必须使用 HTTPS');
  }
}

function fetchBuffer(url, { maxBytes = 64 * 1024, onProgress } = {}) {
  requireHttps(url);
  return new Promise((resolve, reject) => {
    const lib = url.startsWith('https://') ? https : http;
    const req = lib.get(url, { headers: { 'Cache-Control': 'no-store' } }, (res) => {
      if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        fetchBuffer(res.headers.location, { maxBytes, onProgress }).then(resolve, reject);
        return;
      }
      if (res.statusCode !== 200) {
        res.resume();
        reject(new Error(`HTTP ${res.statusCode}`));
        return;
      }
      const total = Number(res.headers['content-length'] || 0);
      const chunks = [];
      let size = 0;
      res.on('data', (chunk) => {
        size += chunk.length;
        if (size > maxBytes) {
          req.destroy();
          reject(new Error('响应过大'));
          return;
        }
        chunks.push(chunk);
        if (typeof onProgress === 'function' && total > 0) {
          onProgress(size, total);
        }
      });
      res.on('end', () => resolve({ buffer: Buffer.concat(chunks), total }));
      res.on('error', reject);
    });
    req.setTimeout(60000, () => {
      req.destroy();
      reject(new Error('请求超时'));
    });
    req.on('error', reject);
  });
}

/**
 * 从清单 URL 推断环境；推断不出则返回空串（调用方应显式失败，不静默兜底）。
 */
function envFromManifestUrl(manifestUrl) {
  const text = String(manifestUrl || '');
  const matched = text.match(/\/print-desktop\/(local|test|prd)\//i);
  return matched ? matched[1].toLowerCase() : '';
}

/**
 * installerUrl 必须落在对应环境目录：…/print-desktop/{local|test|prd}/…
 * @param {string} installerUrl
 * @param {string} env
 */
function requireInstallerUrlForEnv(installerUrl, env) {
  requireHttps(installerUrl);
  const normalized = String(env || '').trim().toLowerCase();
  if (!['local', 'test', 'prd'].includes(normalized)) {
    throw new Error('更新通道环境无效，无法校验 installerUrl');
  }
  let pathname = '';
  try {
    pathname = new URL(installerUrl).pathname || '';
  } catch {
    throw new Error('installerUrl 无效');
  }
  const marker = `/print-desktop/${normalized}/`;
  if (!pathname.toLowerCase().includes(marker)) {
    throw new Error(`installerUrl 必须位于 print-desktop/${normalized}/ 目录下`);
  }
}

/**
 * @param {string} text
 * @param {{ env?: string, manifestUrl?: string }} [options]
 */
function parseManifest(text, options = {}) {
  const body = JSON.parse(text);
  const versionCode = Number(body.versionCode);
  const versionName = String(body.versionName || '').trim();
  const installerUrl = String(body.installerUrl || body.apkUrl || '').trim();
  const sha256 = String(body.sha256 || '').trim().toLowerCase();
  if (!Number.isInteger(versionCode) || versionCode < 1) {
    throw new Error('清单缺少合法 versionCode');
  }
  if (!versionName || versionName.length > 32) {
    throw new Error('清单 versionName 无效');
  }
  if (!installerUrl) {
    throw new Error('清单缺少 installerUrl');
  }
  if (!/^[0-9a-f]{64}$/.test(sha256)) {
    throw new Error('清单 sha256 无效');
  }
  let env = String(options.env || '').trim().toLowerCase();
  if (!['local', 'test', 'prd'].includes(env)) {
    env = envFromManifestUrl(options.manifestUrl || '');
  }
  requireInstallerUrlForEnv(installerUrl, env);
  return { versionCode, versionName, installerUrl, sha256, env };
}

function sha256Of(filePath) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(filePath));
  return hash.digest('hex');
}

/**
 * @param {object} options
 * @param {string} options.rootDir
 * @param {(state:object)=>void} [options.onChange]
 * @param {(msg:string, level?:string)=>void} [options.log]
 */
function createAppUpdater(options) {
  const rootDir = options.rootDir;
  const channel = resolveChannel(rootDir);
  const local = readLocalVersion(rootDir);
  let timer = null;
  let busy = false;
  let remoteManifest = null;
  let state = {
    phase: 'IDLE',
    percent: 0,
    message: '',
    env: channel.env,
    manifestUrl: channel.manifestUrl,
    currentVersionCode: local.versionCode,
    currentVersionName: local.versionName,
    latestVersionCode: 0,
    latestVersionName: '',
    updateAvailable: false,
    unread: false,
    lastCheckAt: null,
    lastCheckError: '',
    configured: Boolean(channel.manifestUrl),
  };

  function emit() {
    if (typeof options.onChange === 'function') options.onChange(snapshot());
  }

  function log(message, level) {
    if (typeof options.log === 'function') options.log(message, level || 'info');
  }

  function snapshot() {
    return { ...state };
  }

  function setState(patch) {
    state = { ...state, ...patch };
    emit();
  }

  async function check({ manual = false } = {}) {
    if (busy) return snapshot();
    if (!channel.manifestUrl) {
      setState({
        phase: 'ERROR',
        message: '尚未配置更新通道',
        lastCheckError: '尚未配置更新通道',
        lastCheckAt: new Date().toISOString(),
      });
      return snapshot();
    }
    busy = true;
    setState({
      phase: 'CHECKING',
      percent: 0,
      message: manual ? '正在手动检查更新…' : '正在检查更新…',
      lastCheckError: '',
    });
    try {
      const { buffer } = await fetchBuffer(channel.manifestUrl, { maxBytes: 64 * 1024 });
      const remote = parseManifest(buffer.toString('utf8'), {
        env: channel.env,
        manifestUrl: channel.manifestUrl,
      });
      const available = remote.versionCode > local.versionCode;
      remoteManifest = available ? remote : null;
      const becameAvailable = available
        && (!state.updateAvailable || state.latestVersionCode !== remote.versionCode);
      setState({
        phase: available ? 'AVAILABLE' : 'UPTODATE',
        percent: 100,
        message: available
          ? `发现新版本 v${remote.versionName}`
          : '已是最新版本',
        latestVersionCode: remote.versionCode,
        latestVersionName: remote.versionName,
        updateAvailable: available,
        unread: available ? (becameAvailable || state.unread || manual) : false,
        lastCheckAt: new Date().toISOString(),
        lastCheckError: '',
      });
      log(available
        ? `发现打印代理新版本 ${remote.versionName}（${remote.versionCode}）`
        : '打印代理已是最新版本');
      return snapshot();
    } catch (error) {
      const text = error && error.message ? error.message : String(error);
      setState({
        phase: 'ERROR',
        message: `检查更新失败：${text}`,
        lastCheckError: text,
        lastCheckAt: new Date().toISOString(),
      });
      log(`检查打印代理更新失败：${text}`, 'warn');
      return snapshot();
    } finally {
      busy = false;
      emit();
    }
  }

  async function applyUpdate() {
    if (busy) return snapshot();
    if (!remoteManifest || !state.updateAvailable) {
      await check({ manual: true });
    }
    const target = remoteManifest;
    if (!target || !(target.versionCode > local.versionCode)) {
      setState({
        phase: state.lastCheckError ? 'ERROR' : 'UPTODATE',
        message: state.lastCheckError
          ? `检查更新失败：${state.lastCheckError}`
          : '已是最新版本',
        unread: false,
      });
      return snapshot();
    }
    busy = true;
    setState({
      phase: 'DOWNLOADING',
      percent: 0,
      message: `正在下载 v${target.versionName}…`,
      unread: false,
    });
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lvpai-print-update-'));
    const ext = path.extname(new URL(target.installerUrl).pathname) || (
      process.platform === 'darwin' ? '.dmg' : '.exe'
    );
    const filePath = path.join(tmpDir, `lvpai-print-desktop-setup${ext}`);
    try {
      const { buffer } = await fetchBuffer(target.installerUrl, {
        maxBytes: 500 * 1024 * 1024,
        onProgress(downloaded, total) {
          const percent = total > 0 ? Math.min(100, Math.floor((downloaded * 100) / total)) : 0;
          setState({
            phase: 'DOWNLOADING',
            percent,
            message: `正在下载 v${target.versionName}… ${percent}%`,
          });
        },
      });
      fs.writeFileSync(filePath, buffer);
      setState({ phase: 'VERIFYING', percent: 100, message: '正在校验安装包…' });
      if (sha256Of(filePath) !== target.sha256) {
        fs.rmSync(tmpDir, { recursive: true, force: true });
        setState({
          phase: 'ERROR',
          message: '安装包校验不通过，已取消更新',
          lastCheckError: '安装包校验不通过',
        });
        return snapshot();
      }
      setState({
        phase: 'INSTALLING',
        percent: 100,
        message: '正在打开安装程序，请按提示完成更新…',
      });
      if (process.platform === 'win32') {
        spawn(filePath, [], { detached: true, stdio: 'ignore' }).unref();
      } else if (process.platform === 'darwin') {
        spawn('open', [filePath], { detached: true, stdio: 'ignore' }).unref();
      } else {
        throw new Error('当前系统暂不支持自动打开安装包');
      }
      log(`已拉起安装包 ${filePath}`);
      return snapshot();
    } catch (error) {
      const text = error && error.message ? error.message : String(error);
      setState({
        phase: 'ERROR',
        message: `更新失败：${text}`,
        lastCheckError: text,
      });
      log(`打印代理更新失败：${text}`, 'warn');
      return snapshot();
    } finally {
      busy = false;
      emit();
    }
  }

  function markRead() {
    setState({ unread: false });
    return snapshot();
  }

  function start() {
    check({ manual: false }).catch(() => {});
    timer = setInterval(() => {
      check({ manual: false }).catch(() => {});
    }, POLL_MS);
    if (typeof timer.unref === 'function') timer.unref();
  }

  function stop() {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  }

  return {
    snapshot,
    check,
    applyUpdate,
    markRead,
    start,
    stop,
    pollMs: POLL_MS,
  };
}

module.exports = {
  POLL_MS,
  createAppUpdater,
  resolveChannel,
  parseManifest,
  readLocalVersion,
  requireInstallerUrlForEnv,
  envFromManifestUrl,
};
