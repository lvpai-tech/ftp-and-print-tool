'use strict';

/**
 * 内存日志环（无 token、无图片内容），供客户端窗口展示。
 */
function createLogBuffer(limit = 500) {
  let max = Math.max(50, Number(limit) || 500);
  const lines = [];
  const listeners = new Set();

  function setLimit(next) {
    max = Math.max(50, Number(next) || 500);
    while (lines.length > max) lines.shift();
  }

  function append(message, level = 'info') {
    const entry = {
      at: new Date().toISOString(),
      level: String(level || 'info'),
      message: String(message == null ? '' : message).slice(0, 2000),
    };
    lines.push(entry);
    while (lines.length > max) lines.shift();
    for (const listener of listeners) {
      try {
        listener(entry);
      } catch {
        /* 忽略 UI 监听异常 */
      }
    }
    return entry;
  }

  function list() {
    return lines.slice();
  }

  function clear() {
    lines.length = 0;
  }

  function subscribe(listener) {
    listeners.add(listener);
    return () => listeners.delete(listener);
  }

  return { append, list, clear, setLimit, subscribe, get limit() { return max; } };
}

module.exports = { createLogBuffer };
