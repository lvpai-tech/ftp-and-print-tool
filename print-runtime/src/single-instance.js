'use strict';

const fs = require('node:fs');
const path = require('node:path');

/**
 * 本机单实例锁（文件锁 + PID）。同机第二个进程启动时失败退出。
 * 注：跨机抢队列仍靠服务端 claim；本锁只防同目录重复启动。
 */
function acquireLock(lockDir, options = {}) {
  const { appRoot } = require('./paths');
  const dir = lockDir || path.join(appRoot(), '.runtime');
  fs.mkdirSync(dir, { recursive: true });
  const lockPath = path.join(dir, 'print-desktop.lock');
  const payload = `${process.pid}\n${new Date().toISOString()}\n`;

  function tryCreate() {
    const fd = fs.openSync(lockPath, 'wx');
    fs.writeFileSync(fd, payload);
    fs.closeSync(fd);
  }

  try {
    tryCreate();
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    let stale = false;
    try {
      const existing = fs.readFileSync(lockPath, 'utf8');
      const pid = Number((existing.split(/\r?\n/)[0] || '').trim());
      if (!pid || !isPidAlive(pid)) stale = true;
      else if (options.force) stale = true;
    } catch {
      stale = true;
    }
    if (!stale) {
      const err = new Error(`已有实例在运行（锁文件：${lockPath}）`);
      err.code = 'ELOCKED';
      throw err;
    }
    try {
      fs.unlinkSync(lockPath);
    } catch {
      /* ignore */
    }
    tryCreate();
  }

  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    try {
      const existing = fs.readFileSync(lockPath, 'utf8');
      const pid = Number((existing.split(/\r?\n/)[0] || '').trim());
      if (pid === process.pid) fs.unlinkSync(lockPath);
    } catch {
      /* ignore */
    }
  };

  process.on('exit', release);
  process.on('SIGINT', () => {
    release();
    process.exit(0);
  });
  process.on('SIGTERM', () => {
    release();
    process.exit(0);
  });

  return { lockPath, release };
}

function isPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error && error.code === 'EPERM';
  }
}

module.exports = { acquireLock, isPidAlive };
