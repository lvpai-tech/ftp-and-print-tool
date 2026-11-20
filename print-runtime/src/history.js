'use strict';

/**
 * 内存中保留最近 N 条任务结果（无 token、无图片路径内容）。
 */
function createHistory(limit = 20) {
  let max = Math.max(1, Number(limit) || 20);
  const items = [];

  function setLimit(next) {
    max = Math.max(1, Number(next) || 20);
    while (items.length > max) items.pop();
  }

  function push(entry) {
    items.unshift({
      at: entry.at || new Date().toISOString(),
      jobId: entry.jobId != null ? String(entry.jobId) : '',
      state: entry.state || '',
      printer: entry.printer || '',
      reason: entry.reason ? String(entry.reason).slice(0, 480) : '',
    });
    while (items.length > max) items.pop();
    return items[0];
  }

  function list() {
    return items.slice();
  }

  function clear() {
    items.length = 0;
  }

  return { push, list, clear, setLimit, get limit() { return max; } };
}

module.exports = { createHistory };
