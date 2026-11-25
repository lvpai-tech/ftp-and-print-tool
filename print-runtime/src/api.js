'use strict';

/**
 * OP10 打印代理 HTTP：任务列表 / begin / 文件下载 / result。
 * Token 仅放请求头，调用方不得把 token 或图片内容写入日志。
 */

async function call(config, method, route, body, signal, { redirect } = {}) {
  const personnel = config.authorizeRequest?.(route, config.token);
  const response = await fetch(config.base + route, {
    method,
    headers: {
      'X-Print-Agent-Token': config.token,
      ...(personnel ? { Authorization: 'Bearer ' + personnel } : {}),
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal,
    redirect: redirect || 'error',
  });
  return response;
}

async function callJson(config, method, route, body, signal, options) {
  const response = await call(config, method, route, body, signal, options);
  const payload = await response.json().catch(() => null);
  if (!payload || payload.code !== 200) {
    const detail = payload && payload.code != null
      ? `${payload.code} ${payload.message || ''}`.trim()
      : `HTTP ${response.status}${payload && payload.error ? ` ${payload.error}` : ''}`;
    const error = new Error(`${method} ${route} 失败：${detail}`);
    error.resultCode = payload?.code;
    error.httpStatus = response.status;
    if (response.status === 401 || payload?.code === 40101 || payload?.code === 40102) {
      error.authorizationLost = true;
      error.message = config.authorizeRequest ? '人员会话或打印设备授权无法使用，请返回工作台核对'
        : '打印设备授权无效或已撤销，请联系运营';
    }
    throw error;
  }
  return payload.data;
}

function sendCrashReport(config, report) {
  return callJson(config, 'POST', '/print-agents/crash-reports', report,
    AbortSignal.timeout(10000), { redirect: 'error' });
}

function listBatchStations(config) {
  return callJson(config, 'GET', '/print-agents/photo-batches/stations', undefined, AbortSignal.timeout(30000));
}

function batchStationRoute(stationId) {
  if (typeof stationId !== 'string' || !/^[1-9]\d*$/.test(stationId)) throw new Error('机位编号无效');
  return `/print-agents/photo-batches/stations/${stationId}`;
}

function listPhotoBatches(config, { stationId, from, to }) {
  const params = new URLSearchParams({ from, to });
  return callJson(config, 'GET', `${batchStationRoute(stationId)}?${params}`, undefined, AbortSignal.timeout(30000));
}

function correctPhotoBatch(config, stationId, correction) {
  return callJson(config, 'POST', `${batchStationRoute(stationId)}/corrections`, correction,
    AbortSignal.timeout(120000));
}

function previewPhotoBatchSplit(config, { stationId, from, to, beforePhotoId, afterPhotoId }) {
  const params = new URLSearchParams({ from, to, beforePhotoId, afterPhotoId });
  return callJson(config, 'GET', `${batchStationRoute(stationId)}/split-preview?${params}`,
    undefined, AbortSignal.timeout(30000));
}

function savePhotoBatchSplit(config, { stationId, from, to }, split) {
  const params = new URLSearchParams({ from, to });
  return callJson(config, 'POST', `${batchStationRoute(stationId)}/splits?${params}`, split,
    AbortSignal.timeout(120000));
}

function movePhotoBatchPhoto(config, { stationId, from, to }, move) {
  const params = new URLSearchParams({ from, to });
  return callJson(config, 'POST', `${batchStationRoute(stationId)}/moves?${params}`, move,
    AbortSignal.timeout(30000));
}

function removePhotoBatch(config, { stationId, from, to }, request) {
  const params = new URLSearchParams({ from, to });
  return callJson(config, 'POST', `${batchStationRoute(stationId)}/removals?${params}`, request,
    AbortSignal.timeout(120000));
}

function batchPhotoRoute(stationId, photoId) {
  if (typeof photoId !== 'string' || !/^[1-9]\d*$/.test(photoId)) throw new Error('照片编号无效');
  return `${batchStationRoute(stationId)}/photos/${photoId}`;
}

function getBatchPhotoCapture(config, stationId, photoId) {
  return callJson(config, 'GET', `${batchPhotoRoute(stationId, photoId)}/capture`,
    undefined, AbortSignal.timeout(30000));
}

function removeBatchPhoto(config, stationId, photoId, request) {
  return callJson(config, 'POST', `${batchPhotoRoute(stationId, photoId)}/removals`,
    request, AbortSignal.timeout(30000));
}

/** 用当前密钥查询绑定景区；失败显式抛错，不做静默兜底。 */
async function fetchMe(config) {
  return callJson(config, 'GET', '/print-agents/me');
}

/**
 * 分页查询本景区打印任务。
 * @param {{ printStatus?: string, createdFrom?: string, createdTo?: string, pageNum?: number, pageSize?: number }} query
 */
async function listJobs(config, query = {}, signal) {
  const params = pageParams(query);
  params.set('printStatus', query.printStatus || 'ALL');
  return callJson(config, 'GET', `/print-agents/jobs?${params.toString()}`, undefined, signal);
}

/** 查看本景区还在生成的取片单，使用独立的只读接口。 */
async function listGenerating(config, query) {
  const params = pageParams(query);
  const page = await callJson(config, 'GET', `/print-agents/generating?${params.toString()}`);
  if (!page || !Array.isArray(page.list) || !Number.isSafeInteger(page.total) ||
      !Number.isSafeInteger(page.pageNum) || !Number.isSafeInteger(page.pageSize) ||
      page.list.some((row) => typeof row?.receiptId !== 'string' || !row.receiptId ||
        typeof row.submittedAt !== 'string' || !Number.isFinite(Date.parse(row.submittedAt)) ||
        !validGeneratingDetails(row))) {
    throw new Error('生成中任务列表响应不完整');
  }
  return page;
}

const generatingThumbnailPath = /^\/print-agents\/generating\/([1-9]\d*)\/original-thumbnails\/[1-9]\d*$/;

function validGeneratingDetails(row) {
  const fields = ['originalThumbnailUrls', 'originalPhotoCount', 'estimatedTotalSheets', 'estimatedContentSummary'];
  // 已部署的旧接口没有预览和明细；界面会明确标记该服务版本不提供这些信息。
  if (fields.every((field) => !Object.hasOwn(row, field))) return true;
  const { originalThumbnailUrls: urls, originalPhotoCount: count, estimatedTotalSheets: total,
    estimatedContentSummary: summary } = row;
  return (count === null || (Number.isSafeInteger(count) && count >= 0)) &&
    Array.isArray(urls) && urls.length === Math.min(count ?? 0, 3) &&
    urls.every((url) => typeof url === 'string' && generatingThumbnailPath.exec(url)?.[1] === row.receiptId) &&
    (total === null || (Number.isSafeInteger(total) && total > 0 && count !== null && total >= count)) &&
    typeof summary === 'string' && summary.trim().length > 0;
}

function pageParams(query) {
  const params = new URLSearchParams({
    pageNum: String(query.pageNum || 1),
    pageSize: String(query.pageSize || 20),
  });
  if (query.createdFrom) params.set('createdFrom', query.createdFrom);
  if (query.createdTo) params.set('createdTo', query.createdTo);
  return params;
}

/** 占单并返回打印条目（下载前必须调用）。 */
async function beginJob(config, jobId) {
  return callJson(config, 'POST', `/print-agents/jobs/${jobId}/begin`);
}

/** 继续打印：FAILED 且有分张进度时占单，客户端从 completedSheets 起打剩余。 */
async function continueJob(config, jobId) {
  return callJson(config, 'POST', `/print-agents/jobs/${jobId}/continue`);
}

async function recoverJob(config, jobId, attempt) {
  return callJson(config, 'POST', `/print-agents/jobs/${jobId}/recover`, { attempt }, AbortSignal.timeout(10000));
}

/** 打前核对：只读条目清单，不占单。 */
async function previewJob(config, jobId, signal) {
  return callJson(config, 'GET', `/print-agents/jobs/${jobId}/preview`, undefined, signal);
}

/** @deprecated 兼容旧测试；正式路径用 listJobs + beginJob */
async function claimJob(config) {
  const body = config.scenicIds && config.scenicIds.length ? { scenicIds: config.scenicIds } : {};
  return callJson(config, 'POST', '/print-agents/jobs/claim', body);
}

async function downloadFile(config, fileUrl, signal) {
  const response = await call(config, 'GET', fileUrl, undefined, signal);
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    const error = new Error(`下载失败：HTTP ${response.status}`);
    error.httpStatus = response.status;
    throw error;
  }
  const contentType = response.headers.get('content-type') || '';
  const buffer = Buffer.from(await response.arrayBuffer());
  if (contentType.toLowerCase().includes('json')) {
    let code = '';
    try { code = JSON.parse(buffer.toString('utf8')).code; } catch { /* 非法JSON也必须拒绝。 */ }
    throw new Error(`图片接口返回错误响应${code ? `（错误码 ${code}）` : ''}，请核对服务版本`);
  }
  return { buffer, contentType };
}

function printJobIds(ids) {
  return (ids || []).flatMap((id) => {
    const exact = String(id);
    if (!/^[1-9][0-9]*$/.test(exact)) return [];
    const number = Number(exact);
    return [Number.isSafeInteger(number) ? number : exact];
  });
}

/**
 * 将失败/已打印任务改回未打印（QUEUED）。
 * @param {string[]|number[]} ids
 */
async function requeueJobs(config, ids) {
  const list = printJobIds(ids);
  if (!list.length) throw new Error('请勾选要标记的任务');
  return callJson(config, 'POST', '/print-agents/jobs/requeue', { ids: list });
}

/**
 * 核对纸面后确认失败/待核对任务已打印（改为 PRINTED，不触发打印）。
 * @param {string[]|number[]} ids
 */
async function confirmPrintedJobs(config, ids) {
  const list = printJobIds(ids);
  if (!list.length) throw new Error('请勾选要确认的任务');
  return callJson(config, 'POST', '/print-agents/jobs/confirm-printed', { ids: list });
}

async function reportResult(config, jobId, result, options = {}) {
  let lastError;
  const retries = options.retries ?? (config.resultRetries || 5);
  for (let attempt = 0; attempt < retries; attempt += 1) {
    try {
      return await callJson(config, 'POST', `/print-agents/jobs/${jobId}/result`, result, AbortSignal.timeout(10000));
    } catch (error) {
      lastError = error;
    }
    if (attempt + 1 < retries) await new Promise((resolve) => setTimeout(resolve, 1000 * (attempt + 1)));
  }
  throw lastError;
}

module.exports = {
  call,
  callJson,
  fetchMe,
  listJobs,
  listGenerating,
  sendCrashReport,
  listBatchStations,
  listPhotoBatches,
  correctPhotoBatch,
  previewPhotoBatchSplit,
  savePhotoBatchSplit,
  movePhotoBatchPhoto,
  removeBatchPhoto,
  removePhotoBatch,
  getBatchPhotoCapture,
  generatingThumbnailPath,
  beginJob,
  continueJob,
  recoverJob,
  previewJob,
  claimJob,
  downloadFile,
  requeueJobs,
  confirmPrintedJobs,
  reportResult,
};
