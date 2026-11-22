'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  loadConfig,
  macPackagedSupportDir,
} = require('../src/config');

const root = path.resolve(__dirname, '..');

test('Mac 安装包配置在用户目录，开发态和 Windows 不改位置', () => {
  const home = path.join(os.tmpdir(), 'print-mac-home');
  const packaged = macPackagedSupportDir({
    platform: 'darwin',
    resourcesPath: path.join('/Applications', '旅派打印代理.app', 'Contents', 'Resources'),
    env: { HOME: home },
  });
  assert.equal(
    packaged,
    path.join(home, 'Library', 'Application Support', 'lvpai-print-desktop'),
  );
  assert.equal(macPackagedSupportDir({ platform: 'win32', resourcesPath: 'x', env: {} }), null);
  assert.equal(macPackagedSupportDir({
    platform: 'darwin',
    defaultApp: true,
    resourcesPath: path.join('/tmp', 'Electron.app', 'Contents', 'Resources'),
    env: { HOME: home },
  }), null);
});

test('Mac 安装包首次启动写入示例配置，再次加载不覆盖密钥', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'print-mac-home-'));
  const resources = path.join(home, '旅派打印代理.app', 'Contents', 'Resources');
  fs.mkdirSync(path.join(resources, 'app'), { recursive: true });
  fs.copyFileSync(
    path.join(root, 'config.mac.example.json'),
    path.join(resources, 'app', 'config.example.json'),
  );
  const proc = {
    platform: 'darwin',
    resourcesPath: resources,
    env: { HOME: home },
  };
  const first = loadConfig({ proc, env: {} });
  assert.equal(first.command[0], '/bin/bash');
  assert.match(first.command[1], /print-image-mac\.sh$/);
  assert.equal(first.token, '替换为管理端生成的景区打印密钥');
  assert.equal(
    first.lockDir,
    path.join(home, 'Library', 'Application Support', 'lvpai-print-desktop', '.runtime'),
  );

  const configPath = path.join(home, 'Library', 'Application Support', 'lvpai-print-desktop', 'config.json');
  const saved = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  saved.token = 'kept-token';
  saved.statusCommand = null;
  fs.writeFileSync(configPath, JSON.stringify(saved));
  const second = loadConfig({ proc, env: {} });
  assert.equal(second.token, 'kept-token');
  assert.deepEqual(second.printers, first.printers);
  assert.deepEqual(second.statusCommand, first.statusCommand);
  assert.match(second.statusCommand.join(' '), /mac-printer\.js \{printer\} \{jobId\}/);
});

test('Mac 出纸脚本把受理交给 lp，示例命令不含 Windows 打印', () => {
  const script = fs.readFileSync(path.join(root, 'scripts', 'print-image-mac.sh'), 'utf8');
  assert.match(script, /\/usr\/bin\/lp /);
  assert.match(script, /\/usr\/bin\/lpstat/);
  assert.match(script, /打印机不可用/);
  const example = JSON.parse(fs.readFileSync(path.join(root, 'config.mac.example.json'), 'utf8'));
  assert.equal(example.command.includes('powershell'), false);
  assert.equal(example.command[0], '/bin/bash');
});
