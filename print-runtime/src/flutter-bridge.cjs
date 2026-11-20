'use strict';

/** Flutter 私有 stdio 桥：不开放端口，复用现有打印内核及结果恢复协议。 */
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { createRuntime } = require('./runtime');
const { normalizeConfig, saveConfig, DEFAULT_OPERATION_BASE } = require('./config');
const { fetchMe } = require('./api');

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
    const { stdout } = await execute('/usr/bin/lpstat', ['-e'], { timeout: 20000 });
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
  async function boot() {
    bridge = await createRuntime({ configPath,
      lockDir: path.join(path.dirname(configPath), '.runtime'), skipLock: true,
      forceManualStart: true, onStateChange: emit });
    // 每次启动均须现场主动开启自动打印，避免重启即出纸。
    bridge.start();
  }
  if (fs.existsSync(configPath)) await boot();
  const read = readline.createInterface({ input, crlfDelay: Infinity });
  const mutations = new Set(['configure', 'saveConfig', 'autoPrint', 'printJobs', 'continueJobs',
    'markUnprinted', 'confirmPrinted', 'queryJobs', 'refreshJobs', 'trialPrintItem', 'downloadJobZip',
    'addScenicProfile', 'activateScenicProfile', 'deleteScenicProfile', 'updateScenicProfile']);
  async function dispatch(method, args) {
    if (method === 'snapshot') return snapshot();
    if (method === 'listPrinters') return listPrinters();
    // 仅本机界面显式索取；不进常规 snapshot，避免日志/状态页带出明文。
    if (method === 'revealToken') {
      if (!bridge) throw new Error('请先验证景区打印密钥');
      return { token: String(bridge.runtime.getConfig().token || '') };
    }
    if (method === 'revealScenicProfileToken') {
      if (!bridge) throw new Error('请先验证景区打印密钥');
      const id = String(args[0]?.id || '').trim();
      const profile = (bridge.runtime.getConfig().scenicProfiles || [])
        .find((p) => p.id === id);
      if (!profile) throw new Error('景区档案不存在');
      return { token: String(profile.token || '') };
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
    if (method === 'configure') {
      if (bridge) throw new Error('已配置，请使用设置保存');
      const token = String(args[0]?.token || '').trim();
      if (!token) throw new Error('请输入景区打印密钥');
      const raw = JSON.parse(fs.readFileSync(path.join(root,
        process.platform === 'darwin' ? 'config.mac.example.json' : 'config.example.json'), 'utf8'));
      const meProbe = normalizeConfig({ ...raw, base: process.env.PRINT_AGENT_BASE || DEFAULT_OPERATION_BASE,
        token, scenicIds: ['0'], printers: {}, autoPrint: false,
        lockDir: path.join(path.dirname(configPath), '.runtime') },
      { configPath, scriptDir: path.join(root, 'scripts') });
      const me = await fetchMe(meProbe);
      if (!me?.scenicId) throw new Error('密钥校验失败：缺少景区信息');
      const scenicIds = (me.scenicIds?.length ? me.scenicIds : [me.scenicId]).map(String);
      const scenicName = me.scenicName || '';
      const scenicCode = me.scenicCode || '';
      const config = normalizeConfig({
        ...raw,
        base: process.env.PRINT_AGENT_BASE || DEFAULT_OPERATION_BASE,
        token,
        scenicIds,
        scenicName,
        scenicCode,
        scenicProfiles: [{ id: 'default', token, scenicIds, scenicName, scenicCode }],
        activeScenicProfileId: 'default',
        printers: {},
        autoPrint: false,
        lockDir: path.join(path.dirname(configPath), '.runtime'),
      }, { configPath, scriptDir: path.join(root, 'scripts') });
      fs.mkdirSync(path.dirname(configPath), { recursive: true });
      saveConfig(config);
      await boot();
      return snapshot();
    }
    if (!bridge) throw new Error('请先验证景区打印密钥');
    if (method === 'saveConfig') {
      await bridge.applyConfigPatch(args[0]);
      return snapshot();
    }
    if (method === 'addScenicProfile') return bridge.addScenicProfile(args[0] || {});
    if (method === 'activateScenicProfile') return bridge.activateScenicProfile(args[0] || {});
    if (method === 'deleteScenicProfile') return bridge.deleteScenicProfile(args[0] || {});
    if (method === 'updateScenicProfile') return bridge.updateScenicProfile(args[0] || {});
    if (method === 'autoPrint') return bridge.setAutoPrint(Boolean(args[0]));
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
      send({ id: request?.id ?? null, error: error.message });
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
