'use strict';

/**
 * 缺纸等打印机异常：送打前拦截、送打后观察、领单前不领。
 * 打印机状态由假状态脚本按序吐出，不碰本机真实打印机。
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { normalizeConfig } = require('../src/config');
const { runOnce } = require('../src/agent');
const { createScheduler } = require('../src/scheduler');
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

async function body(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null;
}

/**
 * 准备目录：假打印脚本记录送打，假状态脚本依次输出 states 中的快照（用完后重复最后一个）。
 * 快照的 jobs 为状态字符串数组，提交时间取输出当下。
 */
function setup(states) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-status-'));
  const printScript = path.join(directory, 'print.cjs');
  fs.writeFileSync(
    printScript,
    `require('node:fs').appendFileSync(process.argv[2] + '/printed.log', process.argv[3] + '\\n');`,
  );
  const statusScript = path.join(directory, 'status.cjs');
  fs.writeFileSync(path.join(directory, 'states.json'), JSON.stringify(states));
  fs.writeFileSync(
    statusScript,
    `const fs=require('node:fs');const dir=process.argv[2];const printer=process.argv[3];
const file=dir+'/states.json';const states=JSON.parse(fs.readFileSync(file,'utf8'));
const current=states.length>1?states.shift():states[0];fs.writeFileSync(file,JSON.stringify(states));
fs.appendFileSync(dir+'/probes.log',printer+'\\n');
const jobs=(current.jobs||[]).map((status,i)=>({id:i+1,documentName:'lvpai-SIZE_6',status,submittedAt:new Date().toISOString()}));
process.stdout.write(JSON.stringify({printer,printerStatus:current.printer,jobs}));`,
  );
  return { directory, printScript, statusScript };
}

function lines(directory, name) {
  const file = path.join(directory, name);
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean) : [];
}

function makeConfig(origin, env, extra = {}) {
  return normalizeConfig(
    {
      base: `${origin}/api/operation`,
      token: 'isolated-print-status-token',
      scenicIds: ['1'],
      resultRetries: 2,
      skipPrint: false,
      printers: { SIZE_6: '打印机-6寸', ORIGINAL: '打印机-6寸' },
      command: [process.execPath, env.printScript, env.directory, '{kind}'],
      statusCommand: [process.execPath, env.statusScript, env.directory, '{printer}'],
      printerSettleMs: 1,
      printerPollMs: 1,
      printerWatchMaxMs: 2000,
      ...extra,
    },
    { configPath: path.join(env.directory, 'config.json'), scriptDir: env.directory },
  );
}

function photoJobServer(jobId, items, results) {
  return startServer(async (request, response) => {
    if (request.url.endsWith('/claim')) return json(response, { id: jobId, items });
    if (request.url.includes('/files/')) {
      response.setHeader('Content-Type', 'image/jpeg');
      return response.end(Buffer.from('img'));
    }
    results.push(await body(request));
    return json(response, { id: jobId });
  });
}

const SIZE6 = { kind: 'SIZE_6', copies: 1, label: '6寸', fileUrl: '/print-agents/jobs/1/files/PHOTO/1' };
const ORIGINAL = { kind: 'ORIGINAL', copies: 1, label: '原片', fileUrl: '/print-agents/jobs/1/files/PHOTO/2' };

test('送打前缺纸→FAILED，不调用打印命令', async () => {
  const env = setup([{ printer: 'PaperOut' }]);
  const results = [];
  const { server, origin } = await photoJobServer('701', [SIZE6], results);
  try {
    const result = await runOnce(makeConfig(origin, env));
    assert.equal(result.state, 'FAILED');
    assert.match(result.reason, /打印机未就绪：打印机-6寸（缺纸）/);
    assert.equal(results[0].status, 'FAILED');
    assert.deepEqual(lines(env.directory, 'printed.log'), []);
  } finally {
    server.close();
    fs.rmSync(env.directory, { recursive: true, force: true });
  }
});

test('送打后打印机报缺纸→FAILED并提示核对实物，不报已打印', async () => {
  const env = setup([
    { printer: 'Normal' },
    { printer: 'Normal', jobs: ['Spooling'] },
    { printer: 'PaperOut', jobs: ['Complete, Retained'] },
  ]);
  const results = [];
  const { server, origin } = await photoJobServer('702', [SIZE6], results);
  try {
    const result = await runOnce(makeConfig(origin, env));
    assert.equal(result.state, 'FAILED');
    assert.match(result.reason, /已送打印机后出现异常：打印机-6寸（缺纸）/);
    assert.match(result.reason, /核对实物/);
    assert.equal(results[0].status, 'FAILED');
    assert.deepEqual(lines(env.directory, 'printed.log'), ['SIZE_6']);
  } finally {
    server.close();
    fs.rmSync(env.directory, { recursive: true, force: true });
  }
});

test('队列作业报错→FAILED', async () => {
  const env = setup([{ printer: 'Normal' }, { printer: 'Normal', jobs: ['Error, Printing'] }]);
  const results = [];
  const { server, origin } = await photoJobServer('703', [SIZE6], results);
  try {
    const result = await runOnce(makeConfig(origin, env));
    assert.equal(result.state, 'FAILED');
    assert.match(result.reason, /作业出错/);
  } finally {
    server.close();
    fs.rmSync(env.directory, { recursive: true, force: true });
  }
});

test('作业结束且打印机持续正常→PRINTED', async () => {
  const env = setup([
    { printer: 'Normal' },
    { printer: 'Printing', jobs: ['Printing'] },
    { printer: 'Normal', jobs: ['Complete, Retained'] },
  ]);
  const results = [];
  const { server, origin } = await photoJobServer('704', [SIZE6], results);
  try {
    const result = await runOnce(makeConfig(origin, env, { printerSettleMs: 5, printerPollMs: 2 }));
    assert.equal(result.state, 'PRINTED');
    assert.equal(results[0].status, 'PRINTED');
  } finally {
    server.close();
    fs.rmSync(env.directory, { recursive: true, force: true });
  }
});

test('打印机一直忙→超时FAILED', async () => {
  const env = setup([{ printer: 'Normal' }, { printer: 'Printing', jobs: ['Printing'] }]);
  const results = [];
  const { server, origin } = await photoJobServer('705', [SIZE6], results);
  try {
    const result = await runOnce(makeConfig(origin, env, { printerWatchMaxMs: 30, printerPollMs: 5 }));
    assert.equal(result.state, 'FAILED');
    assert.match(result.reason, /等待打印机完成超时/);
    assert.match(result.reason, /核对实物/);
  } finally {
    server.close();
    fs.rmSync(env.directory, { recursive: true, force: true });
  }
});

test('第二项送打前缺纸→FAILED并写明已完成张数', async () => {
  const env = setup([
    { printer: 'Normal' },
    { printer: 'Normal', jobs: ['Complete, Retained'] },
    { printer: 'Normal', jobs: ['Complete, Retained'] },
    { printer: 'PaperOut' },
  ]);
  const results = [];
  const { server, origin } = await photoJobServer('706', [SIZE6, ORIGINAL], results);
  try {
    const result = await runOnce(makeConfig(origin, env, { printerSettleMs: 1, printerSheetSettleMs: 1, printerPollMs: 1 }));
    assert.equal(result.state, 'FAILED');
    assert.match(result.reason, /缺纸.*已完成1\/2张/);
    assert.equal(result.completedSheets, 1);
    assert.equal(results[0].completedSheets, 1);
    assert.deepEqual(lines(env.directory, 'printed.log'), ['SIZE_6']);
  } finally {
    server.close();
    fs.rmSync(env.directory, { recursive: true, force: true });
  }
});

test('有进度的任务继续打印只打剩余张', async () => {
  const env = setup([
    { printer: 'Normal' },
    { printer: 'Normal', jobs: ['Complete, Retained'] },
    { printer: 'Normal', jobs: ['Complete, Retained'] },
  ]);
  const results = [];
  const { server, origin } = await startServer(async (request, response) => {
    if (request.url.endsWith('/continue')) {
      return json(response, {
        id: '708',
        completedSheets: 1,
        totalSheets: 2,
        items: [SIZE6, ORIGINAL],
      });
    }
    if (request.url.includes('/files/')) {
      response.setHeader('Content-Type', 'image/jpeg');
      return response.end(Buffer.from('img'));
    }
    results.push(await body(request));
    return json(response, { id: '708' });
  });
  try {
    const { continueJob } = require('../src/api');
    const { processClaimedJob } = require('../src/agent');
    const config = makeConfig(origin, env, { printerSettleMs: 1, printerSheetSettleMs: 1, printerPollMs: 1 });
    const job = await continueJob(config, '708');
    const result = await processClaimedJob(config, job);
    assert.equal(result.state, 'PRINTED');
    assert.deepEqual(lines(env.directory, 'printed.log'), ['ORIGINAL']);
    assert.equal(results[0].status, 'PRINTED');
    assert.equal(results[0].completedSheets, 2);
  } finally {
    server.close();
    fs.rmSync(env.directory, { recursive: true, force: true });
  }
});

test('状态读不到→FAILED，不送打', async () => {
  const env = setup([{ printer: 'Normal' }]);
  const results = [];
  const { server, origin } = await photoJobServer('707', [SIZE6], results);
  try {
    const config = makeConfig(origin, env, {
      statusCommand: [process.execPath, '-e', 'process.stderr.write("no printer");process.exit(2)'],
    });
    const result = await runOnce(config);
    assert.equal(result.state, 'FAILED');
    assert.match(result.reason, /无法读取打印机状态（退出码2）：no printer/);
    assert.deepEqual(lines(env.directory, 'printed.log'), []);
  } finally {
    server.close();
    fs.rmSync(env.directory, { recursive: true, force: true });
  }
});

test('领单前打印机缺纸→不 begin，任务保持未打印', async () => {
  const env = setup([{ printer: 'PaperOut' }]);
  let begins = 0;
  const { server, origin } = await startServer(async (request, response) => {
    const url = new URL(request.url, origin);
    if (url.pathname === '/api/operation/print-agents/jobs' && request.method === 'GET') {
      return json(response, { list: [{ id: '801', status: 'QUEUED' }], total: 1, pageNum: 1, pageSize: 20 });
    }
    if (url.pathname.endsWith('/begin')) begins += 1;
    response.statusCode = 500;
    return response.end('{}');
  });
  const scheduler = createScheduler({
    config: makeConfig(origin, env, { listRefreshMs: 600000, autoPrintMs: 600000 }),
    history: createHistory(5),
    autoPrint: false,
    log() {},
  });
  try {
    await scheduler.refreshJobs();
    await assert.rejects(scheduler.printJobIds(['801']), /打印机未就绪：打印机-6寸（缺纸），任务未领取/);
    assert.equal(begins, 0);
    assert.match(scheduler.getState().lastError, /缺纸/);
    assert.deepEqual(lines(env.directory, 'probes.log'), ['打印机-6寸']);
  } finally {
    scheduler.stop();
    server.close();
    fs.rmSync(env.directory, { recursive: true, force: true });
  }
});

test('手动打印仅缺纸→needConfirm；确认 ignorePaperOut 后可领单并送打', async () => {
  const env = setup([
    { printer: 'PaperOut' },
    { printer: 'PaperOut', jobs: ['Printing'] },
    { printer: 'PaperOut', jobs: ['Complete, Retained'] },
    { printer: 'PaperOut', jobs: ['Complete, Retained'] },
  ]);
  let begins = 0;
  const results = [];
  const { server, origin } = await startServer(async (request, response) => {
    const url = new URL(request.url, origin);
    if (url.pathname === '/api/operation/print-agents/jobs' && request.method === 'GET') {
      return json(response, {
        list: [{ id: '802', status: 'QUEUED', completedSheets: 0, totalSheets: 1 }],
        total: 1,
        pageNum: 1,
        pageSize: 20,
      });
    }
    if (url.pathname.endsWith('/begin') && request.method === 'POST') {
      begins += 1;
      return json(response, {
        id: '802',
        target: 'PHOTOS',
        completedSheets: 0,
        items: [{ kind: 'SIZE_6', copies: 1, label: '6寸', fileUrl: '/print-agents/jobs/802/files/PHOTO/1' }],
      });
    }
    if (url.pathname.includes('/files/')) {
      response.setHeader('Content-Type', 'image/jpeg');
      return response.end(Buffer.from('img'));
    }
    if (url.pathname.endsWith('/result') && request.method === 'POST') {
      results.push(await body(request));
      return json(response, { id: '802' });
    }
    response.statusCode = 404;
    return response.end('{}');
  });
  const scheduler = createScheduler({
    config: makeConfig(origin, env, { listRefreshMs: 600000, autoPrintMs: 600000 }),
    history: createHistory(5),
    autoPrint: false,
    log() {},
  });
  try {
    await scheduler.refreshJobs();
    const ask = await scheduler.printJobIds(['802'], { paperOutConfirm: true });
    assert.equal(ask.needConfirm, true);
    assert.equal(ask.reason, '缺纸');
    assert.equal(begins, 0);
    assert.deepEqual(lines(env.directory, 'printed.log'), []);

    const printed = await scheduler.printJobIds(['802'], { ignorePaperOut: true });
    assert.equal(printed[0].state, 'PRINTED');
    assert.equal(begins, 1);
    assert.deepEqual(lines(env.directory, 'printed.log'), ['SIZE_6']);
    assert.equal(results[0].status, 'PRINTED');
  } finally {
    scheduler.stop();
    server.close();
    fs.rmSync(env.directory, { recursive: true, force: true });
  }
});

test('CUPS 送打返回编号后才跟踪并增加进度，缺编号需要核对且不会重送', async (t) => {
  for (const withId of [true, false]) {
    await t.test(withId ? '跟踪新作业' : '缺少编号', async () => {
      const env = setup([]);
      const results = [];
      const { server, origin } = await photoJobServer('cups-701', [SIZE6], results);
      try {
        fs.appendFileSync(env.printScript,
          withId ? `console.log('request id is Photo-6-42 (1 file(s))');` : '');
        fs.writeFileSync(env.statusScript, `const jobId = process.argv[2];
          if (jobId && jobId !== '42') process.exit(1);
          console.log(JSON.stringify({printerStatus:'Idle',jobs:jobId ? [{id:42,status:'Complete'}] : []}));`);
        const config = makeConfig(origin, env, {
          printers: { SIZE_6: 'Photo-6' },
          statusCommand: [process.execPath, env.statusScript, '{jobId}'],
        });
        const result = await runOnce(config);
        assert.equal(result.state, withId ? 'PRINTED' : 'FAILED');
        assert.equal(results[0].completedSheets, withId ? 1 : 0);
        if (!withId) assert.match(result.reason, /未返回可核对的 CUPS 作业编号.*核对实物/);
        assert.deepEqual(lines(env.directory, 'printed.log'), ['SIZE_6']);
      } finally {
        server.close();
        fs.rmSync(env.directory, { recursive: true, force: true });
      }
    });
  }
});

test('Windows 默认启用状态检查，自定义 macOS 命令保留显式配置', () => {
  const base = { base: 'http://127.0.0.1:1/api/operation', token: 't', command: ['x'] };
  const win = normalizeConfig(base, { platform: 'win32' });
  assert.match(win.statusCommand.join(' '), /printer-status\.ps1 -Printer \{printer\}/);
  assert.equal(normalizeConfig(base, { platform: 'darwin' }).statusCommand, null);
  assert.equal(normalizeConfig({ ...base, statusCommand: null }, { platform: 'win32' }).statusCommand, null);
  assert.throws(() => normalizeConfig({ ...base, statusCommand: 'ps' }), /statusCommand必须是/);
});
