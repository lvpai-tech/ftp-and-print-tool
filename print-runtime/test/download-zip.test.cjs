'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { createRuntime } = require('../src/runtime');
const { buildStoreZip } = require('../src/zip-store.cjs');

async function zipFixture(t, handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => {
    server.close(resolve);
    server.closeAllConnections();
  }));

  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-zip-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const configPath = path.join(directory, 'config.json');
  fs.writeFileSync(configPath, JSON.stringify({
    token: 'test-print-token',
    command: [process.execPath, '-e', 'process.exit(0)'],
  }));
  const runtime = await createRuntime({
    configPath, skipLock: true, forceManualStart: true,
  });
  t.after(() => runtime.stop());
  runtime.runtime.getConfig().base = `http://127.0.0.1:${server.address().port}`;
  return { runtime, targetPath: path.join(directory, 'print-599.zip') };
}

test('ZIP 图片响应中途停住时超时报错，保留目标文件并可重试', async (t) => {
  const cover = Buffer.from('ffd8ffe10000ffd9', 'hex');
  const photo = Buffer.from('ffd8ffe20000ffd9', 'hex');
  const previewRoute = '/print-agents/jobs/599/preview';
  const coverRoute = '/print-agents/jobs/599/preview-files/COVER/1';
  const photoRoute = '/print-agents/jobs/599/preview-files/PHOTO/2';
  const stalledResponse = new AbortController();
  let stall = true;
  const routes = [];
  const { runtime, targetPath } = await zipFixture(t, (request, response) => {
    routes.push(request.url);
    if (request.url === previewRoute) {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify({ code: 200, data: { id: '599', items: [
        { kind: 'COVER', fileUrl: coverRoute },
        { kind: 'ORIGINAL', fileUrl: photoRoute },
      ] } }));
    } else if (request.url === coverRoute || request.url === photoRoute) {
      response.writeHead(200, { 'Content-Type': 'image/jpeg' });
      if (request.url === photoRoute && stall) {
        response.write(photo.subarray(0, 4));
        const abort = setTimeout(() => stalledResponse.abort(), 30);
        const release = setTimeout(() => response.end(photo.subarray(4)), 500);
        response.once('close', () => {
          clearTimeout(abort);
          clearTimeout(release);
        });
      } else {
        response.end(request.url === coverRoute ? cover : photo);
      }
    } else {
      response.writeHead(404).end();
    }
  });
  fs.writeFileSync(targetPath, 'existing file');
  const deadline = t.mock.method(AbortSignal, 'timeout', () => stalledResponse.signal);
  await assert.rejects(runtime.downloadJobZip('599', targetPath), /下载 ZIP 超时/);
  assert.equal(routes.length, 3);
  assert.equal(routes[0], previewRoute);
  assert.deepEqual(new Set(routes.slice(1)), new Set([coverRoute, photoRoute]));
  assert.equal(fs.readFileSync(targetPath, 'utf8'), 'existing file');
  deadline.mock.restore();

  stall = false;
  assert.deepEqual(await runtime.downloadJobZip('599', targetPath),
    { jobId: '599', count: 2, path: targetPath });
  assert.deepEqual(fs.readFileSync(targetPath), buildStoreZip([
    { name: '01-COVER.jpg', data: cover },
    { name: '02-ORIGINAL.jpg', data: photo },
  ]));
});

test('ZIP 最多并发三张、仅重试临时失败的图片，并按工单顺序打包', { timeout: 5000 }, async (t) => {
  const previewRoute = '/print-agents/jobs/599/preview';
  const imagePaths = [1, 2, 3, 4].map(id => `/print-agents/jobs/599/preview-files/PHOTO/${id}`);
  const images = [1, 2, 3, 4].map(id => Buffer.from([0xff, 0xd8, 0xff, id, 0xff, 0xd9]));
  const firstRequests = new Map();
  const hits = [0, 0, 0, 0];
  const progress = [];
  let active = 0;
  let peak = 0;
  const { runtime, targetPath } = await zipFixture(t, (request, response) => {
    if (request.url === previewRoute) {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify({ code: 200, data: { id: '599',
        items: imagePaths.map(fileUrl => ({ kind: 'ORIGINAL', fileUrl })),
      } }));
      return;
    }
    const index = imagePaths.indexOf(request.url);
    if (index < 0) {
      response.writeHead(404).end();
      return;
    }
    hits[index] += 1;
    active += 1;
    peak = Math.max(peak, active);
    response.once('close', () => { active -= 1; });
    const sendImage = () => response.writeHead(200, { 'Content-Type': 'image/jpeg' }).end(images[index]);

    if (index < 3 && hits[index] === 1) {
      firstRequests.set(index, index === 1 ? () => response.writeHead(503).end() : sendImage);
      if (firstRequests.size === 3) firstRequests.get(1)();
      return;
    }
    sendImage();
    if (index === 3) {
      firstRequests.get(2)?.();
      firstRequests.get(0)?.();
    }
  });

  const result = await runtime.downloadJobZip('599', targetPath, entry => progress.push(entry));
  assert.deepEqual(result, { jobId: '599', count: 4, path: targetPath });
  assert.equal(peak, 3);
  assert.deepEqual(hits, [1, 2, 1, 1]);
  assert.deepEqual(progress, [
    ...[0, 1, 2, 3, 4].map(completed => ({ completed, total: 4, saving: false })),
    { completed: 4, total: 4, saving: true },
  ]);
  assert.deepEqual(fs.readFileSync(targetPath), buildStoreZip(
    images.map((data, index) => ({ name: `0${index + 1}-ORIGINAL.jpg`, data })),
  ));
});
