'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createScheduler } = require('../src/scheduler');
const { createHistory } = require('../src/history');

test('调度：自动打印开关与停止', async () => {
  const history = createHistory(5);
  const scheduler = createScheduler({
    config: {
      token: 'x',
      base: 'http://127.0.0.1:9',
      autoPrintMs: 600000,
      listRefreshMs: 600000,
      historyLimit: 5,
    },
    history,
    autoPrint: false,
    log: () => {},
  });

  scheduler.start();
  assert.equal(scheduler.getState().autoPrint, false);
  scheduler.setAutoPrint(true);
  assert.equal(scheduler.getState().autoPrint, true);
  scheduler.setAutoPrint(false);
  assert.equal(scheduler.getState().autoPrint, false);
  scheduler.stop();
  assert.equal(scheduler.getState().phase, 'stopped');
});

test('history：保留最近 N 条', () => {
  const history = createHistory(2);
  history.push({ jobId: '1', state: 'PRINTED' });
  history.push({ jobId: '2', state: 'FAILED', reason: 'x' });
  history.push({ jobId: '3', state: 'PRINTED' });
  assert.equal(history.list().length, 2);
  assert.equal(history.list()[0].jobId, '3');
  assert.equal(history.list()[1].jobId, '2');
});
