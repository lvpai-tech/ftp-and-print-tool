'use strict';

const { listJobs, listGenerating, beginJob, continueJob, requeueJobs, confirmPrintedJobs } = require('./api');
const { processClaimedJob } = require('./agent');
const {
  assertPrinterReady,
  probePrinter,
  printerFaults,
  filterPrinterFaults,
  isOnlyPaperOut,
} = require('./printer-status');

/**
 * 在线任务列表 + 手动/自动打印。本机不囤单；无接单暂停概念。
 * 自动打印开时按 autoPrintMs（默认 5 分钟）拉 UNPRINTED 并依次打印。
 */
function createScheduler(options = {}) {
  let config = options.config;
  let autoPrint = options.autoPrint !== undefined ? Boolean(options.autoPrint) : false;
  let running = false;
  let printBusy = false;
  let listBusy = false;
  let listRequest = 0;
  let listError = '';
  let autoTimer = null;
  let listTimer = null;
  let currentJob = null;
  let lastError = '';
  let phase = 'stopped';
  let jobQuery = {
    printStatus: 'UNPRINTED',
    createdFrom: '',
    createdTo: '',
    pageNum: 1,
    pageSize: 20,
  };
  let jobPage = { list: [], total: 0, pageNum: 1, pageSize: 20 };
  let printIssues = null;
  let printIssuesError = '';

  const history = options.history;
  const onStateChange = typeof options.onStateChange === 'function' ? options.onStateChange : () => {};
  const notify = typeof options.notify === 'function' ? options.notify : () => {};
  const log = typeof options.log === 'function' ? options.log : (msg) => console.log(msg);

  function emit() {
    onStateChange(getState());
  }

  function getState() {
    return {
      running,
      autoPrint,
      printBusy,
      listBusy,
      listError,
      printIssues,
      printIssuesError,
      busy: printBusy || listBusy,
      phase,
      jobQuery: { ...jobQuery },
      jobPage: {
        list: jobPage.list || [],
        total: jobPage.total || 0,
        pageNum: jobPage.pageNum || 1,
        pageSize: jobPage.pageSize || 20,
      },
      currentJob: currentJob
        ? { id: currentJob.id, itemCount: (currentJob.items || []).length }
        : null,
      lastError: lastError || '',
      autoPrintMs: config.autoPrintMs,
      listRefreshMs: config.listRefreshMs,
    };
  }

  function setConfig(next) {
    if (next.base !== config.base || next.token !== config.token) {
      listRequest += 1;
      listBusy = false;
      jobQuery = { ...jobQuery, pageNum: 1, ...(options.includePrintIssues ? { issuePage: 1 } : {}) };
      clearJobPage();
    }
    config = next;
    if (next && next.autoPrint !== undefined) {
      autoPrint = Boolean(next.autoPrint);
    }
    if (history && typeof history.setLimit === 'function') {
      history.setLimit(next.historyLimit);
    }
    emit();
    if (running) {
      scheduleAuto();
      scheduleListRefresh();
    }
  }

  function setAutoPrint(enabled) {
    autoPrint = Boolean(enabled);
    log(`[${new Date().toISOString()}] 自动打印已${autoPrint ? '开启' : '关闭'}`);
    emit();
    scheduleAuto();
    if (autoPrint && !printBusy) {
      runAutoPrintCycle().catch((error) => {
        lastError = String(error.message || error).slice(0, 480);
        emit();
      });
    }
    return autoPrint;
  }

  function setJobQuery(patch = {}) {
    const next = { ...jobQuery, ...patch };
    next.printStatus = String(next.printStatus || 'ALL').toUpperCase();
    if (!['ALL', 'PRINTED', 'UNPRINTED', 'FAILED', 'GENERATING'].includes(next.printStatus)) {
      throw new Error('状态仅支持全部/已打印/未打印/打印失败/生成中');
    }
    next.pageNum = Math.max(1, Number(next.pageNum) || 1);
    next.pageSize = Math.min(100, Math.max(1, Number(next.pageSize) || 20));
    if (options.includePrintIssues) next.issuePage = Math.max(1, Number(next.issuePage) || 1);
    next.createdFrom = next.createdFrom ? String(next.createdFrom) : '';
    next.createdTo = next.createdTo ? String(next.createdTo) : '';
    const changed = Object.keys(next).some((key) => next[key] !== jobQuery[key]);
    jobQuery = next;
    if (changed) clearJobPage();
    return refreshJobs();
  }

  function clearJobPage() {
    jobPage = { list: [], total: 0, pageNum: jobQuery.pageNum, pageSize: jobQuery.pageSize };
    listError = '';
    printIssues = null;
    printIssuesError = '';
  }

  async function refreshPrintIssues(request, query) {
    if (!options.includePrintIssues || query.printStatus !== 'UNPRINTED') return;
    const pageSize = 10;
    const params = { ...query, printStatus: 'EXCEPTIONS', pageSize, pageNum: query.issuePage || 1 };
    try {
      const signal = AbortSignal.timeout(10000);
      const valid = (data) => Array.isArray(data?.list) && Number.isInteger(data.total)
        && Number.isInteger(data.pageNum) && Number.isInteger(data.pageSize);
      let data = await listJobs(config, params, signal);
      if (request !== listRequest) return;
      if (!valid(data)) throw new Error('打印异常列表响应不完整');
      const lastPage = Math.max(1, Math.ceil(data.total / pageSize));
      if (params.pageNum > lastPage) {
        data = await listJobs(config, { ...params, pageNum: lastPage }, signal);
        if (request !== listRequest) return;
        jobQuery.issuePage = lastPage;
      }
      if (!valid(data)) {
        throw new Error('打印异常列表响应不完整');
      }
      printIssues = data;
      printIssuesError = '';
    } catch (error) {
      if (request !== listRequest) return;
      printIssues = null;
      printIssuesError = String(error.message || error).slice(0, 480);
    }
    emit();
  }

  async function refreshJobs() {
    if (!config || !config.token) {
      throw new Error('未配置打印密钥，无法查询任务');
    }
    const request = ++listRequest;
    const query = jobQuery;
    const generating = query.printStatus === 'GENERATING';
    listBusy = true;
    phase = printBusy ? 'printing' : 'listing';
    emit();
    const issues = refreshPrintIssues(request, query);
    try {
      const data = await (generating ? listGenerating : listJobs)(config, query);
      if (request !== listRequest) return jobPage;
      jobPage = {
        list: Array.isArray(data && data.list) ? data.list : [],
        total: Number(data && data.total) || 0,
        pageNum: Number(data && data.pageNum) || query.pageNum,
        pageSize: Number(data && data.pageSize) || query.pageSize,
      };
      listError = '';
      lastError = '';
      phase = printBusy ? 'printing' : 'idle';
      emit();
      return jobPage;
    } catch (error) {
      if (request !== listRequest) return jobPage;
      if (generating) clearJobPage();
      listError = String(error.message || error).slice(0, 480);
      lastError = listError;
      phase = 'error';
      log(`[${new Date().toISOString()}] 任务列表失败：${lastError}`);
      emit();
      throw error;
    } finally {
      await issues;
      if (request === listRequest) {
        listBusy = false;
        if (phase === 'listing') phase = printBusy ? 'printing' : 'idle';
        emit();
      }
    }
  }

  async function finishPrintResult(result) {
    currentJob = null;
    lastError = result.state === 'FAILED' || result.state === 'ERROR' ? result.reason || result.state : '';
    if (history) {
      history.push({
        jobId: result.jobId,
        state: result.state,
        printer: result.printer || '',
        reason: result.reason || '',
      });
    }
    log(
      `[${new Date().toISOString()}] 任务${result.jobId} ${result.state}${
        result.reason ? ` ${result.reason}` : ''
      }`,
    );
    notify(result);
    emit();
  }

  function mappedPrinters() {
    const printers = new Set(Object.values(config.printers || {}).filter(Boolean));
    if (config.allowDefaultPrinter && config.defaultPrinter) printers.add(config.defaultPrinter);
    return [...printers];
  }

  /**
   * 领单前检查本机映射打印机。
   * - 默认：缺纸等异常直接抛错（自动打印仍硬拦）。
   * - paperOutConfirm：仅缺纸时返回 needConfirm，不领单，由界面确认后带 ignorePaperOut 再调。
   * - ignorePaperOut：本批忽略缺纸（含送打后观察），其它故障仍硬拦。
   */
  async function assertMappedPrintersReady(options = {}) {
    if (config.skipPrint || !Array.isArray(config.statusCommand)) return null;
    const ignorePaperOut = Boolean(options.ignorePaperOut);
    const paperOutConfirm = Boolean(options.paperOutConfirm);
    const paperOutPrinters = [];
    try {
      for (const printer of mappedPrinters()) {
        if (ignorePaperOut) {
          await assertPrinterReady(config, printer, { ignorePaperOut: true });
          continue;
        }
        const snapshot = await probePrinter(config, printer);
        const faults = printerFaults(snapshot);
        if (isOnlyPaperOut(faults)) {
          paperOutPrinters.push(printer);
          continue;
        }
        const blocking = filterPrinterFaults(faults, {});
        if (blocking.length) {
          throw new Error(`打印机未就绪：${printer}（${blocking.join('、')}）`);
        }
      }
      if (paperOutPrinters.length) {
        if (paperOutConfirm) {
          const names = paperOutPrinters.join('、');
          return {
            needConfirm: true,
            reason: '缺纸',
            printers: paperOutPrinters,
            message:
              `打印机 ${names} 驱动报告缺纸；若纸匣有纸，可能是误报。`
              + '确认后本批将忽略缺纸继续打印，请核对实物。',
          };
        }
        throw new Error(`打印机未就绪：${paperOutPrinters[0]}（缺纸）`);
      }
      return null;
    } catch (error) {
      lastError = `${error.message}，任务未领取，处理后再打印`.slice(0, 480);
      log(`[${new Date().toISOString()}] ${lastError}`);
      throw new Error(lastError);
    }
  }

  async function runPrintPipeline(ids, mode, options = {}) {
    const list = (ids || []).map((id) => String(id)).filter(Boolean);
    if (!list.length) {
      throw new Error(mode === 'continue' ? '请先勾选要继续打印的任务' : '请先勾选要打印的任务');
    }
    if (printBusy) throw new Error('正在打印中，请稍候');

    const rows = mode === 'continue' ? [...jobPage.list, ...(printIssues?.list || [])] : jobPage.list;
    const byId = new Map(rows.map((row) => [String(row.id), row]));
    for (const id of list) {
      const row = byId.get(id);
      const status = row && row.status ? String(row.status) : '';
      const completed = Number(row && row.completedSheets) || 0;
      const total = Number(row && row.totalSheets) || 0;
      if (mode === 'continue') {
        if (status !== 'FAILED') {
          throw new Error(`任务 ${id} 状态为${status || '未知'}，只能继续打印失败任务`);
        }
        if (completed <= 0) {
          throw new Error(`任务 ${id} 无已完成进度，请先「标记未打印」后整单重打`);
        }
        if (total > 0 && completed >= total) {
          throw new Error(`任务 ${id} 进度已满，请「确认已打印」或「标记未打印」`);
        }
      } else {
        if (status === 'FAILED' || status === 'PRINTED') {
          if (status === 'FAILED' && completed > 0) {
            throw new Error('有进度的失败单请点「继续打印」，或先「标记未打印」整单重打');
          }
          throw new Error('失败/已打印不能直接打印，请先「标记未打印」');
        }
        if (status && status !== 'QUEUED' && status !== 'CLAIMED') {
          throw new Error(`任务 ${id} 状态为${status}，不能打印`);
        }
      }
    }

    const ignorePaperOut = Boolean(options.ignorePaperOut);
    const paperOutConfirm = Boolean(options.paperOutConfirm) && !ignorePaperOut;

    const ready = await assertMappedPrintersReady({
      ignorePaperOut,
      paperOutConfirm,
    });
    if (ready && ready.needConfirm) {
      return {
        needConfirm: true,
        mode,
        ids: list,
        reason: ready.reason,
        printers: ready.printers,
        message: ready.message,
      };
    }

    if (ignorePaperOut) {
      log(`[${new Date().toISOString()}] 用户确认忽略缺纸后${mode === 'continue' ? '继续打印' : '打印'}：${list.join('、')}`);
    }

    printBusy = true;
    phase = 'printing';
    emit();

    const results = [];
    try {
      for (const id of list) {
        currentJob = { id, items: [] };
        emit();
        const job = mode === 'continue' ? await continueJob(config, id) : await beginJob(config, id);
        currentJob = { id: job.id, items: job.items || [] };
        emit();
        const result = await processClaimedJob(config, job, {
          skipPrint: Boolean(config.skipPrint),
          ignorePaperOut,
        });
        results.push(result);
        await finishPrintResult(result);
      }
    } finally {
      currentJob = null;
      printBusy = false;
      phase = 'idle';
      emit();
    }

    try {
      await refreshJobs();
    } catch {
      /* 列表刷新失败已记 lastError */
    }
    return results;
  }

  async function printJobIds(ids, options = {}) {
    return runPrintPipeline(ids, 'begin', options);
  }

  /** 继续打印失败且有分张进度的任务，只打剩余张。 */
  async function continueJobIds(ids, options = {}) {
    return runPrintPipeline(ids, 'continue', options);
  }

  /** 将失败/已打印改回未打印，供自动或手动再打。 */
  async function markUnprinted(ids) {
    const list = (ids || []).map((id) => String(id)).filter(Boolean);
    if (!list.length) throw new Error('请先勾选失败或已打印的任务');
    if (printBusy) throw new Error('正在打印中，请稍候');

    const byId = new Map((jobPage.list || []).map((row) => [String(row.id), row]));
    for (const id of list) {
      const row = byId.get(id);
      const status = row && row.status ? String(row.status) : '';
      if (status && status !== 'FAILED' && status !== 'PRINTED') {
        throw new Error(`任务 ${id} 状态为${status}，只能标记失败或已打印`);
      }
    }

    phase = 'listing';
    emit();
    try {
      await requeueJobs(config, list);
      lastError = '';
      log(`[${new Date().toISOString()}] 已标记 ${list.length} 单为未打印`);
      await refreshJobs();
      return list;
    } catch (error) {
      lastError = String(error.message || error).slice(0, 480);
      phase = 'error';
      log(`[${new Date().toISOString()}] 标记未打印失败：${lastError}`);
      emit();
      throw error;
    }
  }

  /** 店员核对纸面后，把失败/待核对任务确认为已打印；不触发打印。 */
  async function confirmPrinted(ids) {
    const list = (ids || []).map((id) => String(id)).filter(Boolean);
    if (!list.length) throw new Error('请先勾选失败或待核对的任务');
    if (printBusy) throw new Error('正在打印中，请稍候');

    const byId = new Map((jobPage.list || []).map((row) => [String(row.id), row]));
    for (const id of list) {
      const row = byId.get(id);
      const status = row && row.status ? String(row.status) : '';
      if (status && status !== 'FAILED' && status !== 'UNKNOWN') {
        throw new Error(`任务 ${id} 状态为${status}，只能确认失败或待核对的任务已打印`);
      }
    }

    phase = 'listing';
    emit();
    try {
      await confirmPrintedJobs(config, list);
      lastError = '';
      log(`[${new Date().toISOString()}] 已确认 ${list.join('、')} 已打印`);
      await refreshJobs();
      return list;
    } catch (error) {
      lastError = String(error.message || error).slice(0, 480);
      phase = 'error';
      log(`[${new Date().toISOString()}] 确认已打印失败：${lastError}`);
      emit();
      throw error;
    }
  }

  async function runAutoPrintCycle() {
    if (!running || !autoPrint || printBusy) return;
    try {
      const page = await listJobs(config, {
        printStatus: 'UNPRINTED',
        pageNum: 1,
        pageSize: Math.min(50, jobQuery.pageSize || 20),
      });
      const ids = (page && page.list ? page.list : [])
        .filter((row) => row && row.status === 'QUEUED')
        .map((row) => String(row.id));
      if (!ids.length) {
        lastError = '';
        phase = 'idle';
        emit();
        return [];
      }
      log(`[${new Date().toISOString()}] 自动打印：发现 ${ids.length} 单未打印`);
      return printJobIds(ids);
    } catch (error) {
      lastError = String(error.message || error).slice(0, 480);
      phase = 'error';
      log(`[${new Date().toISOString()}] 自动打印失败：${lastError}`);
      emit();
      throw error;
    }
  }

  function scheduleAuto() {
    if (autoTimer) {
      clearTimeout(autoTimer);
      autoTimer = null;
    }
    if (!running || !autoPrint) return;
    const delay = Math.max(5000, Number(config.autoPrintMs) || 300000);
    autoTimer = setTimeout(() => {
      autoTimer = null;
      runAutoPrintCycle()
        .catch(() => {})
        .finally(() => scheduleAuto());
    }, delay);
    if (typeof autoTimer.unref === 'function') autoTimer.unref();
  }

  function scheduleListRefresh() {
    if (listTimer) {
      clearTimeout(listTimer);
      listTimer = null;
    }
    if (!running) return;
    const delay = Math.max(5000, Number(config.listRefreshMs) || 30000);
    listTimer = setTimeout(() => {
      listTimer = null;
      refreshJobs()
        .catch(() => {})
        .finally(() => scheduleListRefresh());
    }, delay);
    if (typeof listTimer.unref === 'function') listTimer.unref();
  }

  function start() {
    if (running) return;
    running = true;
    phase = 'idle';
    emit();
    refreshJobs().catch(() => {});
    scheduleListRefresh();
    scheduleAuto();
  }

  function stop() {
    running = false;
    if (autoTimer) {
      clearTimeout(autoTimer);
      autoTimer = null;
    }
    if (listTimer) {
      clearTimeout(listTimer);
      listTimer = null;
    }
    phase = 'stopped';
    emit();
  }

  return {
    start,
    stop,
    setConfig,
    setAutoPrint,
    setJobQuery,
    refreshJobs,
    printJobIds,
    continueJobIds,
    markUnprinted,
    confirmPrinted,
    runAutoPrintCycle,
    getState,
    get config() {
      return config;
    },
    get autoPrint() {
      return autoPrint;
    },
  };
}

module.exports = { createScheduler };
