'use strict';

/**
 * 打印代理运行时：配置、单实例锁、调度、历史、日志。
 * CLI 与 Electron 共用，避免两套逻辑。
 */
const { loadConfig, resolveConfigPath, saveConfig, redactConfig, normalizeConfig, toWritableConfig } = require('./config');
const { createHistory } = require('./history');
const { createLogBuffer } = require('./log-buffer');
const { createScheduler } = require('./scheduler');
const { acquireLock } = require('./single-instance');

/**
 * @param {object} options
 * @param {string} [options.configPath]
 * @param {boolean} [options.skipLock]
 * @param {(title:string, body:string)=>void} [options.notify]
 */
async function createRuntime(options = {}) {
  const configPathArg = options.configPath;
  let config = loadConfig({ configPath: configPathArg, lockDir: options.lockDir });
  if (options.forceManualStart) config.autoPrint = false;
  let lock = null;
  if (!options.skipLock) {
    try {
      lock = acquireLock(config.lockDir);
    } catch (error) {
      if (error.code === 'ELOCKED') {
        const err = new Error(error.message);
        err.code = 'ELOCKED';
        throw err;
      }
      throw error;
    }
  }

  const history = createHistory(config.historyLimit);
  const logs = createLogBuffer(500);
  const runtime = {
    config,
    lock,
    history,
    logs,
    scheduler: null,
    setConfig(next) {
      runtime.config = next;
      if (runtime.scheduler) runtime.scheduler.setConfig(next);
    },
    getConfig() {
      return runtime.config;
    },
  };

  function logLine(message, level) {
    const text = String(message);
    logs.append(text, level || 'info');
    if (typeof options.onLog === 'function') options.onLog(text, level);
  }

  const scheduler = createScheduler({
    config: runtime.config,
    includePrintIssues: options.includePrintIssues,
    history,
    autoPrint: Boolean(runtime.config.autoPrint),
    log: (msg) => logLine(msg, 'info'),
    notify(result) {
      if (typeof options.notify === 'function') {
        if (result.state === 'PRINTED') {
          options.notify('打印完成', `任务 ${result.jobId}`);
        } else if (result.state === 'FAILED' || result.state === 'ERROR') {
          options.notify('打印失败', `任务 ${result.jobId || ''} ${result.reason || ''}`.trim());
        }
      }
    },
    onStateChange(state) {
      if (typeof options.onStateChange === 'function') options.onStateChange(state);
    },
  });
  runtime.scheduler = scheduler;

  logLine(`配置 ${runtime.config.configPath}`, 'info');
  if (lock) logLine(`单实例锁 ${lock.lockPath}`, 'info');
  logLine(
    runtime.config.autoPrint
      ? `自动打印开（每 ${Math.round((runtime.config.autoPrintMs || 300000) / 60000)} 分钟拉未打印）`
      : '自动打印关（在线列表勾选后打印）',
    'info',
  );
  if (runtime.config.skipPrint) {
    logLine('skipPrint：下载与回报照常，不调本机打印机', 'warn');
  } else if (!runtime.config.statusCommand) {
    logLine('未配置打印机状态检查（statusCommand）：缺纸、卡纸不会被拦截，打印命令受理即报已打印', 'warn');
  }

  function snapshot() {
    return {
      state: scheduler.getState(),
      config: redactConfig(runtime.getConfig()),
      history: history.list(),
      logs: logs.list(),
    };
  }

  async function setAutoPrint(enabled) {
    const on = scheduler.setAutoPrint(enabled);
    const current = toWritableConfig(runtime.getConfig());
    const next = normalizeConfig({ ...current, autoPrint: on }, {
      configPath: runtime.getConfig().configPath,
      scriptDir: runtime.getConfig().scriptDir,
    });
    saveConfig(next);
    runtime.setConfig(next);
    return snapshot();
  }

  /**
   * 勾选打印。手动路径默认 paperOutConfirm：仅缺纸时返回 needConfirm，确认后再带 ignorePaperOut。
   * @param {string[]} ids
   * @param {{ignorePaperOut?:boolean}} [options]
   */
  async function printJobs(ids, options = {}) {
    const result = await scheduler.printJobIds(ids || [], {
      paperOutConfirm: true,
      ignorePaperOut: Boolean(options && options.ignorePaperOut),
    });
    if (result && result.needConfirm) {
      return {
        ...snapshot(),
        needConfirm: true,
        mode: 'begin',
        ids: result.ids,
        printers: result.printers,
        reason: result.reason,
        message: result.message,
      };
    }
    return snapshot();
  }

  /**
   * 继续打印。手动路径默认 paperOutConfirm：仅缺纸时返回 needConfirm。
   * @param {string[]} ids
   * @param {{ignorePaperOut?:boolean}} [options]
   */
  async function continueJobs(ids, options = {}) {
    const result = await scheduler.continueJobIds(ids || [], {
      paperOutConfirm: true,
      ignorePaperOut: Boolean(options && options.ignorePaperOut),
    });
    if (result && result.needConfirm) {
      return {
        ...snapshot(),
        needConfirm: true,
        mode: 'continue',
        ids: result.ids,
        printers: result.printers,
        reason: result.reason,
        message: result.message,
      };
    }
    return snapshot();
  }

  async function markUnprinted(ids) {
    await scheduler.markUnprinted(ids || []);
    return snapshot();
  }

  async function confirmPrinted(ids) {
    await scheduler.confirmPrinted(ids || []);
    return snapshot();
  }

  async function queryJobs(patch) {
    await scheduler.setJobQuery(patch || {});
    return snapshot();
  }

  async function refreshJobs() {
    await scheduler.refreshJobs();
    return snapshot();
  }

  /** 打前核对：拉条目清单（不含图片字节）。 */
  async function previewJob(jobId) {
    const { previewJob } = require('./api');
    const job = await previewJob(runtime.getConfig(), jobId);
    if (!job || !job.id) throw new Error('任务预览失败：未返回任务');
    return {
      id: String(job.id),
      items: (job.items || []).map((item, index) => ({
        index: index + 1,
        kind: item.kind || '',
        label: item.label || item.kind || '',
        copies: item.copies != null ? item.copies : 1,
        fileUrl: item.fileUrl || '',
      })),
    };
  }

  /** 打前核对：按 fileUrl 下载一张图，返回 data URL（主进程持有 token）。 */
  async function previewJobImage(fileUrl) {
    const { downloadFile, generatingThumbnailPath } = require('./api');
    if (!fileUrl || typeof fileUrl !== 'string') {
      throw new Error('预览地址无效');
    }
    const generating = generatingThumbnailPath.test(fileUrl);
    if (!generating && !fileUrl.startsWith('/print-agents/jobs/')) {
      throw new Error('预览地址无效');
    }
    if (!generating && !fileUrl.includes('/preview-files/')) {
      throw new Error('预览只能使用 preview-files 地址');
    }
    const previewUrl = new URL(fileUrl, 'http://print.local');
    const small = previewUrl.searchParams.get('thumbnail') === 'true';
    const detail = previewUrl.searchParams.get('preview') === 'true';
    const downloadUrl = small || detail
      ? previewUrl.pathname.replace('/preview-files/', '/preview-thumbnails/') + `?width=${small ? 160 : 1200}`
      : fileUrl;
    const { buffer, contentType } = await downloadFile(runtime.getConfig(), downloadUrl);
    const mime = (contentType && contentType.split(';')[0].trim()) || 'image/jpeg';
    const jpeg = buffer.length > 2 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff;
    const png = buffer.length > 8 && buffer.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'));
    const webp = buffer.length >= 20 && buffer.toString('ascii', 0, 4) === 'RIFF'
      && buffer.toString('ascii', 8, 12) === 'WEBP';
    if (!(jpeg && mime === 'image/jpeg') && !(png && mime === 'image/png')
      && !(webp && mime === 'image/webp')) {
      throw new Error('预览响应不是有效的JPEG/PNG/WebP图片');
    }
    return {
      contentType: mime,
      dataUrl: `data:${mime};base64,${buffer.toString('base64')}`,
    };
  }

  /**
   * 详情试打印：只打当前预览张，本机出纸，不占单、不回写任务状态。
   * 仅缺纸且未确认时返回 needConfirm，由界面弹窗后带 ignorePaperOut 再调。
   * @param {{kind:string,label?:string,fileUrl:string,copies?:number}} item
   * @param {{ignorePaperOut?:boolean}} [options]
   */
  async function trialPrintItem(item, options = {}) {
    const fs = require('node:fs');
    const os = require('node:os');
    const path = require('node:path');
    const { downloadFile } = require('./api');
    const { resolvePrinter, runPrintCommand } = require('./print');
    const {
      probePrinter,
      printerFaults,
      filterPrinterFaults,
      isOnlyPaperOut,
      assertPrinterReady,
    } = require('./printer-status');
    if (!item || typeof item !== 'object') throw new Error('试打印条目无效');
    const fileUrl = item.fileUrl;
    if (!fileUrl || typeof fileUrl !== 'string' || !fileUrl.startsWith('/print-agents/jobs/')) {
      throw new Error('试打印地址无效');
    }
    if (!fileUrl.includes('/preview-files/')) {
      throw new Error('试打印只能使用 preview-files 地址');
    }
    const kind = String(item.kind || '').trim();
    if (!kind) throw new Error('试打印缺少 kind');
    const ignorePaperOut = Boolean(options && options.ignorePaperOut);
    const config = runtime.getConfig();
    const printer = resolvePrinter(config, kind);
    const label = item.label || kind;
    if (Array.isArray(config.statusCommand) && !config.skipPrint) {
      if (!ignorePaperOut) {
        const snapshot = await probePrinter(config, printer);
        const faults = printerFaults(snapshot);
        if (isOnlyPaperOut(faults)) {
          return {
            needConfirm: true,
            kind,
            printer,
            label,
            reason: '缺纸',
            message: `打印机 ${printer} 驱动报告缺纸；若纸匣有纸，可能是误报。`,
          };
        }
        const blocking = filterPrinterFaults(faults, {});
        if (blocking.length) {
          throw new Error(`打印机未就绪：${printer}（${blocking.join('、')}）`);
        }
      } else {
        await assertPrinterReady(config, printer, { ignorePaperOut: true });
        logLine(`用户确认忽略缺纸后试打印：${label} → ${printer}`, 'warn');
      }
    }
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-trial-'));
    try {
      const { buffer, contentType } = await downloadFile(config, fileUrl);
      const extension = String(contentType || '').includes('png') ? '.png' : '.jpg';
      const file = path.join(directory, `trial-${kind}${extension}`);
      fs.writeFileSync(file, buffer);
      if (config.skipPrint) {
        logLine(`试打印跳过出纸（skipPrint）：${label} → ${printer}`, 'info');
        return { skipped: true, kind, printer, label, bytes: buffer.length };
      }
      await runPrintCommand(config, { kind, copies: 1, label }, file, printer);
      logLine(`试打印已受理：${label} → ${printer}`, 'info');
      return { skipped: false, kind, printer, label, bytes: buffer.length, ignoredPaperOut: ignorePaperOut };
    } finally {
      try {
        fs.rmSync(directory, { recursive: true, force: true });
      } catch {
        /* ignore */
      }
    }
  }

  /**
   * 打前/手动打印：把本单全部图片打成 ZIP 写到本地。
   * @param {string|number} jobId
   * @param {string} targetPath 用户选定的 .zip 路径
   */
  async function downloadJobZip(jobId, targetPath) {
    const path = require('path');
    const { downloadFile } = require('./api');
    const { writeStoreZipFile } = require('./zip-store.cjs');
    if (!targetPath || typeof targetPath !== 'string' || !targetPath.toLowerCase().endsWith('.zip')) {
      throw new Error('请选择以 .zip 结尾的保存路径');
    }
    const preview = await previewJob(jobId);
    const items = preview.items || [];
    if (!items.length) throw new Error('本单没有可下载图片');
    const entries = [];
    for (const item of items) {
      if (!item.fileUrl || !item.fileUrl.includes('/preview-files/')) {
        throw new Error(`条目 ${item.index} 缺少预览下载地址`);
      }
      const { buffer, contentType } = await downloadFile(runtime.getConfig(), item.fileUrl);
      const mime = (contentType && contentType.split(';')[0].trim()) || 'image/jpeg';
      const ext = mime.includes('png') ? '.png' : '.jpg';
      const kind = String(item.kind || item.label || 'PHOTO').replace(/[^\w\u4e00-\u9fff-]+/g, '_');
      const name = `${String(item.index).padStart(2, '0')}-${kind}${ext}`;
      entries.push({ name, data: buffer });
      logLine(`ZIP 已收录 ${name}（${buffer.length} 字节）`, 'info');
    }
    writeStoreZipFile(path.resolve(targetPath), entries);
    logLine(`任务 ${preview.id} 已打包 ${entries.length} 张 → ${targetPath}`, 'info');
    return { jobId: String(preview.id), count: entries.length, path: path.resolve(targetPath) };
  }

  function assertCanSwitchScenic() {
    const state = scheduler.getState();
    if (state.printBusy) throw new Error('正在打印，请完成后再切换景区');
    if (state.autoPrint) throw new Error('请先关闭自动打印再切换景区');
  }

  function withNorm(patch) {
    return normalizeConfig({
      ...toWritableConfig(runtime.getConfig()),
      ...patch,
      base: runtime.getConfig().base || require('./config').DEFAULT_OPERATION_BASE,
    }, {
      configPath: runtime.getConfig().configPath,
      scriptDir: runtime.getConfig().scriptDir,
    });
  }

  async function bindToken(token) {
    const { fetchMe } = require('./api');
    const me = await fetchMe({ base: runtime.getConfig().base, token });
    if (!me || !me.scenicId) throw new Error('密钥校验失败：未返回景区信息');
    const ids = Array.isArray(me.scenicIds) && me.scenicIds.length
      ? me.scenicIds.map((id) => String(id))
      : [String(me.scenicId)];
    return {
      token,
      scenicIds: ids,
      scenicName: me.scenicName || '',
      scenicCode: me.scenicCode || '',
    };
  }

  function syncActiveProfile(writable, bound) {
    const profiles = (writable.scenicProfiles || []).map((p) => ({ ...p }));
    const activeId = writable.activeScenicProfileId || (profiles[0] && profiles[0].id);
    const index = profiles.findIndex((p) => p.id === activeId);
    if (index < 0) throw new Error('当前激活景区档案不存在');
    profiles[index] = { ...profiles[index], ...bound };
    return {
      ...writable,
      ...bound,
      scenicProfiles: profiles,
      activeScenicProfileId: profiles[index].id,
    };
  }

  async function applyConfigPatch(body) {
    const current = toWritableConfig(runtime.getConfig());
    let merged = {
      ...current,
      ...body,
      token: body.token && String(body.token).trim()
        ? String(body.token).trim()
        : current.token,
      base: current.base || require('./config').DEFAULT_OPERATION_BASE,
      scenicProfiles: body.scenicProfiles || current.scenicProfiles,
      activeScenicProfileId: body.activeScenicProfileId || current.activeScenicProfileId,
    };
    if (body.token && String(body.token).trim()) {
      const bound = await bindToken(String(body.token).trim());
      merged = syncActiveProfile(merged, bound);
      logLine(`密钥已绑定景区 ${bound.scenicName || bound.scenicIds[0]}`, 'info');
    }
    const next = normalizeConfig(merged, {
      configPath: runtime.getConfig().configPath,
      scriptDir: runtime.getConfig().scriptDir,
    });
    saveConfig(next);
    runtime.setConfig(next);
    logLine('配置已保存并热加载', 'info');
    return redactConfig(next);
  }

  async function addScenicProfile(body = {}) {
    const token = String(body.token || '').trim();
    if (!token) throw new Error('请输入景区打印密钥');
    const current = toWritableConfig(runtime.getConfig());
    if ((current.scenicProfiles || []).some((p) => p.token === token)) {
      throw new Error('该密钥已在档案列表中');
    }
    const bound = await bindToken(token);
    if (body.scenicId && !bound.scenicIds.includes(body.scenicId)) {
      throw new Error('该打印密钥不属于此机位的景区');
    }
    const id = `scenic-${Date.now()}`;
    const profiles = [...(current.scenicProfiles || []), { id, ...bound }];
    const activate = Boolean(body.activate) || profiles.length === 1;
    if (activate) assertCanSwitchScenic();
    const next = withNorm({
      scenicProfiles: profiles,
      activeScenicProfileId: activate ? id : current.activeScenicProfileId,
      ...(activate ? bound : {}),
    });
    saveConfig(next);
    runtime.setConfig(next);
    logLine(`已添加景区档案 ${bound.scenicName || id}${activate ? '（已激活）' : ''}`, 'info');
    return snapshot();
  }

  async function activateScenicProfile(body = {}) {
    assertCanSwitchScenic();
    const id = String(body.id || '').trim();
    if (!id) throw new Error('请指定要激活的景区档案');
    const original = runtime.getConfig();
    const current = toWritableConfig(original);
    const profile = (current.scenicProfiles || []).find((p) => p.id === id);
    if (!profile) throw new Error('景区档案不存在');
    const bound = await bindToken(profile.token);
    assertCanSwitchScenic();
    if (runtime.getConfig() !== original) throw new Error('景区档案已更新，请重试');
    const next = withNorm({
      activeScenicProfileId: id,
      scenicProfiles: current.scenicProfiles.map((entry) => entry.id === id ? { id, ...bound } : entry),
    });
    saveConfig(next);
    runtime.setConfig(next);
    await scheduler.refreshJobs().catch((error) => {
      logLine(`切换景区后刷新列表失败：${error.message}`, 'warn');
    });
    logLine(`已切换景区 ${next.scenicName || id}`, 'info');
    return snapshot();
  }

  async function deleteScenicProfile(body = {}) {
    assertCanSwitchScenic();
    const id = String(body.id || '').trim();
    if (!id) throw new Error('请指定要删除的景区档案');
    const current = toWritableConfig(runtime.getConfig());
    const profiles = current.scenicProfiles || [];
    if (profiles.length <= 1) throw new Error('至少保留一个景区档案');
    if (current.activeScenicProfileId === id) {
      throw new Error('不能删除当前激活的景区，请先切换到其他景区');
    }
    const next = withNorm({
      scenicProfiles: profiles.filter((p) => p.id !== id),
      activeScenicProfileId: current.activeScenicProfileId,
    });
    saveConfig(next);
    runtime.setConfig(next);
    logLine(`已删除景区档案 ${id}`, 'info');
    return snapshot();
  }

  async function updateScenicProfile(body = {}) {
    const id = String(body.id || '').trim();
    if (!id) throw new Error('请指定要更新的景区档案');
    const token = String(body.token || '').trim();
    if (!token) throw new Error('请输入景区打印密钥');
    const current = toWritableConfig(runtime.getConfig());
    const profiles = (current.scenicProfiles || []).slice();
    const index = profiles.findIndex((p) => p.id === id);
    if (index < 0) throw new Error('景区档案不存在');
    if (current.activeScenicProfileId === id) assertCanSwitchScenic();
    const bound = await bindToken(token);
    profiles[index] = { id, ...bound };
    const next = withNorm({
      scenicProfiles: profiles,
      activeScenicProfileId: current.activeScenicProfileId,
      ...(current.activeScenicProfileId === id ? bound : {}),
    });
    saveConfig(next);
    runtime.setConfig(next);
    logLine(`已更新景区档案 ${bound.scenicName || id}`, 'info');
    return snapshot();
  }

  function reloadFromDisk() {
    const next = loadConfig({
      configPath: runtime.getConfig().configPath || resolveConfigPath(configPathArg),
    });
    runtime.setConfig(next);
    logLine('已从磁盘重载配置', 'info');
    return next;
  }

  function start() {
    scheduler.start();
    logLine('代理已启动', 'info');
  }

  function stop() {
    scheduler.stop();
    if (lock && typeof lock.release === 'function') {
      try {
        lock.release();
      } catch {
        /* ignore */
      }
    }
    logLine('代理已停止', 'warn');
  }

  return {
    runtime,
    scheduler,
    history,
    logs,
    snapshot,
    applyConfigPatch,
    addScenicProfile,
    activateScenicProfile,
    deleteScenicProfile,
    updateScenicProfile,
    reloadFromDisk,
    setAutoPrint,
    printJobs,
    continueJobs,
    markUnprinted,
    confirmPrinted,
    queryJobs,
    refreshJobs,
    previewJob,
    previewJobImage,
    trialPrintItem,
    downloadJobZip,
    start,
    stop,
    logLine,
  };
}

module.exports = { createRuntime };
