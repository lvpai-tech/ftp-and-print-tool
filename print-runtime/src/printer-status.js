'use strict';

const { spawn } = require('node:child_process');
const path = require('node:path');
const { appRoot } = require('./paths');

/**
 * 打印机就绪检查与送打后观察。
 * 打印命令退出码0只代表Windows假脱机已受理，缺纸、卡纸等由驱动稍后上报；
 * 这里读取驱动状态拦截已知异常，但仍不能证明纸张真正出纸。
 */

/** 驱动上报的打印机异常，出现即不可送打或判为送打后异常。 */
const PRINTER_FAULTS = {
  PaperOut: '缺纸',
  PaperJam: '卡纸',
  PaperProblem: '纸张异常',
  ManualFeed: '等待手动进纸',
  Offline: '离线',
  Error: '故障',
  Paused: '已暂停',
  DoorOpen: '盖板打开',
  NoToner: '缺墨',
  OutputBinFull: '出纸托盘已满',
  NotAvailable: '不可用',
  UserIntervention: '需要人工处理',
  OutOfMemory: '内存不足',
  ServerUnknown: '状态未知',
};

/** 打印机仍在处理中的状态：送打后需等其结束再判定。 */
const PRINTER_BUSY = new Set(['Printing', 'Busy', 'Processing', 'IOActive', 'WarmingUp', 'Initializing', 'Waiting']);

/** 队列中单个打印作业的异常状态。 */
const JOB_FAULTS = {
  Error: '出错',
  Offline: '打印机离线',
  PaperOut: '缺纸',
  Blocked: '被阻塞',
  UserIntervention: '需要人工处理',
  Paused: '已暂停',
  Deleting: '已被取消',
  Deleted: '已被取消',
};

/** 队列中单个打印作业的已结束状态。 */
const JOB_DONE = new Set(['Complete', 'Printed']);

function splitFlags(value) {
  return String(value || '')
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean);
}

function describe(flags, table) {
  return flags.filter((flag) => table[flag]).map((flag) => table[flag]);
}

function buildStatusArgs(config, printer) {
  const scriptDir = config.scriptDir || path.join(appRoot(), 'scripts');
  return config.statusCommand.map((part) =>
    part.replace(/\{(printer|scriptDir)\}/g, (_, key) => (key === 'printer' ? printer : scriptDir)),
  );
}

/**
 * 运行 statusCommand 读取打印机状态。命令失败或输出不是约定JSON时抛错，调用方按未就绪处理。
 * @returns {Promise<{printer:string, printerStatus:string, jobs:Array<{id:number, documentName:string, status:string, submittedAt:string}>}>}
 */
function probePrinter(config, printer) {
  const args = buildStatusArgs(config, printer);
  return new Promise((resolve, reject) => {
    const child = spawn(args[0], args.slice(1), {
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr = (stderr + chunk).slice(-300);
    });
    child.on('error', (error) => {
      reject(new Error(`无法读取打印机状态：${error.message}`));
    });
    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`无法读取打印机状态（退出码${code}）：${stderr.trim()}`));
        return;
      }
      let parsed;
      try {
        parsed = JSON.parse(stdout.trim());
      } catch (error) {
        reject(new Error(`打印机状态输出不是JSON：${stdout.trim().slice(0, 120)}`));
        return;
      }
      if (!parsed || typeof parsed.printerStatus !== 'string' || !Array.isArray(parsed.jobs)) {
        reject(new Error('打印机状态输出缺少 printerStatus 或 jobs'));
        return;
      }
      resolve(parsed);
    });
  });
}

/** 打印机自身的异常说明；无异常返回空数组。 */
function printerFaults(snapshot) {
  return describe(splitFlags(snapshot.printerStatus), PRINTER_FAULTS);
}

/**
 * @param {string[]} faults
 * @param {{ignorePaperOut?:boolean}} [options]
 */
function filterPrinterFaults(faults, options = {}) {
  const list = Array.isArray(faults) ? faults.slice() : [];
  if (options.ignorePaperOut) {
    // 打印机 PaperOut →「缺纸」；作业 PaperOut →「作业缺纸」
    return list.filter((fault) => fault !== '缺纸' && fault !== '作业缺纸');
  }
  return list;
}

/** 是否仅为缺纸（可提示用户确认后试打印 / 正式打印）。 */
function isOnlyPaperOut(faults) {
  return Array.isArray(faults) && faults.length > 0 && faults.every((fault) => fault === '缺纸');
}

/**
 * 送打前检查：打印机有已知异常或状态读不到时抛错，不送打。
 * @param {{ignorePaperOut?: boolean}} [options] 用户确认缺纸误报后可忽略缺纸
 */
async function assertPrinterReady(config, printer, options = {}) {
  const snapshot = await probePrinter(config, printer);
  const faults = filterPrinterFaults(printerFaults(snapshot), options);
  if (faults.length) {
    throw new Error(`打印机未就绪：${printer}（${faults.join('、')}）`);
  }
  return snapshot;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * 送打后观察：本单作业在队列里结束、打印机不再忙且连续 printerSettleMs 无异常才算完成。
 * 期间出现缺纸等异常或超过 printerWatchMaxMs 抛错；此时纸可能已出或会在补纸后续打，须人工核对实物。
 * @param {string[]} printers 本单用过的打印机
 * @param {number} sinceMs 本单开始送打的时间戳，用于从队列中挑出本单作业
 */
async function watchAfterSubmit(config, printers, sinceMs, options = {}) {
  const now = options.now || (() => Date.now());
  const wait = options.sleep || sleep;
  const settleMs = options.settleMs != null ? options.settleMs : config.printerSettleMs;
  const maxMs = config.printerWatchMaxMs;
  const pollMs = config.printerPollMs;
  const ignorePaperOut = Boolean(options.ignorePaperOut);
  const startedAt = now();
  const settledSince = new Map();
  const pending = new Set(printers);

  while (pending.size) {
    for (const printer of [...pending]) {
      const snapshot = await probePrinter(config, printer);
      const faults = printerFaults(snapshot);
      const ours = snapshot.jobs.filter((job) =>
        String(job.documentName || '').startsWith('lvpai-')
          && Date.parse(job.submittedAt) >= sinceMs - 5000,
      );
      for (const job of ours) {
        faults.push(...describe(splitFlags(job.status), JOB_FAULTS).map((text) => `作业${text}`));
      }
      const blocking = filterPrinterFaults(faults, { ignorePaperOut });
      if (blocking.length) {
        throw new Error(`已送打印机后出现异常：${printer}（${[...new Set(blocking)].join('、')}）`);
      }
      const jobsDone = ours.every((job) => splitFlags(job.status).some((flag) => JOB_DONE.has(flag)));
      const busy = splitFlags(snapshot.printerStatus).some((flag) => PRINTER_BUSY.has(flag));
      if (!jobsDone || busy) {
        settledSince.delete(printer);
      } else if (!settledSince.has(printer)) {
        settledSince.set(printer, now());
      }
      if (settledSince.has(printer) && now() - settledSince.get(printer) >= settleMs) {
        pending.delete(printer);
      }
    }
    if (!pending.size) return;
    if (now() - startedAt >= maxMs) {
      throw new Error(`等待打印机完成超时（${Math.round(maxMs / 1000)}秒）：${[...pending].join('、')}`);
    }
    await wait(pollMs);
  }
}

/**
 * 尽力取消本机队列中尚未结束的 lvpai-* 作业，避免补纸后驱动自动续打造成多打。
 * 无 statusCommand 或非 Windows 时为空操作；取消失败不抛给业务主路径。
 */
async function cancelPendingLvpaiJobs(config, printer) {
  if (!printer || !Array.isArray(config.statusCommand)) return { cancelled: 0 };
  const platform = config.platform || process.platform;
  if (platform !== 'win32') return { cancelled: 0 };
  const safe = String(printer).replace(/'/g, "''");
  const script = [
    `$ErrorActionPreference='SilentlyContinue'`,
    `$jobs = @(Get-PrintJob -PrinterName '${safe}' | Where-Object {`,
    `  $_.DocumentName -like 'lvpai-*' -and`,
    `  ($_.JobStatus -notmatch 'Completed|Printed|Deleted|Deleting')`,
    `})`,
    `$n = 0`,
    `foreach ($j in $jobs) { try { Remove-PrintJob -InputObject $j; $n++ } catch {} }`,
    `Write-Output $n`,
  ].join('; ');
  return new Promise((resolve) => {
    const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.on('error', () => resolve({ cancelled: 0 }));
    child.on('close', () => {
      const n = Number(String(stdout).trim());
      resolve({ cancelled: Number.isFinite(n) ? n : 0 });
    });
  });
}

module.exports = {
  PRINTER_FAULTS,
  probePrinter,
  printerFaults,
  filterPrinterFaults,
  isOnlyPaperOut,
  assertPrinterReady,
  watchAfterSubmit,
  cancelPendingLvpaiJobs,
};
