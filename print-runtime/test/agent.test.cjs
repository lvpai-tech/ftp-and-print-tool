'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { normalizeConfig } = require('../src/config');
const { processClaimedJob, runOnce } = require('../src/agent');
const { resolvePrinter } = require('../src/print');
const { createPrintRecovery } = require('../src/print-recovery');

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

function makeConfig(origin, directory, script, extra = {}) {
  return normalizeConfig(
    {
      base: `${origin}/api/operation`,
      token: 'isolated-print-desktop-token',
      scenicIds: ['1'],
      resultRetries: 2,
      printer: '照片打印机',
      // 显式关，避免本机 PRINT_DESKTOP_SKIP_PRINT 污染「真走命令」断言
      skipPrint: false,
      command: [process.execPath, script, directory, '{kind}', '{copies}', '{printer}', '{file}'],
      // 默认不读本机打印机状态；缺纸检查由下方专门用例的假状态脚本覆盖
      statusCommand: null,
      ...extra,
    },
    { configPath: path.join(directory, 'config.json'), scriptDir: directory },
  );
}

test('Mac 纸型验证失败直接回写失败，提交异常仍保留待核对记录', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-layout-validation-'));
  const reports = [];
  const { server, origin } = await startServer(async (request, response) => {
    if (request.url.endsWith('/result')) {
      const result = await body(request);
      reports.push(result);
      return json(response, { status: result.status });
    }
    response.setHeader('Content-Type', 'image/jpeg');
    response.end('fixture');
  });
  t.after(() => {
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  });
  const script = path.join(directory, 'print-image-mac.sh');
  function configForExit(code) {
    return makeConfig(origin, directory, script, { command: [process.execPath, '-e',
      `if (process.env.LVPAI_PRINT_NODE !== process.execPath) process.exit(3);
       console.error('无法选择 4×6'); process.exit(${code});`, script] });
  }
  const job = { id: '102', attempt: 1,
    items: [{ kind: 'ORIGINAL', fileUrl: '/print-agents/jobs/102/files/PHOTO/1', copies: 1 }] };
  const preflight = configForExit(2);
  const recovery = createPrintRecovery(preflight);
  const result = await processClaimedJob(preflight, job, { recovery });
  assert.equal(result.state, 'FAILED');
  assert.match(reports[0].reason, /4×6/);
  assert.equal(reports[0].completedSheets, 0);
  assert.equal(recovery.jobs.size, 0);

  await assert.rejects(processClaimedJob(configForExit(1), job, { recovery }), /核对中断工单/);
  assert.equal(recovery.jobs.get('102').sheets[0].state, 'UNCERTAIN');
  assert.equal(reports.length, 1);
});

test('领取→下载→四种照片使用同一台打印机→PRINTED', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-desktop-'));
  const script = path.join(directory, 'fake-print.cjs');
  fs.writeFileSync(
    script,
    `const fs=require('node:fs');const [dir,kind,copies,printer,file]=process.argv.slice(2);
fs.appendFileSync(dir+'/printed.log',[kind,copies,printer,fs.statSync(file).size].join(',')+'\\n');`,
  );
  const results = [];
  const { server, origin } = await startServer(async (request, response) => {
    assert.equal(request.headers['x-print-agent-token'], 'isolated-print-desktop-token');
    if (request.url === '/api/operation/print-agents/jobs/claim') {
      assert.deepEqual(await body(request), { scenicIds: ['1'] });
      return json(response, {
        id: '101',
        items: [
          { kind: 'COVER', copies: 1, label: '开头片', fileUrl: '/print-agents/jobs/101/files/COVER/1' },
          { kind: 'SIZE_6', copies: 2, label: '6寸', fileUrl: '/print-agents/jobs/101/files/PHOTO/1' },
          { kind: 'ORIGINAL', copies: 1, label: '原片', fileUrl: '/print-agents/jobs/101/files/PHOTO/2' },
          { kind: 'CREATIVE', copies: 1, label: '创意', fileUrl: '/print-agents/jobs/101/files/PHOTO/3' },
        ],
      });
    }
    if (request.url.includes('/files/')) {
      response.setHeader('Content-Type', 'image/jpeg');
      return response.end(Buffer.from('fake-jpeg-bytes'));
    }
    const match = request.url.match(/\/jobs\/(\d+)\/result$/);
    results.push({ id: match[1], ...(await body(request)) });
    return json(response, { id: match[1] });
  });
  try {
    const config = makeConfig(origin, directory, script);
    const result = await runOnce(config);
    assert.equal(result.state, 'PRINTED');
    assert.equal(result.jobId, '101');
    assert.equal(result.printer, 'COVER=照片打印机;SIZE_6=照片打印机;ORIGINAL=照片打印机;CREATIVE=照片打印机');
    assert.equal(results.length, 1);
    assert.equal(results[0].status, 'PRINTED');
    assert.equal(
      fs.readFileSync(path.join(directory, 'printed.log'), 'utf8'),
      'COVER,1,照片打印机,15\nSIZE_6,1,照片打印机,15\nSIZE_6,1,照片打印机,15\nORIGINAL,1,照片打印机,15\nCREATIVE,1,照片打印机,15\n',
    );
    assert.equal(results[0].completedSheets, 5);
  } finally {
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('某 kind 命令失败→整单 FAILED', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-desktop-'));
  const script = path.join(directory, 'fail-print.cjs');
  // argv: node script dir kind copies printer file → kind is argv[3]
  fs.writeFileSync(
    script,
    `const kind=process.argv[3];
if (kind === 'SIZE_6') { console.error('缺纸'); process.exit(3); }
process.exit(0);`,
  );
  const results = [];
  const { server, origin } = await startServer(async (request, response) => {
    if (request.url.endsWith('/claim')) {
      return json(response, {
        id: '102',
        items: [
          { kind: 'SIZE_6', copies: 1, label: '6寸', fileUrl: '/print-agents/jobs/102/files/PHOTO/1' },
          { kind: 'ORIGINAL', copies: 1, label: '原片', fileUrl: '/print-agents/jobs/102/files/PHOTO/2' },
        ],
      });
    }
    if (request.url.includes('/files/')) return response.end(Buffer.from('x'));
    results.push(await body(request));
    return json(response, { id: '102' });
  });
  try {
    const failed = await runOnce(makeConfig(origin, directory, script));
    assert.equal(failed.state, 'FAILED');
    assert.match(failed.reason, /退出码3：缺纸/);
    assert.equal(results[0].status, 'FAILED');
    assert.match(results[0].reason, /缺纸/);
  } finally {
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('回写持续失败不自重打（claim 仅 1 次）', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-desktop-'));
  const script = path.join(directory, 'ok.cjs');
  fs.writeFileSync(script, 'process.exit(0);');
  let claims = 0;
  const { server, origin } = await startServer(async (request, response) => {
    if (request.url.endsWith('/claim')) {
      claims += 1;
      return json(response, {
        id: '201',
        items: [
          {
            kind: 'ORIGINAL',
            copies: 1,
            label: '原片',
            fileUrl: '/print-agents/jobs/201/files/PHOTO/1',
          },
        ],
      });
    }
    if (request.url.includes('/files/')) return response.end(Buffer.from('x'));
    response.statusCode = 503;
    return response.end('{}');
  });
  try {
    await assert.rejects(runOnce(makeConfig(origin, directory, script)), /result 失败|失败/);
    assert.equal(claims, 1);
  } finally {
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('无打印机时阻止领单，也拒绝未支持的照片类型', async () => {
  const config = normalizeConfig({ token: 'test', command: [process.execPath], printer: '', skipPrint: false });
  await assert.rejects(runOnce(config), /请先在打印设置/);
  assert.throws(() => resolvePrinter({ ...config, printer: '照片打印机' }, 'RECEIPT'), /不支持的照片类型/);
});

test('双实例并发 claim：服务端只发一单，客户端不本地复制任务', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-desktop-'));
  const script = path.join(directory, 'ok.cjs');
  fs.writeFileSync(script, 'process.exit(0);');
  let claims = 0;
  let issued = false;
  const results = [];
  const { server, origin } = await startServer(async (request, response) => {
    if (request.url.endsWith('/claim')) {
      claims += 1;
      await body(request);
      if (issued) return json(response, null);
      issued = true;
      return json(response, {
        id: '401',
        items: [
          {
            kind: 'SIZE_6',
            copies: 1,
            label: '6寸',
            fileUrl: '/print-agents/jobs/401/files/PHOTO/1',
          },
        ],
      });
    }
    if (request.url.includes('/files/')) return response.end(Buffer.from('img'));
    results.push(await body(request));
    return json(response, { id: '401' });
  });
  try {
    const config = makeConfig(origin, directory, script);
    const [a, b] = await Promise.all([runOnce(config), runOnce(config)]);
    const states = [a.state, b.state].sort();
    assert.deepEqual(states, ['IDLE', 'PRINTED']);
    assert.equal(claims, 2);
    assert.equal(results.length, 1);
    assert.equal(results[0].status, 'PRINTED');
  } finally {
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('非 PHOTOS target → FAILED 且不调用打印命令', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-desktop-'));
  const script = path.join(directory, 'ok.cjs');
  fs.writeFileSync(
    script,
    `require('node:fs').appendFileSync(require('node:path').join(process.argv[2],'printed.log'),'should-not\\n');`,
  );
  const results = [];
  const { server, origin } = await startServer(async (request, response) => {
    if (request.url.endsWith('/claim')) {
      return json(response, {
        id: '501',
        target: 'RECEIPT',
        items: [
          { kind: 'SIZE_6', copies: 1, label: '小票', fileUrl: '/print-agents/jobs/501/files/PHOTO/1' },
        ],
      });
    }
    if (request.url.includes('/files/')) return response.end(Buffer.from('x'));
    results.push(await body(request));
    return json(response, { id: '501' });
  });
  try {
    const failed = await runOnce(makeConfig(origin, directory, script));
    assert.equal(failed.state, 'FAILED');
    assert.match(failed.reason, /拒绝非PHOTOS任务：RECEIPT/);
    assert.equal(results[0].status, 'FAILED');
    assert.equal(fs.existsSync(path.join(directory, 'printed.log')), false);
  } finally {
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('处理后临时目录已删除', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-desktop-'));
  const script = path.join(directory, 'ok.cjs');
  fs.writeFileSync(script, 'process.exit(0);');
  const prefix = `print-job-601-`;
  const before = new Set(
    fs.readdirSync(os.tmpdir()).filter((name) => name.startsWith('print-job-')),
  );
  const { server, origin } = await startServer(async (request, response) => {
    if (request.url.endsWith('/claim')) {
      return json(response, {
        id: '601',
        items: [
          {
            kind: 'SIZE_6',
            copies: 1,
            label: '6寸',
            fileUrl: '/print-agents/jobs/601/files/PHOTO/1',
          },
        ],
      });
    }
    if (request.url.includes('/files/')) return response.end(Buffer.from('img'));
    return json(response, { id: '601' });
  });
  try {
    const result = await runOnce(makeConfig(origin, directory, script));
    assert.equal(result.state, 'PRINTED');
    const leftover = fs
      .readdirSync(os.tmpdir())
      .filter((name) => name.startsWith(prefix) && !before.has(name));
    assert.deepEqual(leftover, []);
  } finally {
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
