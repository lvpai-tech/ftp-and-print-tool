'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { appRoot } = require('./paths');
const { usesMacPrintScript } = require('./mac-printer');

const ROOT = appRoot();
const DEFAULT_CONFIG_PATH = path.join(ROOT, 'config.json');
const EXAMPLE_CONFIG_PATH = path.join(ROOT, 'config.example.json');
/** 正式运营 API 根；界面不展示，本机可用 PRINT_AGENT_BASE 覆盖（联调/测试）。 */
const DEFAULT_OPERATION_BASE = 'https://hilvpai.com/api/operation';
const DEFAULT_PRINT_DPI = 300;

const KIND_KEYS = ['COVER', 'SIZE_6', 'ORIGINAL', 'CREATIVE'];
const MAC_SUPPORT_DIR_NAME = 'lvpai-print-desktop';

/**
 * 已安装的 Mac 应用把配置和单实例锁放在用户目录。
 * 开发态（electron .）和 Windows 仍用应用目录里的 config.json。
 * 这样替换 .app 升级时不会清掉现场填的密钥和打印机。
 */
function macPackagedSupportDir(proc = process) {
  if (!proc || proc.platform !== 'darwin' || proc.defaultApp) return null;
  const resources = proc.resourcesPath ? String(proc.resourcesPath) : '';
  const marker = `${path.sep}Contents${path.sep}Resources`;
  if (!resources.includes(marker)) return null;
  const home = proc.env && proc.env.HOME ? String(proc.env.HOME) : os.homedir();
  if (!home) return null;
  return path.join(home, 'Library', 'Application Support', MAC_SUPPORT_DIR_NAME);
}

function seedMacConfigIfNeeded(configPath, resourcesPath) {
  if (fs.existsSync(configPath)) return;
  const example = path.join(String(resourcesPath || ''), 'app', 'config.example.json');
  if (!fs.existsSync(example)) {
    throw new Error(`找不到配置文件：${configPath}（安装包内也没有示例配置）`);
  }
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.copyFileSync(example, configPath);
}

function asPositiveInt(value, fallback, label) {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 1) {
    if (fallback !== undefined) return fallback;
    throw new Error(`${label}必须是正整数`);
  }
  return Math.floor(n);
}

function asNonNegInt(value, fallback, label) {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 0) {
    if (fallback !== undefined) return fallback;
    throw new Error(`${label}必须是非负整数`);
  }
  return Math.floor(n);
}

function normalizeCommand(command) {
  if (!Array.isArray(command) || command.length === 0 || command.some((part) => typeof part !== 'string')) {
    throw new Error('command必须是非空字符串数组');
  }
  return command.slice();
}

function normalizePrinterSettings(raw) {
  if (raw.printer !== undefined) {
    if (typeof raw.printer !== 'string') throw new Error('printer必须是字符串');
    const printer = raw.printer.trim();
    return { printer, printerSelectionRequired: !printer && raw.printerSelectionRequired === true };
  }

  const printers = raw.printers ?? {};
  if (typeof printers !== 'object' || Array.isArray(printers)) {
    throw new Error('printers必须是对象');
  }
  const names = new Set();
  for (const [key, value] of Object.entries(printers)) {
    if (value == null) continue;
    if (typeof value !== 'string') throw new Error(`printers.${key}必须是字符串`);
    if (value.trim()) names.add(value.trim());
  }
  if (raw.allowDefaultPrinter) {
    const fallback = String(raw.defaultPrinter || '').trim();
    if (!fallback) throw new Error('开启 allowDefaultPrinter 时必须配置 defaultPrinter');
    names.add(fallback);
  }
  return {
    printer: names.size === 1 ? [...names][0] : '',
    printerSelectionRequired: names.size > 1,
  };
}

const WINDOWS_STATUS_COMMAND = [
  'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
  '-File', '{scriptDir}/printer-status.ps1', '-Printer', '{printer}',
];
const MAC_STATUS_COMMAND = ['{node}', '{scriptDir}/../src/mac-printer.js', '{printer}', '{jobId}'];

function normalizeStatusCommand(value, platform, command) {
  // 旧 macOS 档案由安装包写入 null，升级时为随包送打脚本启用状态检查。
  if (value == null && platform === 'darwin' && usesMacPrintScript(command)) {
    return MAC_STATUS_COMMAND.slice();
  }
  if (value === undefined) return platform === 'win32' ? WINDOWS_STATUS_COMMAND.slice() : null;
  if (value === null) return null;
  if (!Array.isArray(value) || value.length === 0 || value.some((part) => typeof part !== 'string')) {
    throw new Error('statusCommand必须是非空字符串数组或null');
  }
  return value.slice();
}

/**
 * 从对象校验并规范化配置（可被文件加载与测试复用）。
 */
function normalizeConfig(raw, options = {}) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new Error('配置必须是JSON对象');
  }
  const base = String(raw.base || DEFAULT_OPERATION_BASE).trim().replace(/\/+$/, '');
  if (!base) throw new Error('缺少 base（运营API根）');
  const token = String(raw.token || '').trim();
  if (!token) throw new Error('缺少 token（景区打印密钥）');

  let scenicIds = raw.scenicIds;
  if (scenicIds == null) scenicIds = [];
  if (typeof scenicIds === 'string') {
    scenicIds = scenicIds.split(',').map((s) => s.trim()).filter(Boolean);
  }
  if (!Array.isArray(scenicIds) || scenicIds.some((id) => id == null || String(id).trim() === '')) {
    throw new Error('scenicIds必须是字符串数组');
  }
  scenicIds = scenicIds.map((id) => String(id).trim());
  let scenicName = raw.scenicName == null ? '' : String(raw.scenicName).trim();
  let scenicCode = raw.scenicCode == null ? '' : String(raw.scenicCode).trim();

  const { scenicProfiles, activeScenicProfileId, active } = normalizeScenicProfiles(
    raw,
    { token, scenicIds, scenicName, scenicCode },
  );
  // 顶层 token/景区字段始终等于当前激活档案，供现有打印/拉单路径使用。
  const activeToken = active.token;
  scenicIds = active.scenicIds;
  scenicName = active.scenicName;
  scenicCode = active.scenicCode;

  const command = normalizeCommand(raw.command);
  const printerSettings = normalizePrinterSettings(raw);
  const printDpi = raw.printDpi === undefined ? DEFAULT_PRINT_DPI : raw.printDpi;
  if (!Number.isInteger(printDpi) || printDpi < 72 || printDpi > 1200) {
    throw new Error('打印分辨率须为 72–1200 DPI 的整数');
  }
  const highPrintQuality = raw.highPrintQuality === undefined ? false : raw.highPrintQuality;
  if (typeof highPrintQuality !== 'boolean') throw new Error('高画质设置无效');
  const skipPrint = raw.skipPrint != null
    ? Boolean(raw.skipPrint)
    : /^(1|true|yes)$/i.test(String(process.env.PRINT_DESKTOP_SKIP_PRINT || ''));

  const scriptDir = options.scriptDir || path.join(ROOT, 'scripts');
  const configPath = options.configPath || null;
  const statusHost = String(raw.statusHost || '127.0.0.1').trim() || '127.0.0.1';
  if (statusHost !== '127.0.0.1' && statusHost !== 'localhost') {
    throw new Error(`状态页仅允许绑定 127.0.0.1（当前：${statusHost}）`);
  }

  return {
    base,
    token: activeToken,
    scenicIds,
    scenicName,
    scenicCode,
    scenicProfiles,
    activeScenicProfileId,
    pollMs: asPositiveInt(raw.pollMs, 3000, 'pollMs'),
    idleBackoffMs: asPositiveInt(raw.idleBackoffMs, 12000, 'idleBackoffMs'),
    idleThreshold: asPositiveInt(raw.idleThreshold, 3, 'idleThreshold'),
    resultRetries: asPositiveInt(raw.resultRetries, 5, 'resultRetries'),
    /** 自动打印轮询间隔，默认 5 分钟。 */
    autoPrintMs: asPositiveInt(raw.autoPrintMs, 300000, 'autoPrintMs'),
    /** 任务列表自动刷新间隔。 */
    listRefreshMs: asPositiveInt(raw.listRefreshMs, 30000, 'listRefreshMs'),
    statusHost,
    statusPort: asPositiveInt(raw.statusPort, 17888, 'statusPort'),
    ...printerSettings,
    printDpi,
    highPrintQuality,
    command,
    /** 打印机状态命令；null 表示本机不检查缺纸等异常，打印命令受理即报已打印。 */
    statusCommand: normalizeStatusCommand(raw.statusCommand, options.platform || process.platform, command),
    /** 送打后本单作业结束且打印机连续无异常多久才报已打印（整单兜底）。 */
    printerSettleMs: asPositiveInt(raw.printerSettleMs, 30000, 'printerSettleMs'),
    /**
     * 逐张观察的稳定等待；默认不超过 10 秒，避免 9 张任务被 30 秒×N 拖死。
     * 缺省取 min(printerSettleMs, 10000)。
     */
    printerSheetSettleMs: asPositiveInt(
      raw.printerSheetSettleMs,
      Math.min(asPositiveInt(raw.printerSettleMs, 30000, 'printerSettleMs'), 10000),
      'printerSheetSettleMs',
    ),
    /** 送打后最长观察时长，超时报失败待人工核对。 */
    printerWatchMaxMs: asPositiveInt(raw.printerWatchMaxMs, 600000, 'printerWatchMaxMs'),
    printerPollMs: asPositiveInt(raw.printerPollMs, 2000, 'printerPollMs'),
    /** 定时拉未打印并自动出纸；默认关。 */
    autoPrint: Boolean(raw.autoPrint) && (skipPrint || Boolean(printerSettings.printer)),
    /** 验证用：走完整下载/回报，不调本机打印机。配置显式优先于环境变量。 */
    skipPrint,
    historyLimit: asPositiveInt(raw.historyLimit, 20, 'historyLimit'),
    openStatusOnStart: raw.openStatusOnStart !== false,
    notifyOnResult: raw.notifyOnResult !== false,
    lockDir: raw.lockDir ? String(raw.lockDir) : (options.lockDir || path.join(ROOT, '.runtime')),
    scriptDir,
    configPath,
  };
}

function applyEnvOverrides(raw, env = process.env) {
  const next = { ...raw };
  if (env.PRINT_AGENT_BASE) next.base = env.PRINT_AGENT_BASE;
  if (env.PRINT_AGENT_TOKEN) next.token = env.PRINT_AGENT_TOKEN;
  if (env.PRINT_AGENT_SCENIC_IDS != null && env.PRINT_AGENT_SCENIC_IDS !== '') {
    next.scenicIds = env.PRINT_AGENT_SCENIC_IDS.split(',').map((s) => s.trim()).filter(Boolean);
  }
  if (env.PRINT_AGENT_POLL_MS) next.pollMs = Number(env.PRINT_AGENT_POLL_MS);
  if (env.PRINT_AGENT_IDLE_BACKOFF_MS) next.idleBackoffMs = Number(env.PRINT_AGENT_IDLE_BACKOFF_MS);
  if (env.PRINT_AGENT_RESULT_RETRIES) next.resultRetries = Number(env.PRINT_AGENT_RESULT_RETRIES);
  if (env.PRINT_AGENT_STATUS_HOST) next.statusHost = env.PRINT_AGENT_STATUS_HOST;
  if (env.PRINT_AGENT_STATUS_PORT) next.statusPort = Number(env.PRINT_AGENT_STATUS_PORT);
  if (env.PRINT_AGENT_ALLOW_DEFAULT != null) {
    next.allowDefaultPrinter = /^(1|true|yes)$/i.test(env.PRINT_AGENT_ALLOW_DEFAULT);
  }
  if (env.PRINT_AGENT_DEFAULT_PRINTER != null) next.defaultPrinter = env.PRINT_AGENT_DEFAULT_PRINTER;
  if (env.PRINT_AGENT_COMMAND) {
    try {
      next.command = JSON.parse(env.PRINT_AGENT_COMMAND);
    } catch (error) {
      throw new Error(`PRINT_AGENT_COMMAND必须是JSON数组：${error.message}`);
    }
  }
  if (env.PRINT_AGENT_PRINTER != null) {
    next.printer = env.PRINT_AGENT_PRINTER;
  } else if (env.PRINT_AGENT_PRINTERS) {
    try {
      next.printers = JSON.parse(env.PRINT_AGENT_PRINTERS);
    } catch (error) {
      throw new Error(`PRINT_AGENT_PRINTERS必须是JSON对象：${error.message}`);
    }
    delete next.printer;
  }
  return next;
}

function resolveConfigPath(explicitPath, env = process.env, proc = process) {
  if (explicitPath) return path.resolve(explicitPath);
  if (env.PRINT_AGENT_CONFIG) return path.resolve(env.PRINT_AGENT_CONFIG);
  const support = macPackagedSupportDir(proc);
  if (support) return path.join(support, 'config.json');
  return DEFAULT_CONFIG_PATH;
}

/**
 * 加载配置文件及环境变量覆盖。Flutter 通过 PRINT_AGENT_CONFIG 指定用户配置文件。
 */
function loadConfig(options = {}) {
  const env = options.env || process.env;
  const proc = options.proc || process;
  const configPath = resolveConfigPath(options.configPath, env, proc);
  const support = macPackagedSupportDir(proc);
  if (support && configPath === path.join(support, 'config.json')) {
    seedMacConfigIfNeeded(configPath, proc.resourcesPath);
  }
  let raw;
  if (fs.existsSync(configPath)) {
    let text;
    try {
      text = fs.readFileSync(configPath, 'utf8');
    } catch (error) {
      throw new Error(`无法读取配置文件：${error.message}`);
    }
    try {
      raw = JSON.parse(text);
    } catch (error) {
      throw new Error(`配置文件不是合法JSON：${error.message}`);
    }
  } else if (options.allowMissingFile && options.raw) {
    raw = options.raw;
  } else if (options.raw) {
    raw = options.raw;
  } else {
    throw new Error(`找不到配置文件：${configPath}（可复制 config.example.json 为 config.json）`);
  }
  const merged = options.transformRaw ? options.transformRaw(raw) : applyEnvOverrides(raw, env);
  return normalizeConfig(merged, {
    configPath,
    platform: proc.platform,
    scriptDir: options.scriptDir || path.join(ROOT, 'scripts'),
    lockDir: options.lockDir || (support ? path.join(support, '.runtime') : undefined),
  });
}

/**
 * 从已规范化配置写出可编辑 JSON（不含运行期字段）。
 */
/**
 * 多景区密钥档案：打印机等仍走顶层共用字段。
 * 旧配置仅有 token 时自动迁成一条档案并激活。
 */
function normalizeScenicProfiles(raw, fallback) {
  let list = Array.isArray(raw.scenicProfiles) ? raw.scenicProfiles.slice() : [];
  if (list.length === 0) {
    list = [{
      id: 'default',
      token: fallback.token,
      scenicIds: fallback.scenicIds,
      scenicName: fallback.scenicName,
      scenicCode: fallback.scenicCode,
    }];
  }
  const seen = new Set();
  const scenicProfiles = list.map((entry, index) => {
    if (!entry || typeof entry !== 'object') {
      throw new Error(`scenicProfiles[${index}] 必须是对象`);
    }
    const id = String(entry.id || `profile-${index + 1}`).trim();
    if (!id) throw new Error(`scenicProfiles[${index}] 缺少 id`);
    if (seen.has(id)) throw new Error(`景区档案 id 重复：${id}`);
    seen.add(id);
    const profileToken = String(entry.token || '').trim();
    if (!profileToken) throw new Error(`景区档案 ${id} 缺少密钥`);
    let ids = entry.scenicIds;
    if (ids == null) ids = [];
    if (typeof ids === 'string') {
      ids = ids.split(',').map((s) => s.trim()).filter(Boolean);
    }
    if (!Array.isArray(ids) || ids.some((v) => v == null || String(v).trim() === '')) {
      throw new Error(`景区档案 ${id} 的 scenicIds 无效`);
    }
    return {
      id,
      token: profileToken,
      scenicIds: ids.map((v) => String(v).trim()),
      scenicName: entry.scenicName == null ? '' : String(entry.scenicName).trim(),
      scenicCode: entry.scenicCode == null ? '' : String(entry.scenicCode).trim(),
    };
  });
  let activeScenicProfileId = String(raw.activeScenicProfileId || '').trim();
  if (!scenicProfiles.some((p) => p.id === activeScenicProfileId)) {
    activeScenicProfileId = scenicProfiles[0].id;
  }
  const active = scenicProfiles.find((p) => p.id === activeScenicProfileId);
  return { scenicProfiles, activeScenicProfileId, active };
}

function toWritableConfig(config) {
  return {
    base: config.base,
    token: config.token,
    scenicIds: config.scenicIds,
    scenicName: config.scenicName || '',
    scenicCode: config.scenicCode || '',
    scenicProfiles: (config.scenicProfiles || []).map((p) => ({
      id: p.id,
      token: p.token,
      scenicIds: (p.scenicIds || []).slice(),
      scenicName: p.scenicName || '',
      scenicCode: p.scenicCode || '',
    })),
    activeScenicProfileId: config.activeScenicProfileId || '',
    pollMs: config.pollMs,
    idleBackoffMs: config.idleBackoffMs,
    idleThreshold: config.idleThreshold,
    resultRetries: config.resultRetries,
    autoPrintMs: config.autoPrintMs,
    listRefreshMs: config.listRefreshMs,
    statusHost: config.statusHost,
    statusPort: config.statusPort,
    printer: config.printer,
    ...(config.printerSelectionRequired ? { printerSelectionRequired: true } : {}),
    printDpi: config.printDpi,
    highPrintQuality: config.highPrintQuality,
    command: config.command.slice(),
    statusCommand: config.statusCommand ? config.statusCommand.slice() : null,
    printerSettleMs: config.printerSettleMs,
    printerSheetSettleMs: config.printerSheetSettleMs,
    printerWatchMaxMs: config.printerWatchMaxMs,
    printerPollMs: config.printerPollMs,
    autoPrint: Boolean(config.autoPrint),
    historyLimit: config.historyLimit,
    openStatusOnStart: config.openStatusOnStart,
    notifyOnResult: config.notifyOnResult,
  };
}

function saveConfig(config, configPath = config.configPath, transform = payload => payload) {
  if (!configPath) throw new Error('无配置路径，无法保存');
  const payload = transform(toWritableConfig(config));
  const dir = path.dirname(configPath);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = `${configPath}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  fs.renameSync(tmp, configPath);
  return configPath;
}

function redactConfig(config) {
  const writable = toWritableConfig(config);
  return {
    ...writable,
    token: config.token ? '[已配置]' : '',
    scenicProfiles: (writable.scenicProfiles || []).map((p) => ({
      ...p,
      token: p.token ? '[已配置]' : '',
    })),
    configPath: config.configPath,
    scriptDir: config.scriptDir,
  };
}

module.exports = {
  ROOT,
  DEFAULT_CONFIG_PATH,
  EXAMPLE_CONFIG_PATH,
  DEFAULT_OPERATION_BASE,
  KIND_KEYS,
  loadConfig,
  normalizeConfig,
  macPackagedSupportDir,
  seedMacConfigIfNeeded,
  applyEnvOverrides,
  saveConfig,
  toWritableConfig,
  redactConfig,
  resolveConfigPath,
};
