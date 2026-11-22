'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { claimJob, downloadFile, reportResult } = require('./api');
const { resolvePrinter, runPrintCommand, summarizePrinters } = require('./print');
const { assertPrinterReady, watchAfterSubmit, cancelPendingLvpaiJobs } = require('./printer-status');
const { usesMacPrintScript } = require('./mac-printer');

const CHECK_PAPER_HINT =
  '请核对实物：剩余未出点「继续打印」；纸已齐点「确认已打印」；要整单重打先「标记未打印」';

/**
 * 将条目按 copies 展开为单张（每张 copies=1），保证缺纸时可精确记进度。
 * @param {Array<{kind:string,copies?:number,label?:string,fileUrl:string}>} items
 */
function expandSheets(items) {
  const sheets = [];
  for (const item of items || []) {
    if (!item) continue;
    const copies = Math.max(1, Number(item.copies) || 1);
    for (let i = 0; i < copies; i += 1) {
      sheets.push({
        kind: item.kind,
        copies: 1,
        label: item.label || item.kind,
        fileUrl: item.fileUrl,
      });
    }
  }
  return sheets;
}

/**
 * 处理已领取的 PHOTOS 任务（下载→逐张本机打印并观察→回写）。
 * 配置了 statusCommand 时：每张送打前检查、送打后观察完成才计入进度；缺纸等异常整单 FAILED 并带 completedSheets。
 * 未配置 statusCommand 时，全部命令退出码 0 即 PRINTED（无法分张确认）。
 * 回写网络失败会重试后抛错，调用方不得因此再次 claim 同一任务或本地重打。
 */
async function processClaimedJob(config, job, hooks = {}) {
  if (!job) return { state: 'IDLE' };

  if (typeof hooks.onClaimed === 'function') {
    hooks.onClaimed(job);
  }

  // 防御：claim 接口应只发 PHOTOS；若服务端误下发其它 target，整单 FAILED，不落盘、不出片。
  if (job.target != null && String(job.target).toUpperCase() !== 'PHOTOS') {
    const reason = `拒绝非PHOTOS任务：${job.target}`.slice(0, 480);
    await reportResult(config, job.id, { status: 'FAILED', printer: '', reason, completedSheets: 0 });
    return { state: 'FAILED', jobId: job.id, reason, printer: '', completedSheets: 0 };
  }

  const directory = fs.mkdtempSync(path.join(os.tmpdir(), `print-job-${job.id}-`));
  const usedPrinters = [];
  const sheets = expandSheets(job.items || []);
  const totalSheets = sheets.length;
  const startAt = Math.max(0, Math.min(totalSheets, Number(job.completedSheets) || 0));
  const skipPrint = Boolean(hooks.skipPrint || config.skipPrint);
  const ignorePaperOut = Boolean(hooks.ignorePaperOut);
  const checkPrinter = !skipPrint && Array.isArray(config.statusCommand);
  const requireCupsJobId = checkPrinter && (usesMacPrintScript(config.command)
    || config.statusCommand.some((part) => part.includes('{jobId}')));
  let completedSheets = startAt;
  let printerSummary = '';
  const fileCache = new Map();

  const sheetSettleMs =
    config.printerSheetSettleMs != null
      ? config.printerSheetSettleMs
      : Math.min(Number(config.printerSettleMs) || 30000, 10000);

  try {
    for (let index = startAt; index < sheets.length; index += 1) {
      const item = sheets[index];
      const printer = resolvePrinter(config, item.kind);
      let cached = fileCache.get(item.fileUrl);
      if (!cached) {
        const { buffer, contentType } = await downloadFile(config, item.fileUrl);
        const extension = contentType.includes('png') ? '.png' : '.jpg';
        const file = path.join(directory, `${fileCache.size}-${item.kind}${extension}`);
        fs.writeFileSync(file, buffer);
        cached = { file };
        fileCache.set(item.fileUrl, cached);
      }
      if (skipPrint) {
        usedPrinters.push({ kind: item.kind, printer: `${printer || 'dry'}(skip-print)` });
        completedSheets = index + 1;
      } else {
        if (checkPrinter) await assertPrinterReady(config, printer, { ignorePaperOut });
        const submittedAt = Date.now();
        const { cupsJobId } = await runPrintCommand(config, item, cached.file, printer);
        usedPrinters.push({ kind: item.kind, printer });
        if (checkPrinter) {
          try {
            if (requireCupsJobId && cupsJobId == null) throw new Error('系统已受理，但未返回可核对的 CUPS 作业编号');
            await watchAfterSubmit(config, [printer], submittedAt, {
              ...hooks.watchOptions,
              settleMs: sheetSettleMs,
              ignorePaperOut,
              cupsJobId: requireCupsJobId ? cupsJobId : undefined,
            });
          } catch (error) {
            let cancellation = '';
            if (!requireCupsJobId || cupsJobId != null) {
              const { cancelled } = await cancelPendingLvpaiJobs(config, printer, requireCupsJobId ? cupsJobId : undefined)
                .catch(() => ({ cancelled: 0 }));
              if (requireCupsJobId) cancellation = `。CUPS 作业 ${cupsJobId}${cancelled ? '已受理取消' : '未确认取消'}`;
            }
            throw new Error(`${error.message}${cancellation}。${CHECK_PAPER_HINT}`);
          }
        }
        completedSheets = index + 1;
      }
      if (typeof hooks.onItemPrinted === 'function') {
        hooks.onItemPrinted({
          jobId: job.id,
          kind: item.kind,
          printer,
          skipPrint,
          sheetIndex: index,
          completedSheets,
          totalSheets,
        });
      }
    }
    printerSummary = summarizePrinters(usedPrinters);
  } catch (error) {
    const progress =
      totalSheets > 0 ? `（已完成${completedSheets}/${totalSheets}张，待继续）` : '';
    const reason = `${error.message}${progress}`.slice(0, 480);
    printerSummary = summarizePrinters(usedPrinters) || (config.defaultPrinter || '');
    await reportResult(config, job.id, {
      status: 'FAILED',
      printer: printerSummary,
      reason,
      completedSheets,
    });
    return {
      state: 'FAILED',
      jobId: job.id,
      reason,
      printer: printerSummary,
      completedSheets,
      totalSheets,
    };
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }

  await reportResult(config, job.id, {
    status: 'PRINTED',
    printer: printerSummary,
    completedSheets: totalSheets,
  });
  return {
    state: 'PRINTED',
    jobId: job.id,
    printer: printerSummary,
    completedSheets: totalSheets,
    totalSheets,
  };
}

/**
 * 领取并处理一个 PHOTOS 任务。
 */
async function runOnce(config, hooks = {}) {
  const job = await claimJob(config);
  if (!job) return { state: 'IDLE' };
  return processClaimedJob(config, job, hooks);
}

module.exports = { runOnce, processClaimedJob, expandSheets };
