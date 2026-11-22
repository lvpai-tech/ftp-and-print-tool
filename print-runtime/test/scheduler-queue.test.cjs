'use strict';

/**
 * 在线列表 + begin 打印；skipPrint 不调打印机。
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { createScheduler } = require('../src/scheduler');
const { normalizeConfig } = require('../src/config');
const { createHistory } = require('../src/history');

function startServer(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () =>
      resolve({ server, origin: `http://127.0.0.1:${server.address().port}` }),
    );
  });
}

function json(response, data) {
  response.setHeader('Content-Type', 'application/json');
  response.end(JSON.stringify({ code: 200, message: 'success', data }));
}

test('列表查询 + 手动 begin 打印走 skipPrint 回报 PRINTED', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-queue-'));
  let begins = 0;
  let downloads = 0;
  let results = [];
  const { server, origin } = await startServer(async (request, response) => {
    const url = new URL(request.url, origin);
    if (url.pathname === '/api/operation/print-agents/jobs' && request.method === 'GET') {
      return json(response, {
        list: [{ id: '501', status: 'QUEUED', createdAt: new Date().toISOString() }],
        total: 1,
        pageNum: 1,
        pageSize: 20,
      });
    }
    if (url.pathname === '/api/operation/print-agents/jobs/501/begin' && request.method === 'POST') {
      begins += 1;
      return json(response, {
        id: '501',
        scenicId: '1',
        leaseUntil: new Date(Date.now() + 3600000).toISOString(),
        items: [
          { kind: 'SIZE_6', copies: 1, label: '6寸', fileUrl: '/print-agents/jobs/501/files/PHOTO/1' },
        ],
      });
    }
    if (url.pathname.includes('/files/')) {
      downloads += 1;
      response.setHeader('Content-Type', 'image/jpeg');
      return response.end(Buffer.from('fake-jpeg'));
    }
    if (url.pathname.includes('/result')) {
      const chunks = [];
      for await (const c of request) chunks.push(c);
      results.push(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      return json(response, { id: '501', status: 'PRINTED' });
    }
    response.statusCode = 404;
    response.end('no');
  });

  const config = normalizeConfig({
    base: `${origin}/api/operation`,
    token: 'queue-test-token-xxxx',
    scenicIds: ['1'],
    autoPrintMs: 600000,
    listRefreshMs: 600000,
    autoPrint: false,
    skipPrint: true,
    command: [process.execPath, '-e', 'throw new Error("should not print")'],
    printers: { SIZE_6: '虚拟机' },
  }, { configPath: path.join(directory, 'config.json'), scriptDir: directory });

  const scheduler = createScheduler({
    config,
    history: createHistory(10),
    autoPrint: false,
    log() {},
  });

  try {
    scheduler.start();
    await new Promise((r) => setTimeout(r, 80));
    const page = await scheduler.refreshJobs();
    assert.equal(page.total, 1);
    assert.equal(page.list[0].id, '501');

    const printed = await scheduler.printJobIds(['501']);
    assert.equal(printed[0].state, 'PRINTED');
    assert.equal(begins, 1);
    assert.equal(downloads, 1);
    assert.equal(results.length, 1);
    assert.equal(results[0].status, 'PRINTED');
    assert.match(String(results[0].printer || ''), /skip-print/);
  } finally {
    scheduler.stop();
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('待打印单独读取打印异常，其他标签不查询异常', async (t) => {
  const filters = [];
  const { server, origin } = await startServer((request, response) => {
    const filter = new URL(request.url, origin).searchParams.get('printStatus');
    filters.push(filter);
    const list = filter === 'EXCEPTIONS' ? [{ id: '11', status: 'UNKNOWN' }] : [];
    return json(response, { list, total: list.length, pageNum: 1, pageSize: 10 });
  });
  t.after(() => server.close());
  const scheduler = createScheduler({
    config: { base: origin + '/api/operation', token: 'issue-test-token' },
    includePrintIssues: true,
  });
  await scheduler.refreshJobs();
  assert.deepEqual(filters.sort(), ['EXCEPTIONS', 'UNPRINTED']);
  assert.equal(scheduler.getState().jobPage.total, 0);
  assert.equal(scheduler.getState().printIssues.list[0].status, 'UNKNOWN');
  filters.length = 0;
  await scheduler.setJobQuery({ printStatus: 'PRINTED' });
  assert.deepEqual(filters, ['PRINTED']);
  assert.equal(scheduler.getState().printIssues, null);
});

test('确认已打印：只提交失败/待核对任务，不调用 begin', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-confirm-'));
  const confirms = [];
  let begins = 0;
  const { server, origin } = await startServer(async (request, response) => {
    const url = new URL(request.url, origin);
    if (url.pathname === '/api/operation/print-agents/jobs' && request.method === 'GET') {
      return json(response, {
        list: [
          { id: '901', status: confirms.length ? 'PRINTED' : 'FAILED' },
          { id: '902', status: 'UNKNOWN' },
          { id: '903', status: 'QUEUED' },
        ],
        total: 3,
        pageNum: 1,
        pageSize: 20,
      });
    }
    if (url.pathname === '/api/operation/print-agents/jobs/confirm-printed' && request.method === 'POST') {
      const chunks = [];
      for await (const c of request) chunks.push(c);
      confirms.push(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      return json(response, []);
    }
    if (url.pathname.endsWith('/begin')) begins += 1;
    response.statusCode = 404;
    response.end('no');
  });
  const scheduler = createScheduler({
    config: normalizeConfig({
      base: `${origin}/api/operation`,
      token: 'confirm-test-token-xxxx',
      scenicIds: ['1'],
      autoPrintMs: 600000,
      listRefreshMs: 600000,
      command: [process.execPath, '-e', 'throw new Error("should not print")'],
      statusCommand: null,
      printers: { SIZE_6: '虚拟' },
    }, { configPath: path.join(directory, 'c.json'), scriptDir: directory }),
    history: createHistory(5),
    autoPrint: false,
    log() {},
  });
  try {
    await scheduler.refreshJobs();
    await assert.rejects(scheduler.confirmPrinted(['903']), /只能确认失败或待核对的任务已打印/);
    assert.equal(confirms.length, 0);
    await scheduler.confirmPrinted(['901', '902']);
    assert.deepEqual(confirms, [{ ids: [901, 902] }]);
    assert.equal(begins, 0);
    assert.equal(scheduler.getState().jobPage.list[0].status, 'PRINTED');
  } finally {
    scheduler.stop();
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('自动打印：拉 UNPRINTED 并 begin（仍可 skipPrint）', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-auto-'));
  let results = [];
  let begins = 0;
  const { server, origin } = await startServer(async (request, response) => {
    const url = new URL(request.url, origin);
    if (url.pathname === '/api/operation/print-agents/jobs' && request.method === 'GET') {
      const status = url.searchParams.get('printStatus') || 'ALL';
      if (status === 'UNPRINTED') {
        return json(response, {
          list: [{ id: '601', status: 'QUEUED' }],
          total: 1,
          pageNum: 1,
          pageSize: 20,
        });
      }
      return json(response, { list: [], total: 0, pageNum: 1, pageSize: 20 });
    }
    if (url.pathname.endsWith('/begin')) {
      begins += 1;
      return json(response, {
        id: '601',
        leaseUntil: new Date(Date.now() + 3600000).toISOString(),
        items: [{ kind: 'ORIGINAL', copies: 1, fileUrl: '/print-agents/jobs/601/files/PHOTO/1' }],
      });
    }
    if (url.pathname.includes('/files/')) {
      response.setHeader('Content-Type', 'image/jpeg');
      return response.end(Buffer.from('x'));
    }
    if (url.pathname.includes('/result')) {
      const chunks = [];
      for await (const c of request) chunks.push(c);
      results.push(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      return json(response, { id: '601' });
    }
    response.end('{}');
  });

  const config = normalizeConfig({
    base: `${origin}/api/operation`,
    token: 'auto-test-token-xxxx',
    scenicIds: ['1'],
    autoPrintMs: 600000,
    listRefreshMs: 600000,
    autoPrint: true,
    skipPrint: true,
    command: [process.execPath, '-e', 'process.exit(1)'],
    printers: { ORIGINAL: '虚拟' },
  }, { configPath: path.join(directory, 'c.json'), scriptDir: directory });

  const scheduler = createScheduler({
    config,
    history: createHistory(5),
    autoPrint: true,
    log() {},
  });
  try {
    scheduler.start();
    await scheduler.runAutoPrintCycle();
    assert.equal(begins, 1);
    assert.equal(results[0].status, 'PRINTED');
  } finally {
    scheduler.stop();
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
