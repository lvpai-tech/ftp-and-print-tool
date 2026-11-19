const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const { chromium } = createRequire(path.join(__dirname, '../site/package.json'))('@playwright/test');

test('download page: responsive, valid releases, 404, corrupt manifest and refreshed links', async () => {
  const site = path.resolve(__dirname, '../site');
  let mode = 'published';
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    const match = url.pathname.match(/^\/prd\/(windows-x64|macos-arm64|macos-x64|ios)\/latest.json$/);
    if (match) {
      if (mode === 'missing') { response.writeHead(404); response.end(); return; }
      const platform = match[1];
      const data = { platform, channel: 'prd', versionCode: 3, versionName: '0.3.0',
        installerUrl: `https://cdn.hilvpai.com/ftp-client/prd/${platform}/lvpai-ftp-0.3.0-3-${platform}${platform === 'windows-x64' ? '.zip' : '.dmg'}`,
        sizeBytes: 12, sha256: 'a'.repeat(64), storeUrl: 'https://testflight.apple.com/join/Ab12Cd34' };
      if (mode === 'corrupt') data.versionName = '<img src=x onerror=window.injected=true>';
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify(data)); return;
    }
    const name = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
    if (!['index.html', 'style.css', 'releases.js', 'download.js'].includes(name)) {
      response.writeHead(404); response.end(); return;
    }
    response.writeHead(200, { 'Content-Type': name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html; charset=utf-8' });
    response.end(fs.readFileSync(path.join(site, name)));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('https://cdn.hilvpai.com/**', route => route.abort());
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 960 });
      await page.goto(`http://127.0.0.1:${server.address().port}/`);
      await page.locator('[data-platform="windows-x64"] .release a').waitFor();
      assert.equal(await page.locator('.release a').count(), 4);
      assert.equal(await page.locator('[data-platform="ios"] .release a').getAttribute('href'), 'https://testflight.apple.com/join/Ab12Cd34');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      const evidence = path.resolve(__dirname, '../../.local');
      fs.mkdirSync(evidence, { recursive: true });
      await page.screenshot({ path: path.join(evidence, `ftp-download-${width}.png`), fullPage: true });
    }
    mode = 'missing';
    await page.getByRole('button', { name: '刷新版本' }).click();
    await page.waitForFunction(() => document.querySelectorAll('.unavailable').length === 4);
    assert.equal(await page.locator('.release a').count(), 0);
    mode = 'corrupt';
    await page.getByRole('button', { name: '刷新版本' }).click();
    await page.waitForFunction(() => document.querySelectorAll('.release .error').length === 4);
    assert.equal(await page.locator('.release a').count(), 0);
    assert.equal(await page.evaluate(() => window.injected), undefined);
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
});
