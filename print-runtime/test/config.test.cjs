'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  normalizeConfig,
  loadConfig,
  applyEnvOverrides,
  EXAMPLE_CONFIG_PATH,
} = require('../src/config');

const validCommand = ['powershell', '-File', '{scriptDir}/print-image.ps1', '-File', '{file}'];

test('配置校验：缺少 token/command 时拒绝；base 可缺省为正式根', () => {
  assert.throws(() => normalizeConfig({}), /缺少 token/);
  assert.throws(
    () => normalizeConfig({ base: 'http://x', token: '' }),
    /缺少 token/,
  );
  assert.throws(
    () => normalizeConfig({ base: 'http://x', token: 't', command: 'cmd' }),
    /非空字符串数组/,
  );
  assert.throws(
    () =>
      normalizeConfig({
        base: 'http://x',
        token: 't',
        command: validCommand,
        allowDefaultPrinter: true,
        defaultPrinter: '',
      }),
    /开启 allowDefaultPrinter/,
  );
  assert.throws(
    () =>
      normalizeConfig({
        base: 'http://x',
        token: 't',
        command: validCommand,
        statusHost: '0.0.0.0',
      }),
    /状态页仅允许绑定 127\.0\.0\.1/,
  );
});

test('配置校验：合法示例可规范化，环境变量可覆盖', () => {
  const example = JSON.parse(fs.readFileSync(EXAMPLE_CONFIG_PATH, 'utf8'));
  example.token = 'test-token';
  example.printers = {
    SIZE_6: 'A',
    ORIGINAL: 'B',
    CREATIVE: 'B',
  };
  const cfg = normalizeConfig(example);
  assert.equal(cfg.base.endsWith('/'), false);
  assert.equal(cfg.pollMs, 3000);
  assert.equal(cfg.allowDefaultPrinter, false);

  const overridden = normalizeConfig(
    applyEnvOverrides(example, {
      PRINT_AGENT_BASE: 'http://127.0.0.1:9/api/operation/',
      PRINT_AGENT_TOKEN: 'from-env',
      PRINT_AGENT_POLL_MS: '5000',
      PRINT_AGENT_SCENIC_IDS: '2,3',
    }),
  );
  assert.equal(overridden.base, 'http://127.0.0.1:9/api/operation');
  assert.equal(overridden.token, 'from-env');
  assert.equal(overridden.pollMs, 5000);
  assert.deepEqual(overridden.scenicIds, ['2', '3']);
});

test('多景区档案：旧配置自动迁成一条并激活；redact 遮盖密钥', () => {
  const { redactConfig } = require('../src/config');
  const cfg = normalizeConfig({
    base: 'http://127.0.0.1:1/api/operation',
    token: 'legacy-token',
    scenicIds: ['7'],
    scenicName: '旧景区',
    scenicCode: 'OLD',
    printers: { SIZE_6: 'P' },
    command: validCommand,
  });
  assert.equal(cfg.activeScenicProfileId, 'default');
  assert.equal(cfg.scenicProfiles.length, 1);
  assert.equal(cfg.scenicProfiles[0].token, 'legacy-token');
  assert.deepEqual(cfg.scenicProfiles[0].scenicIds, ['7']);
  const publicCfg = redactConfig(cfg);
  assert.equal(publicCfg.token, '[已配置]');
  assert.equal(publicCfg.scenicProfiles[0].token, '[已配置]');
});

test('loadConfig：从文件加载；缺失文件报错', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'print-cfg-'));
  const file = path.join(dir, 'config.json');
  try {
    assert.throws(() => loadConfig({ configPath: file, env: {} }), /找不到配置文件/);
    fs.writeFileSync(
      file,
      JSON.stringify({
        base: 'http://127.0.0.1:1/api/operation',
        token: 'file-token',
        scenicIds: ['9'],
        printers: { SIZE_6: 'P2' },
        command: validCommand,
      }),
    );
    const cfg = loadConfig({ configPath: file, env: {} });
    assert.equal(cfg.token, 'file-token');
    assert.deepEqual(cfg.scenicIds, ['9']);
    assert.equal(cfg.configPath, file);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
