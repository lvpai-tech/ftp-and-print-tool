const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto, createHash } = require('node:crypto');
const releases = require('../site/releases.js');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'frontend/operation-web/live-bridge.js'), 'utf8');

function fixture(platform = 'windows-x64') {
  return { platform, channel: 'prd', versionCode: 3, versionName: '0.3.0', sizeBytes: 12, sha256: 'a'.repeat(64),
    installerUrl: `https://cdn.hilvpai.com/ftp-client/prd/${platform}/lvpai-ftp-0.3.0-3-${platform}${platform === 'windows-x64' ? '.zip' : '.dmg'}` };
}
test('download manifest shares version/platform/hash contract and refuses malicious links', () => {
  for (const platform of releases.platforms.filter(p => p !== 'ios')) assert.equal(releases.validate(fixture(platform), platform, 'prd').versionCode, 3);
  for (const patch of [{ channel: 'test' }, { platform: 'macos-x64' }, { sizeBytes: 0 }, { sha256: '' },
    { versionName: '<script>' }, { installerUrl: 'https://evil.example/update.zip' }, { versionCode: 3.5 }]) {
    assert.throws(() => releases.validate({ ...fixture(), ...patch }, 'windows-x64', 'prd'));
  }
  assert.equal(releases.validStoreUrl('https://testflight.apple.com/join/Ab12Cd34'), true);
  for (const url of ['https://apps.apple.com:443/app/id123', 'https://apps.apple.com/app/id123?',
    'https://apps.apple.com.evil.example/app/id123', 'https://testflight.apple.com/join/Ab12Cd34?next=x']) assert.equal(releases.validStoreUrl(url), false);
});

function bridge(api = {}, confirm = true) {
  const calls = [];
  const client = { getToken: () => 'controlled-test', ...api };
  const window = { crypto: webcrypto, confirm: () => confirm,
    LvpaiLiveCore: { isLiveEnabled: () => true, requireApi: () => client } };
  const context = vm.createContext({ window, document: { addEventListener() {} }, Uint8Array, console,
    setInterval: () => 1, clearInterval() {}, setTimeout() {}, fetch: async (url, options) => {
      calls.push({ url, options }); return { ok: true };
    } });
  vm.runInContext(source, context);
  window.LvpaiLive.ready = true;
  return { live: window.LvpaiLive, calls };
}
function ctx(product, env = 'test') {
  return { state: { clientReleaseProduct: product, clientReleaseEnv: env,
    clientReleaseVersionCode: '3', clientReleaseVersionName: '0.3.0',
    clientReleaseStoreUrl: 'https://apps.apple.com/app/id123' },
  setState(patch) { Object.assign(this.state, patch); } };
}
const file = (name) => ({ name, size: 3, arrayBuffer: async () => Uint8Array.from([1, 2, 3]).buffer });

test('admin controlled transport sends platform and confirms actual SHA after upload', async () => {
  let prepared, confirmed;
  const { live, calls } = bridge({
    opPrepareClientRelease: async body => { prepared = body; return { uploadUrl: 'https://controlled.invalid/put', objectKey: 'key' }; },
    opConfirmClientRelease: async body => { confirmed = body; return { versionCode: 3, versionName: '0.3.0', packageUrl: 'url', manifestKey: 'key' }; },
  });
  const state = ctx('FTP_WINDOWS_X64');
  await live.publishClientRelease(state, file('package.zip'));
  assert.equal(prepared.product, 'FTP_WINDOWS_X64');
  assert.equal(prepared.contentType, 'application/octet-stream');
  assert.equal(calls.length, 1);
  assert.equal(confirmed.sha256, createHash('sha256').update(Buffer.from([1, 2, 3])).digest('hex'));
  assert.equal(state.state.clientReleaseBusy, false);
  assert.match(state.state.toast, /已发布/);
});

test('admin rejects wrong extension and production cancellation before upload', async () => {
  const api = { opPrepareClientRelease: async () => assert.fail('must not upload') };
  const { live } = bridge(api);
  const state = ctx('FTP_MACOS_ARM64');
  await live.publishClientRelease(state, file('wrong.zip'));
  assert.match(state.state.toast, /dmg/);
  const cancelled = bridge(api, false);
  await cancelled.live.publishClientRelease(ctx('FTP_WINDOWS_X64', 'prd'), file('package.zip'));
});

test('iOS publishes official link without uploading IPA; server rejection is visible', async () => {
  let request;
  const { live, calls } = bridge({ opPublishIosReleaseLink: async body => {
    request = body; return { versionCode: 3, versionName: '0.3.0', packageUrl: body.storeUrl, manifestKey: 'ios/latest.json' };
  } });
  await live.publishClientRelease(ctx('FTP_IOS'), null);
  assert.equal(request.storeUrl, 'https://apps.apple.com/app/id123');
  assert.equal(calls.length, 0);
  const failing = bridge({ opPublishIosReleaseLink: async () => { throw Error('拒绝伪造链接'); } });
  const state = ctx('FTP_IOS');
  await failing.live.publishClientRelease(state, null);
  assert.match(state.state.toast, /发布失败.*拒绝/);
  assert.equal(state.state.clientReleaseBusy, false);
});

test('stale current-version responses cannot overwrite switched platform', async () => {
  let finish;
  const { live } = bridge({ opGetClientReleaseCurrent: () => new Promise(resolve => { finish = resolve; }) });
  const state = ctx('FTP_WINDOWS_X64');
  const loading = live.loadClientReleases(state);
  await new Promise(resolve => setImmediate(resolve));
  state.state.clientReleaseProduct = 'FTP_MACOS_ARM64';
  finish({ available: true, versionCode: 3, versionName: '0.3.0' });
  await loading;
  assert.equal(state.state.clientReleaseCurrentText, undefined);
});
