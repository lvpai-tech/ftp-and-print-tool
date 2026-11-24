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

test('刷新保留本机打印进度，中断可续打，完成后从待打印移出', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-queue-'));
  let begins = 0;
  let resumes = 0;
  let status = 'QUEUED';
  const downloads = [];
  const results = [];
  const activeRows = [];
  const fileRequested = Promise.withResolvers();
  const releaseFile = Promise.withResolvers();
  const row = {
    id: '501', cardTail: '4987', createdAt: '2026-11-24T02:00:00Z', totalSheets: 2,
  };
  const items = [1, 2].map((id) => ({
    kind: 'SIZE_6', copies: 1, label: '6寸', fileUrl: `/print-agents/jobs/501/files/PHOTO/${id}`,
  }));
  const { server, origin } = await startServer(async (request, response) => {
    const url = new URL(request.url, origin);
    if (url.pathname === '/api/operation/print-agents/jobs' && request.method === 'GET') {
      const filter = url.searchParams.get('printStatus');
      const visible = (filter === 'UNPRINTED' && status === 'QUEUED') || filter === status;
      // 模拟未包含该单的异常页，由本机刚收到的失败结果保留这行。
      const list = visible ? [{ ...row, status }] : [];
      return json(response, { list, total: list.length, pageNum: 1, pageSize: 20 });
    }
    if (url.pathname === '/api/operation/print-agents/jobs/501/begin' && request.method === 'POST') {
      begins += 1;
      status = 'CLAIMED';
      return json(response, { ...row, attempt: begins, completedSheets: 0, items });
    }
    if (url.pathname.endsWith('/continue')) {
      resumes += 1;
      status = 'CLAIMED';
      return json(response, { ...row, attempt: begins + resumes, completedSheets: 1, items });
    }
    if (url.pathname.includes('/files/')) {
      const id = url.pathname.split('/').at(-1);
      downloads.push(id);
      if (id === '1') {
        fileRequested.resolve();
        await releaseFile.promise;
      } else if (resumes === 0) {
        return response.writeHead(503).end('暂时无法取图');
      }
      response.setHeader('Content-Type', 'image/jpeg');
      return response.end(Buffer.from('fake-jpeg'));
    }
    if (url.pathname.includes('/result')) {
      const chunks = [];
      for await (const c of request) chunks.push(c);
      const result = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      results.push(result);
      status = result.status;
      return json(response, { id: '501', status });
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
  }, { configPath: path.join(directory, 'config.json'), scriptDir: directory, lockDir: directory });

  const scheduler = createScheduler({
    config,
    includePrintIssues: true,
    history: createHistory(10),
    autoPrint: false,
    onStateChange({ activePrintJob }) {
      if (activePrintJob) activeRows.push(activePrintJob);
    },
    log() {},
  });

  let printing;
  try {
    const page = await scheduler.refreshJobs();
    assert.equal(page.total, 1);
    assert.equal(page.list[0].id, '501');

    printing = scheduler.printJobIds(['501']);
    await Promise.race([
      fileRequested.promise,
      printing.then(() => assert.fail('取图挂起时打印任务应仍在运行')),
    ]);
    await scheduler.refreshJobs();
    const active = scheduler.getState();
    assert.deepEqual(active.jobPage.list, []);
    assert.deepEqual(active.activePrintJob, {
      ...row, status: 'PRINTING', completedSheets: 0, errorReason: '',
    });
    releaseFile.resolve();

    const failed = await printing;
    assert.equal(failed[0].state, 'FAILED');
    const interrupted = scheduler.getState();
    assert.equal(interrupted.activePrintJob, null);
    assert.equal(interrupted.localPrintIssues[0].status, 'FAILED');
    assert.equal(interrupted.localPrintIssues[0].completedSheets, 1);
    assert(activeRows.some((activeRow) => activeRow.completedSheets === 1));

    const printed = await scheduler.continueJobIds(['501']);
    assert.equal(printed[0].state, 'PRINTED');
    assert.equal(begins, 1);
    assert.equal(resumes, 1);
    assert.deepEqual(downloads, ['1', '2', '2']);
    assert.deepEqual(results.map(({ status, completedSheets }) => [status, completedSheets]), [
      ['FAILED', 1], ['PRINTED', 2],
    ]);
    assert.match(String(results[1].printer || ''), /skip-print/);
    assert.deepEqual(scheduler.getState().localPrintIssues, []);
    assert.deepEqual(scheduler.getState().jobPage.list, []);
    await scheduler.setJobQuery({ printStatus: 'PRINTED' });
    assert.equal(scheduler.getState().jobPage.list[0].id, row.id);
  } finally {
    releaseFile.resolve();
    await printing?.catch(() => {});
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
