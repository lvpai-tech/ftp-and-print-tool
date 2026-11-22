'use strict';

/**
 * 景区密钥绑定：保存 token 时调用 /me，写入景区名；不调用打印机。
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { createRuntime } = require('../src/runtime');
const { fetchMe, claimJob } = require('../src/api');
const { normalizeConfig, saveConfig } = require('../src/config');

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

function fail(response, code, message) {
  response.setHeader('Content-Type', 'application/json');
  response.end(JSON.stringify({ code, message, data: null }));
}

test('保存新密钥：校验 /me 后写入 scenicName/scenicIds，不出纸', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-scenic-key-'));
  const configPath = path.join(directory, 'config.json');
  let meHits = 0;
  let claimHits = 0;
  const { server, origin } = await startServer(async (request, response) => {
    const token = request.headers['x-print-agent-token'];
    if (request.method === 'GET' && request.url === '/api/operation/print-agents/me') {
      if (token !== 'scenic-plain-token-for-unit-test') return fail(response, 40101, '提交了错误的密钥');
      meHits += 1;
      return json(response, {
        agentId: 'scenic-42',
        scenicId: '42',
        scenicName: '单元验景区',
        scenicCode: 'unit-psk',
        scenicIds: ['42'],
      });
    }
    if (request.method === 'GET' && request.url.startsWith('/api/operation/print-agents/jobs')) {
      return json(response, { list: [], total: 0, pageNum: 1, pageSize: 20 });
    }
    if (request.method === 'POST' && request.url === '/api/operation/print-agents/jobs/claim') {
      assert.equal(token, 'scenic-plain-token-for-unit-test');
      claimHits += 1;
      return json(response, null);
    }
    fail(response, 40401, `unexpected ${request.method} ${request.url}`);
  });

  const seed = normalizeConfig({
    base: `${origin}/api/operation`,
    token: 'old-token-placeholder-xxxx',
    scenicIds: [],
    listRefreshMs: 600000,
    autoPrintMs: 600000,
    command: [process.execPath, '-e', 'process.exit(0)'],
    printers: {},
  }, { configPath, scriptDir: directory });
  saveConfig(seed, configPath);

  try {
    process.env.PRINT_AGENT_CONFIG = configPath;
    process.env.PRINT_AGENT_BASE = `${origin}/api/operation`;
    const bridge = await createRuntime({
      configPath,
      skipLock: true,
      onLog() {},
      onStateChange() {},
    });
    try {
      await bridge.applyConfigPatch({ token: 'scenic-plain-token-for-unit-test' });
      assert.equal(meHits, 1);
      const snap = bridge.snapshot();
      assert.equal(snap.config.token, '[已配置]');
      assert.equal(snap.config.scenicName, '单元验景区');
      assert.deepEqual(snap.config.scenicIds, ['42']);

      const cfg = require('../src/config').loadConfig({ configPath });
      const me = await fetchMe(cfg);
      assert.equal(me.scenicName, '单元验景区');
      const job = await claimJob(cfg);
      assert.equal(job, null);
      assert.equal(claimHits, 1);
      bridge.start();
      await bridge.refreshJobs();
    } finally {
      bridge.stop();
    }
  } finally {
    delete process.env.PRINT_AGENT_CONFIG;
    delete process.env.PRINT_AGENT_BASE;
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('新增或激活档案时，用该档案的密钥校验景区', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-scenic-profiles-'));
  const configPath = path.join(directory, 'config.json');
  const oldToken = 'unit-token-for-blue-moon';
  const newToken = 'unit-token-for-hanjing';
  const probes = [];
  const { server, origin } = await startServer((request, response) => {
    if (request.url.endsWith('/me')) {
      const token = request.headers['x-print-agent-token'];
      probes.push(token);
      const scenicId = token === newToken ? '5' : '1';
      return json(response, { scenicId, scenicName: scenicId === '5' ? '汉京中心' : '蓝月谷' });
    }
    return json(response, { list: [], total: 0 });
  });
  t.after(() => {
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  });
  const base = `${origin}/api/operation`;
  const previousBase = process.env.PRINT_AGENT_BASE;
  process.env.PRINT_AGENT_BASE = base;
  t.after(() => {
    if (previousBase === undefined) delete process.env.PRINT_AGENT_BASE;
    else process.env.PRINT_AGENT_BASE = previousBase;
  });
  const oldProfile = { id: 'default', token: oldToken, scenicIds: ['1'], scenicName: '蓝月谷' };
  saveConfig(normalizeConfig({
    base, token: oldToken, command: [process.execPath], printers: {},
    scenicProfiles: [oldProfile, { ...oldProfile, id: 'saved', token: newToken }],
  }, { configPath, scriptDir: directory }));
  const bridge = await createRuntime({ configPath, skipLock: true });
  try {
    await bridge.activateScenicProfile({ id: 'saved' });
    assert.equal(bridge.snapshot().config.scenicName, '汉京中心');
    assert.deepEqual(bridge.snapshot().config.scenicIds, ['5']);
    await bridge.deleteScenicProfile({ id: 'default' });
    await bridge.addScenicProfile({ token: oldToken });
    const added = bridge.snapshot().config.scenicProfiles.find((profile) => profile.id !== 'saved');
    assert.equal(added.scenicName, '蓝月谷');
    assert.deepEqual(added.scenicIds, ['1']);
    assert.deepEqual(probes, [newToken, oldToken]);
  } finally {
    bridge.stop();
  }
});

test('错误密钥：/me 失败时不落盘新密钥', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-scenic-key-bad-'));
  const configPath = path.join(directory, 'config.json');
  const { server, origin } = await startServer(async (request, response) => {
    if (request.url === '/api/operation/print-agents/me') {
      return fail(response, 40101, '打印代理令牌无效');
    }
    if (request.url && request.url.startsWith('/api/operation/print-agents/jobs')) {
      return json(response, { list: [], total: 0, pageNum: 1, pageSize: 20 });
    }
    fail(response, 40401, 'unexpected');
  });
  const seed = normalizeConfig({
    base: `${origin}/api/operation`,
    token: 'keep-old-token-value-xx',
    scenicIds: ['9'],
    scenicName: '旧景区',
    listRefreshMs: 600000,
    autoPrintMs: 600000,
    command: [process.execPath, '-e', 'process.exit(0)'],
    printers: {},
  }, { configPath, scriptDir: directory });
  saveConfig(seed, configPath);

  try {
    process.env.PRINT_AGENT_CONFIG = configPath;
    process.env.PRINT_AGENT_BASE = `${origin}/api/operation`;
    const bridge = await createRuntime({
      configPath,
      skipLock: true,
      onLog() {},
      onStateChange() {},
    });
    try {
      await assert.rejects(
        () => bridge.applyConfigPatch({ token: 'bad-new-token-xxxxxx' }),
        /失败|无效|密钥/,
      );
      const onDisk = JSON.parse(fs.readFileSync(configPath, 'utf8'));
      assert.equal(onDisk.token, 'keep-old-token-value-xx');
      assert.equal(onDisk.scenicName, '旧景区');
    } finally {
      bridge.stop();
    }
  } finally {
    delete process.env.PRINT_AGENT_CONFIG;
    delete process.env.PRINT_AGENT_BASE;
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
