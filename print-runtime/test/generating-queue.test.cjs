'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createServer } = require('node:http');
const { createScheduler } = require('../src/scheduler');

test('生成中使用只读接口，晚返回的旧页与旧景区响应不会替换当前队列', async (t) => {
  const requests = [];
  let malformed = false;
  let waiting;
  const firstRequest = new Promise((resolve) => { waiting = resolve; });
  const server = createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    requests.push({ method: request.method, url, token: request.headers['x-print-agent-token'] });
    const sendPage = (list) => {
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify({
        code: 200,
        data: { list, total: list.length, pageNum: Number(url.searchParams.get('pageNum')), pageSize: 20 },
      }));
    };
    if (url.pathname === '/print-agents/generating') {
      const receipt = { receiptId: '9007199254740994', submittedAt: '2026-11-21T09:20:00+08:00' };
      if (url.searchParams.get('pageNum') === '2') {
        waiting(() => sendPage([receipt]));
      } else {
        sendPage([malformed ? { ...receipt, receiptId: '' } : receipt]);
      }
    } else {
      sendPage([{ id: '12', status: 'QUEUED' }]);
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => {
    server.closeAllConnections();
    server.close();
  });
  const config = { base: `http://127.0.0.1:${server.address().port}`, token: 'test-token-a' };
  const scheduler = createScheduler({ config, log() {} });
  const createdFrom = '2026-11-21T09:00:00+08:00';
  const older = scheduler.setJobQuery({ printStatus: 'GENERATING', createdFrom, pageNum: 2 });
  const finishOldRequest = await firstRequest;
  assert.equal(requests[0].url.pathname, '/print-agents/generating');
  assert.equal(requests[0].url.searchParams.get('createdFrom'), createdFrom);
  assert.equal(requests[0].url.searchParams.get('pageNum'), '2');
  assert.equal(requests[0].url.searchParams.has('printStatus'), false);

  scheduler.setConfig({ ...config, token: 'test-token-b' });
  assert.equal(scheduler.getState().jobPage.pageNum, 1);
  assert.deepEqual(scheduler.getState().jobPage.list, []);
  await scheduler.setJobQuery({ printStatus: 'UNPRINTED' });
  finishOldRequest();
  await older;
  assert.deepEqual(scheduler.getState().jobPage.list, [{ id: '12', status: 'QUEUED' }]);
  assert.equal(requests[1].url.pathname, '/print-agents/jobs');
  assert.equal(requests[1].url.searchParams.get('printStatus'), 'UNPRINTED');
  assert.equal(requests[1].token, 'test-token-b');

  const generating = await scheduler.setJobQuery({ printStatus: 'GENERATING' });
  assert.equal(generating.list[0].receiptId, '9007199254740994');
  malformed = true;
  await assert.rejects(scheduler.refreshJobs(), /响应不完整/);
  assert.match(scheduler.getState().listError, /响应不完整/);
  assert.deepEqual(scheduler.getState().jobPage.list, []);
  assert.ok(requests.every(({ method }) => method === 'GET'));
});
