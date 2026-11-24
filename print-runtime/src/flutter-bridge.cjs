'use strict';

/** Flutter 私有 stdio 桥：不开放端口，复用现有打印内核及结果恢复协议。 */
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { createRuntime } = require('./runtime');
const { normalizeConfig, saveConfig, DEFAULT_OPERATION_BASE } = require('./config');
const { fetchMe, listBatchStations, listPhotoBatches, correctPhotoBatch, removeBatchPhoto,
  getBatchPhotoCapture, sendCrashReport } = require('./api');
const { CUPS_SOCKET } = require('./mac-printer');

const execute = promisify(execFile);

/** 查询真实系统打印机；失败显式上报，不返回假列表。 */
async function listPrinters() {
  if (process.platform === 'win32') {
    const { stdout } = await execute('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
      "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new(); @(Get-Printer -ErrorAction Stop | Select-Object -ExpandProperty Name) | ConvertTo-Json -Compress"],
    { windowsHide: true, encoding: 'utf8', timeout: 20000 });
    const result = JSON.parse(stdout.trim() || '[]');
    return typeof result === 'string' ? [result] : result;
  }
  if (process.platform === 'darwin') {
    const { stdout } = await execute('/usr/bin/lpstat', ['-e'], {
      timeout: 20000, env: { ...process.env, CUPS_SERVER: CUPS_SOCKET },
    });
    return stdout.split(/\r?\n/).map((name) => name.trim()).filter(Boolean);
  }
  throw new Error('当前仅支持 Windows / macOS 打印机');
}

/** 同一时刻只执行一个业务变更；查询快照不被长时间打印阻塞。 */
async function serve({ input = process.stdin, send, configPath, root }) {
  if (!configPath) throw new Error('缺少独立配置路径 PRINT_AGENT_CONFIG');
  // 首次配置也持锁，避免两个未配置窗口同时校验并覆盖同一配置。
  const lock = require('./single-instance').acquireLock(path.join(path.dirname(configPath), '.runtime'));
  let bridge;
  let mutating = false;
  let closing = false;
  const snapshot = () => bridge ? { ...bridge.snapshot(), configured: true } : {
    configured: false, config: {}, state: {}, logs: [], history: [],
  };
  const emit = () => send({ event: 'snapshot', data: snapshot() });
  const credentials = new Map();
  const authorizedBase = process.env.PRINT_AGENT_BASE || DEFAULT_OPERATION_BASE;
  let initialized = false;
  const stored = () => fs.existsSync(configPath) ? JSON.parse(fs.readFileSync(configPath, 'utf8')) : {};
  const stripCredentials = ({ token, ...payload }) => ({
    ...payload,
    scenicProfiles: payload.scenicProfiles.map(({ token: secret, ...profile }) => profile),
  });
  const authorizedProfiles = raw => (raw.scenicProfiles || [])
    .filter(profile => credentials.has(profile.id))
    .map(profile => ({ ...profile, token: credentials.get(profile.id) }));
  async function boot() {
    bridge = await createRuntime({ configPath,
      lockDir: path.join(path.dirname(configPath), '.runtime'), skipLock: true,
      transformSavedConfig: stripCredentials,
      transformRaw(raw) {
        const profiles = authorizedProfiles(raw);
        return { ...raw, base: authorizedBase, token: profiles[0].token, scenicProfiles: profiles };
      },
      forceManualStart: true, includePrintIssues: true, onStateChange: emit });
    bridge.start();
  }
  const read = readline.createInterface({ input, crlfDelay: Infinity });
  const mutations = new Set(['initialize', 'installPrintAuthorization', 'saveConfig', 'autoPrint', 'printJobs', 'continueJobs',
    'markUnprinted', 'confirmPrinted', 'recoverPrintJob', 'queryJobs', 'refreshJobs', 'trialPrintItem', 'downloadJobZip',
    'activateScenicProfile', 'deleteScenicProfile',
    'correctPhotoBatch', 'removeBatchPhoto']);
  function batchConfig(scope) {
    const config = bridge.runtime.getConfig();
    if (scope === undefined) return config;
    const profile = config.scenicProfiles.find((entry) => entry.id === scope?.profileId);
    if (!profile || (scope.scenicId && !profile.scenicIds.includes(scope.scenicId))) {
      throw new Error('机位所属景区的打印档案已变更，请重新打开取片批次');
    }
    return { ...config, token: profile.token };
  }

  async function dispatch(method, args) {
    if (method === 'snapshot') return snapshot();
    if (method === 'listPrinters') return listPrinters();
    if (method === 'initialize') {
      if (initialized) return snapshot();
      for (const [id, token] of Object.entries(args[0] || {})) {
        if (/^[a-f0-9-]{36}$/.test(id) && /^[a-f0-9]{64}$/.test(token)) credentials.set(id, token);
      }
      if (authorizedProfiles(stored()).length) await boot();
      initialized = true;
      return snapshot();
    }
    if (method === 'printerStatus') {
      if (!bridge) throw new Error('请先连接景区');
      if (!bridge.runtime.getConfig().statusCommand) throw new Error('当前平台未配置打印机状态观察');
      return require('./printer-status').probePrinter(bridge.runtime.getConfig(), String(args[0]));
    }
    if (method === 'printerPreferences') {
      if (process.platform !== 'win32') throw new Error('请在系统打印设置中调整打印机偏好');
      const printer = String(args[0] || '');
      if (!(await listPrinters()).includes(printer)) throw new Error('打印机未安装');
      const child = require('node:child_process').spawn('rundll32.exe',
        ['printui.dll,PrintUIEntry', '/e', '/n', printer], { windowsHide: false, stdio: 'ignore' });
      await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
      return { opened: true };
    }
    if (method === 'shutdown') {
      closing = true;
      if (bridge) bridge.stop();
      lock.release();
      read.close();
      return { stopped: true };
    }
    if (method === 'installPrintAuthorization') {
      if (!initialized) throw new Error('打印内核尚未初始化');
      const { id, token, scenicId } = args[0] || {};
      if (!/^[a-f0-9-]{36}$/.test(id) || !/^[a-f0-9]{64}$/.test(token)) {
        throw new Error('打印设备凭据无效');
      }
      if (bridge) {
        const result = await bridge.addScenicProfile({ id, token, scenicId });
        credentials.set(id, token);
        return result;
      }
      const defaults = JSON.parse(fs.readFileSync(path.join(root,
        process.platform === 'darwin' ? 'config.mac.example.json' : 'config.example.json'), 'utf8'));
      const me = await fetchMe({ base: authorizedBase, token });
      if (!me?.scenicId || String(me.scenicId) !== scenicId) throw new Error('打印授权景区不一致');
      const profile = { id, token, scenicIds: [scenicId], scenicName: me.scenicName, scenicCode: me.scenicCode };
      const config = normalizeConfig({
        ...defaults, printers: {}, ...stored(), ...profile, base: authorizedBase, scenicProfiles: [profile],
        activeScenicProfileId: id, autoPrint: false,
        lockDir: path.join(path.dirname(configPath), '.runtime'),
      }, { configPath, scriptDir: path.join(root, 'scripts') });
      credentials.set(id, token);
      saveConfig(config, configPath, stripCredentials);
      await boot();
      return snapshot();
    }
    if (!bridge) throw new Error('请先申请打印权限');
    if (method === 'recoveryDetails') return bridge.scheduler.recoveryDetails(args[0]);
    if (method === 'recoverPrintJob') {
      await bridge.scheduler.recoverPrintJob(args[0], args[1]);
      return snapshot();
    }
    if (method === 'sendCrashReport') return sendCrashReport(batchConfig(), args[0]);
    if (method === 'listBatchStations') return listBatchStations(batchConfig(args[0]));
    if (method === 'listPhotoBatches') return listPhotoBatches(batchConfig(args[1]), args[0]);
    if (method === 'correctPhotoBatch') return correctPhotoBatch(batchConfig(args[2]), args[0], args[1]);
    if (method === 'removeBatchPhoto') return removeBatchPhoto(batchConfig(args[3]), args[0], args[1], args[2]);
    if (method === 'getBatchPhotoCapture') return getBatchPhotoCapture(batchConfig(args[2]), args[0], args[1]);
    if (method === 'saveConfig') {
      const { printers, printDpi } = args[0] || {};
      await bridge.applyConfigPatch({ printers, printDpi });
      return snapshot();
    }
    if (method === 'activateScenicProfile') return bridge.activateScenicProfile(args[0] || {});
    if (method === 'deleteScenicProfile') return bridge.deleteScenicProfile(args[0] || {});
    if (method === 'autoPrint') {
      const enabled = Boolean(args[0]);
      const config = bridge.runtime.getConfig();
      if (enabled && !config.skipPrint && !Object.values(config.printers).some(Boolean)
          && !config.allowDefaultPrinter) {
        throw new Error('请先在打印设置中选择并保存本机打印机');
      }
      return bridge.setAutoPrint(enabled);
    }
    const methods = new Set(['printJobs', 'continueJobs', 'markUnprinted', 'confirmPrinted', 'queryJobs',
      'refreshJobs', 'previewJob', 'previewJobImage', 'trialPrintItem', 'downloadJobZip']);
    if (!methods.has(method)) throw new Error('不支持的操作');
    return bridge[method](...args);
  }
  read.on('line', async (line) => {
    let request;
    let ownsMutation = false;
    try {
      request = JSON.parse(line);
      if (!Number.isSafeInteger(request.id) || typeof request.method !== 'string'
          || !Array.isArray(request.args)) throw new Error('请求格式无效');
      if (closing) throw new Error('代理正在退出');
      const mutation = mutations.has(request.method) || request.method === 'shutdown';
      if (mutation && (mutating || bridge?.scheduler.getState().printBusy)) {
        throw new Error('任务处理中，请等待完成；不能中断或重复送打');
      }
      if (mutation) { mutating = true; ownsMutation = true; }
      const data = await dispatch(request.method, request.args);
      send({ id: request.id, data });
      if (closing) process.exitCode = 0;
    } catch (error) {
      send({ id: request?.id ?? null, error: error.message,
        ...(request?.method === 'correctPhotoBatch' && Number.isInteger(error.resultCode)
          ? { resultCode: error.resultCode } : {}) });
    } finally {
      if (ownsMutation) mutating = false;
    }
  });
  read.on('close', () => {
    // UI 异常退出时，停止接新单；已送打任务完成回写后才释放锁。
    if (bridge) bridge.scheduler.stop();
    const finish = () => {
      if (mutating || bridge?.scheduler.getState().printBusy) return setTimeout(finish, 250);
      if (bridge) bridge.stop();
      lock.release();
    };
    finish();
  });
  emit();
  return { snapshot };
}

if (require.main === module) {
  let outputClosed = false;
  // Flutter 意外退出会关闭 stdout。EPIPE 不能终止正在执行的送打/回写。
  process.stdout.on('error', (error) => {
    if (error.code === 'EPIPE' || error.code === 'ERR_STREAM_DESTROYED') outputClosed = true;
    else { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
  });
  serve({ configPath: process.env.PRINT_AGENT_CONFIG, root: path.resolve(__dirname, '..'),
    send: (message) => { if (!outputClosed) process.stdout.write(`${JSON.stringify(message)}\n`); } })
    .catch((error) => {
      if (error.code === 'ELOCKED') {
        process.stdout.write(`${JSON.stringify({ event: 'startupError', code: error.code })}\n`);
      } else {
        process.stderr.write(`${error.message}\n`);
      }
      process.exitCode = 1;
    });
}
module.exports = { serve, listPrinters };
