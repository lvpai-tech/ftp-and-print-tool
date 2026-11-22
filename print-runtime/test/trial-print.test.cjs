'use strict';

/**
 * 详情试打印：本机出纸不回写；COVER 复用 SIZE_6 映射。
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { createRuntime } = require('../src/runtime');
const { normalizeConfig, saveConfig } = require('../src/config');
const { resolvePrinter } = require('../src/print');
const { isOnlyPaperOut, filterPrinterFaults } = require('../src/printer-status');

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

test('COVER 未单独映射时 resolvePrinter 复用 SIZE_6', () => {
  const config = normalizeConfig({
    base: 'http://127.0.0.1/api/operation',
    token: 'trial-print-token-xxxxx',
    command: [process.execPath, '-e', 'process.exit(0)'],
    printers: { SIZE_6: '机A', ORIGINAL: '机A', CREATIVE: '机A' },
  }, { scriptDir: os.tmpdir() });
  assert.equal(resolvePrinter(config, 'COVER'), '机A');
});

test('仅缺纸可确认继续；忽略缺纸后仍保留其它故障', () => {
  assert.equal(isOnlyPaperOut(['缺纸']), true);
  assert.equal(isOnlyPaperOut(['缺纸', '离线']), false);
  assert.deepEqual(filterPrinterFaults(['缺纸', '离线'], { ignorePaperOut: true }), ['离线']);
  assert.deepEqual(filterPrinterFaults(['缺纸', '作业缺纸', '卡纸'], { ignorePaperOut: true }), ['卡纸']);
});

test('trialPrintItem：下载 preview-files 并送打，不调用 result', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-trial-'));
  const printedLog = path.join(directory, 'printed.log');
  const script = path.join(directory, 'print.cjs');
  fs.writeFileSync(
    script,
    `const fs=require('fs');fs.appendFileSync(${JSON.stringify(printedLog)}, process.argv.slice(2).join(',')+'\\n');`,
  );
  let resultHits = 0;
  let fileHits = 0;
  const previewHits = [];
  const webp = Buffer.from('UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoCAAIAAUAmJaACdLoB+AADsAD+8ut//NgVzXPv9//S4P0uD9Lg/9KQAAA=', 'base64');
  const { server, origin } = await startServer((request, response) => {
    if (request.url.includes('/preview-thumbnails/PHOTO/')) {
      previewHits.push(request.url);
      response.setHeader('Content-Type', 'image/webp');
      return response.end(request.url.includes('/PHOTO/999') ? Buffer.from('not-a-webp') : webp);
    }
    if (request.method === 'GET' && request.url.includes('/preview-files/COVER/156')) {
      fileHits += 1;
      response.setHeader('Content-Type', 'image/jpeg');
      return response.end(Buffer.from('fake-cover-jpeg'));
    }
    if (request.method === 'POST' && request.url.includes('/result')) {
      resultHits += 1;
      return json(response, { id: '1' });
    }
    if (request.method === 'GET' && request.url.startsWith('/api/operation/print-agents/jobs')) {
      return json(response, { list: [], total: 0, pageNum: 1, pageSize: 20 });
    }
    response.statusCode = 404;
    response.end('no');
  });

  const configPath = path.join(directory, 'config.json');
  const seed = normalizeConfig({
    base: `${origin}/api/operation`,
    token: 'trial-print-token-xxxxx',
    scenicIds: ['1'],
    listRefreshMs: 600000,
    autoPrintMs: 600000,
    statusCommand: null,
    command: [process.execPath, script, '{kind}', '{printer}', '{file}'],
    printers: { SIZE_6: '机试打' },
  }, { configPath, scriptDir: directory });
  saveConfig(seed, configPath);

  const prevConfig = process.env.PRINT_AGENT_CONFIG;
  const prevBase = process.env.PRINT_AGENT_BASE;
  const prevToken = process.env.PRINT_AGENT_TOKEN;
  try {
    process.env.PRINT_AGENT_CONFIG = configPath;
    process.env.PRINT_AGENT_BASE = `${origin}/api/operation`;
    process.env.PRINT_AGENT_TOKEN = 'trial-print-token-xxxxx';
    const bridge = await createRuntime({ configPath, skipLock: true });
    try {
      for (const [flag, width] of [['thumbnail', 160], ['preview', 1200]]) {
        const image = await bridge.previewJobImage(`/print-agents/jobs/99/preview-files/PHOTO/8?${flag}=true`);
        assert.equal(image.contentType, 'image/webp');
        assert.equal(image.dataUrl, `data:image/webp;base64,${webp.toString('base64')}`);
        assert.ok(previewHits.at(-1).endsWith(`/preview-thumbnails/PHOTO/8?width=${width}`));
      }
      await assert.rejects(bridge.previewJobImage('/print-agents/jobs/99/preview-files/PHOTO/999?thumbnail=true'), /有效的JPEG\/PNG\/WebP/);
    } catch (error) {
      await bridge.stop();
      throw error;
    }
    const result = await bridge.trialPrintItem({
      kind: 'COVER',
      label: '开头片',
      copies: 1,
      fileUrl: '/print-agents/jobs/99/preview-files/COVER/156',
    });
    assert.equal(result.printer, '机试打');
    assert.equal(result.kind, 'COVER');
    assert.equal(fileHits, 1);
    assert.equal(resultHits, 0);
    assert.match(fs.readFileSync(printedLog, 'utf8'), /COVER,机试打,/);
    await bridge.stop();
  } finally {
    if (prevConfig == null) delete process.env.PRINT_AGENT_CONFIG;
    else process.env.PRINT_AGENT_CONFIG = prevConfig;
    if (prevBase == null) delete process.env.PRINT_AGENT_BASE;
    else process.env.PRINT_AGENT_BASE = prevBase;
    if (prevToken == null) delete process.env.PRINT_AGENT_TOKEN;
    else process.env.PRINT_AGENT_TOKEN = prevToken;
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('trialPrintItem：仅缺纸时返回 needConfirm；确认后可送打', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-trial-paper-'));
  const printedLog = path.join(directory, 'printed.log');
  const printScript = path.join(directory, 'print.cjs');
  const statusScript = path.join(directory, 'status.cjs');
  fs.writeFileSync(
    printScript,
    `const fs=require('fs');fs.appendFileSync(${JSON.stringify(printedLog)}, 'ok\\n');`,
  );
  fs.writeFileSync(
    statusScript,
    `process.stdout.write(JSON.stringify({printer:'机试打',printerStatus:'PaperOut',jobs:[]}));`,
  );
  const { server, origin } = await startServer((request, response) => {
    if (request.method === 'GET' && request.url.includes('/preview-files/COVER/166')) {
      response.setHeader('Content-Type', 'image/jpeg');
      return response.end(Buffer.from('cover'));
    }
    if (request.method === 'GET' && request.url.startsWith('/api/operation/print-agents/jobs')) {
      return json(response, { list: [], total: 0, pageNum: 1, pageSize: 20 });
    }
    response.statusCode = 404;
    response.end('no');
  });
  const configPath = path.join(directory, 'config.json');
  const seed = normalizeConfig({
    base: `${origin}/api/operation`,
    token: 'trial-print-token-xxxxx',
    scenicIds: ['1'],
    listRefreshMs: 600000,
    autoPrintMs: 600000,
    statusCommand: [process.execPath, statusScript],
    command: [process.execPath, printScript],
    printers: { SIZE_6: '机试打' },
  }, { configPath, scriptDir: directory });
  saveConfig(seed, configPath);

  const prevConfig = process.env.PRINT_AGENT_CONFIG;
  const prevBase = process.env.PRINT_AGENT_BASE;
  const prevToken = process.env.PRINT_AGENT_TOKEN;
  try {
    process.env.PRINT_AGENT_CONFIG = configPath;
    process.env.PRINT_AGENT_BASE = `${origin}/api/operation`;
    process.env.PRINT_AGENT_TOKEN = 'trial-print-token-xxxxx';
    const bridge = await createRuntime({ configPath, skipLock: true });
    const item = {
      kind: 'COVER',
      label: '开头片',
      fileUrl: '/print-agents/jobs/99/preview-files/COVER/166',
    };
    const ask = await bridge.trialPrintItem(item);
    assert.equal(ask.needConfirm, true);
    assert.equal(ask.reason, '缺纸');
    assert.equal(fs.existsSync(printedLog), false);
    const done = await bridge.trialPrintItem(item, { ignorePaperOut: true });
    assert.equal(done.needConfirm, undefined);
    assert.equal(done.ignoredPaperOut, true);
    assert.match(fs.readFileSync(printedLog, 'utf8'), /ok/);
    await bridge.stop();
  } finally {
    if (prevConfig == null) delete process.env.PRINT_AGENT_CONFIG;
    else process.env.PRINT_AGENT_CONFIG = prevConfig;
    if (prevBase == null) delete process.env.PRINT_AGENT_BASE;
    else process.env.PRINT_AGENT_BASE = prevBase;
    if (prevToken == null) delete process.env.PRINT_AGENT_TOKEN;
    else process.env.PRINT_AGENT_TOKEN = prevToken;
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
