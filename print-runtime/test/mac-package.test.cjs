'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
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

const bash = process.env.LVPAI_TEST_BASH || (process.platform === 'darwin' ? '/bin/bash' : null);

test('Mac 送打按队列纸型和图片方向请求完整的 6 寸图', { skip: !bash }, (t) => {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'print-mac-layout-'));
  t.after(() => fs.rmSync(fixture, { recursive: true, force: true }));
  fs.writeFileSync(path.join(fixture, 'photo.png'), 'fixture');
  const script = fs.readFileSync(path.join(root, 'scripts', 'print-image-mac.sh'), 'utf8')
    .replaceAll('/usr/bin/', 'stub_');
  fs.writeFileSync(path.join(fixture, 'print.sh'), `
stub_lpstat() { [[ "$1" = -p && "$2" = Photo ]]; }
stub_lpoptions() { printf '%s\\n' "$TEST_PAGE_SIZES"; }
stub_sips() { printf '%s\\n' 'photo.png' "  pixelWidth: $TEST_WIDTH" "  pixelHeight: $TEST_HEIGHT" "  orientation: $TEST_ORIENTATION"; }
stub_lp() { printf '%s\\n' 'request id is Photo-42 (1 file(s))' "$@"; }
stub_node() { [[ -n "$TEST_IPP_MEDIA" ]] && printf '%s\\n' "$TEST_IPP_MEDIA"; }
${script}`);

  function print(pageSizes, width, height, orientation = 1, ippMedia = '') {
    return spawnSync(bash, ['print.sh', '-File', 'photo.png', '-Printer', 'Photo', '-Copies', '2', '-Kind', 'CREATIVE'], {
      cwd: fixture, encoding: 'utf8', env: { ...process.env,
        LVPAI_PRINT_DPI: '360', LVPAI_PRINT_DOCUMENT_NAME: 'lvpai-test-job', LVPAI_PRINT_NODE: 'stub_node',
        TEST_PAGE_SIZES: pageSizes, TEST_WIDTH: String(width), TEST_HEIGHT: String(height),
        TEST_ORIENTATION: String(orientation), TEST_IPP_MEDIA: ippMedia },
    });
  }

  const choices = 'PageSize/Media Size: *A4 4x6.Borderless 4x6 Letter';
  const portrait = print(choices, 1440, 2160);
  assert.equal(portrait.status, 0, portrait.stderr);
  assert.deepEqual(portrait.stdout.trim().split(/\r?\n/), [
    'request id is Photo-42 (1 file(s))',
    '-d', 'Photo', '-n', '2', '-t', 'lvpai-test-job',
    '-o', 'PageSize=4x6', '-o', 'media=4x6', '-o', 'orientation-requested=3',
    '-o', 'print-scaling=fit', '-o', 'fit-to-page', '-o', 'scaling=100', '-o', 'position=center',
    '-o', 'printer-resolution=360dpi', 'photo.png',
  ]);

  const landscape = print('PageSize/Media Size: *A4 w288h432', 2160, 1440);
  assert.equal(landscape.status, 0, landscape.stderr);
  assert.match(landscape.stdout, /PageSize=w288h432/);
  assert.match(landscape.stdout, /orientation-requested=4/);
  const rotatedPortrait = print(choices, 2160, 1440, 6);
  assert.equal(rotatedPortrait.status, 0, rotatedPortrait.stderr);
  assert.match(rotatedPortrait.stdout, /orientation-requested=3/);

  const borderless = print('PageSize/Media Size: *A4 4x6.Borderless', 900, 1800, '(null)');
  assert.equal(borderless.status, 0, borderless.stderr);
  assert.match(borderless.stdout, /PageSize=4x6\.Borderless/);

  const driverless = print('', 1200, 1200, 1, 'na_index-4x6_4x6in');
  assert.equal(driverless.status, 0, driverless.stderr);
  assert.match(driverless.stdout, /media=na_index-4x6_4x6in/);
  assert.doesNotMatch(driverless.stdout, /PageSize=/);

  const unsupported = print('PageSize/Media Size: *A4 Letter', 1440, 2160);
  assert.equal(unsupported.status, 2, unsupported.stderr);
  assert.match(unsupported.stderr, /4×6/);
  assert.equal(unsupported.stdout, '');
  const unreadable = print(choices, '', '');
  assert.equal(unreadable.status, 2, unreadable.stderr);
  assert.equal(unreadable.stdout, '');
});
