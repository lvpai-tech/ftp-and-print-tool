'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn, spawnSync } = require('node:child_process');
const readline = require('node:readline');

test('Flutter桥：打印服务已占用时报告占用，保留原锁且不显示锁路径', (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'flutter-print-lock-'));
  const lock = require('../src/single-instance').acquireLock(path.join(temp, '.runtime'));
  t.after(() => { lock.release(); fs.rmSync(temp, { recursive: true, force: true }); });
  const child = spawnSync(process.execPath, [path.resolve(__dirname, '../src/flutter-bridge.cjs')], {
    env: { ...process.env, PRINT_AGENT_CONFIG: path.join(temp, 'config.json') },
    encoding: 'utf8', timeout: 5000, windowsHide: true,
  });
  assert.equal(child.status, 1);
  assert.equal(child.stderr, '');
  assert.deepEqual(JSON.parse(child.stdout), { event: 'startupError', code: 'ELOCKED' });
  assert.equal(Number(fs.readFileSync(lock.lockPath, 'utf8').split('\n')[0]), process.pid);
});

/** 使用真实子进程与本机受控协议服务验证桥接，不连接生产或打印机。 */
test('Flutter桥：设备授权校验、凭据不落配置、互斥与回写失败不重打', async (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'flutter-print-test-'));
  const secret = 'ab'.repeat(32);
  const other = 'cd'.repeat(32);
  const firstId = '11111111-1111-4111-8111-111111111111';
  const secondId = '22222222-2222-4222-8222-222222222222';
  let beginCount = 0;
  let resultCount = 0;
  let failResult = true;
  const scopedRemovals = [];
  const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json');
    const token = req.headers['x-print-agent-token'];
    if (token === other) {
      let data;
      if (req.url === '/print-agents/me') data = { scenicId: '2', scenicName: '第二景区' };
      else if (req.url === '/print-agents/photo-batches/stations') data = [{ id: '27' }];
      else if (req.url.startsWith('/print-agents/photo-batches/stations/27/split-preview?')) {
        const params = new URL(req.url, 'http://localhost').searchParams;
        assert.equal(req.method, 'GET');
        assert.equal(params.get('beforePhotoId'), '31');
        assert.equal(params.get('afterPhotoId'), '32');
        data = { managementOnly: true };
      }
      else if (req.url.startsWith('/print-agents/photo-batches/stations/27/moves?')) {
        assert.equal(req.method, 'POST');
        const params = new URL(req.url, 'http://localhost').searchParams;
        assert.equal(params.get('from'), '2026-11-23T16:00:00Z');
        let body = '';
        req.setEncoding('utf8');
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
          const { photoId, targetPhotoId } = JSON.parse(body);
          res.end(JSON.stringify({ code: 200, data: { photoId, targetPhotoId } }));
        });
        return;
      }
      else if (req.url.startsWith('/print-agents/photo-batches/stations/27/removals?')) {
        assert.equal(req.method, 'POST');
        assert.equal(new URL(req.url, 'http://localhost').searchParams.get('to'), '2026-11-24T16:00:00Z');
        let body = '';
        req.setEncoding('utf8');
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
          const { requestId, photos } = JSON.parse(body);
          assert.deepEqual(photos.map(photo => photo.photoId), ['31', '32']);
          res.end(JSON.stringify({ code: 200, data: { requestId, removedCount: photos.length } }));
        });
        return;
      }
      else if (req.url === '/print-agents/photo-batches/stations/27/photos/31/capture') {
        assert.equal(req.method, 'GET');
        data = { collected: true, cameraMake: 'Canon' };
      }
      else if (req.url === '/print-agents/photo-batches/stations/27/photos/31/removals') {
        let body = '';
        req.setEncoding('utf8');
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
          const request = JSON.parse(body);
          scopedRemovals.push(request);
          res.end(JSON.stringify({ code: 200, data: { requestId: request.requestId, photoId: '31' } }));
        });
        return;
      } else { res.statusCode = 404; res.end('{}'); return; }
      res.end(JSON.stringify({ code: 200, data }));
      return;
    }
    if (token !== secret) {
      res.end(JSON.stringify({ code: 401, message: '密钥无效' })); return;
    }
    let data;
    if (req.url === '/print-agents/me') data = { scenicId: '1', scenicName: '隔离测试景区' };
    else if (req.url.startsWith('/print-agents/jobs?')) data = { list: [], total: 0 };
    else if (['/print-agents/jobs/9/begin', '/print-agents/jobs/10/begin'].includes(req.url)) {
      beginCount++;
      data = { id: req.url.split('/')[3], attempt: beginCount, target: 'PHOTOS',
        items: [{ kind: 'ORIGINAL', copies: 1, fileUrl: '/image' }] };
    } else if (req.url === '/print-agents/jobs/9/preview') {
      data = { id: '9', attempt: 1, status: 'CLAIMED', items: [{ kind: 'ORIGINAL', copies: 1, fileUrl: '/image' }] };
    } else if (req.url === '/print-agents/jobs/11/preview') {
      data = { id: '11', items: [{ kind: 'ORIGINAL', fileUrl: '/print-agents/jobs/11/preview-files/PHOTO/3' }] };
    } else if (req.url === '/image' || req.url === '/print-agents/jobs/11/preview-files/PHOTO/3') {
      res.setHeader('Content-Type', 'image/jpeg'); res.end(Buffer.from([255, 216, 255, 217])); return;
    } else if (['/print-agents/jobs/9/result', '/print-agents/jobs/10/result'].includes(req.url)) {
      resultCount++;
      res.end(JSON.stringify(failResult ? { code: 503, message: '受控回写失败' }
        : { code: 200, data: { status: 'PRINTED' } })); return;
    } else { res.statusCode = 404; res.end('{}'); return; }
    res.end(JSON.stringify({ code: 200, data }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const configPath = path.join(temp, 'config.json');
  const child = spawn(process.execPath, [path.resolve(__dirname, '../src/flutter-bridge.cjs')], {
    env: { ...process.env, PRINT_AGENT_CONFIG: configPath,
      PRINT_AGENT_BASE: `http://127.0.0.1:${server.address().port}` },
    stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
  });
  t.after(() => { child.kill(); server.close(); fs.rmSync(temp, { recursive: true, force: true }); });
  const pending = new Map(); let sequence = 0; let wire = '';
  const zipEvents = [];
  readline.createInterface({ input: child.stdout }).on('line', (line) => {
    wire += line;
    const response = JSON.parse(line);
    if (response.event === 'zipProgress') {
      zipEvents.push(response);
      return;
    }
    if (response.id != null) { pending.get(response.id)?.(response); pending.delete(response.id); }
  });
  const call = (method, ...args) => new Promise((resolve) => {
    const id = ++sequence; pending.set(id, resolve);
    child.stdin.write(`${JSON.stringify({ id, method, args })}\n`);
  });
  assert.equal((await call('snapshot')).data.configured, false);
  await call('initialize', {});
  assert.match((await call('installPrintAuthorization', { id: firstId, token: 'bad' })).error, /凭据无效/);
  assert.match((await call('installPrintAuthorization', { id: firstId, token: secret, scenicId: '2' })).error, /不一致/);
  assert.equal(fs.existsSync(configPath), false);
  const marker = path.join(temp, 'submitted');
  fs.writeFileSync(configPath, JSON.stringify({
    statusCommand: null, resultRetries: 1, command: [process.execPath, '-e',
      'require("node:fs").appendFileSync(process.argv[1], process.env.LVPAI_PRINT_DPI + "\\n");setTimeout(()=>{},200)', marker],
    token: 'retired-shared-token',
  }));
  const configured = await call('installPrintAuthorization', { id: firstId, token: secret, scenicId: '1' });
  assert.equal(configured.data.configured, true);
  assert.equal(configured.data.config.token, '[已配置]');
  assert.equal(configured.data.config.printDpi, 300);
  assert.equal(configured.data.state.autoPrint, false);
  assert.match((await call('autoPrint', true)).error, /请先在打印设置/);
  assert.match((await call('installPrintAuthorization', { id: secondId, token: other, scenicId: '1' })).error, /不属于/);
  const added = await call('installPrintAuthorization', { id: secondId, token: other, scenicId: '2' });
  const second = added.data.config.scenicProfiles.find(profile => profile.scenicIds.includes('2'));
  const scope = { profileId: second.id, scenicId: '2' };
  assert.match((await call('listBatchStations', { ...scope, scenicId: '1' })).error, /档案已变更/);
  assert.deepEqual((await call('listBatchStations', scope)).data, [{ id: '27' }]);
  const range = { stationId: '27', from: '2026-11-23T16:00:00Z', to: '2026-11-24T16:00:00Z' };
  assert.deepEqual((await call('previewPhotoBatchSplit', { ...range, beforePhotoId: '31', afterPhotoId: '32' }, scope)).data,
    { managementOnly: true });
  const move = { photoId: '31', targetPhotoId: '32', revision: 0, targetRevision: 0 };
  assert.match((await call('movePhotoBatchPhoto', range, move, { ...scope, scenicId: '1' })).error, /档案已变更/);
  assert.deepEqual((await call('movePhotoBatchPhoto', range, move, scope)).data, { photoId: '31', targetPhotoId: '32' });
  assert.deepEqual((await call('getBatchPhotoCapture', '27', '31', scope)).data,
    { collected: true, cameraMake: 'Canon' });
  assert.match((await call('getBatchPhotoCapture', '27', '31', { ...scope, scenicId: '1' })).error, /档案已变更/);
  const removal = { requestId: 'local-removal-test', revision: 2 };
  assert.deepEqual((await call('removeBatchPhoto', '27', '31', removal, scope)).data,
    { requestId: removal.requestId, photoId: '31' });
  assert.deepEqual(scopedRemovals, [removal]);
  const group = { requestId: 'local-group-removal-test', photos: [{ photoId: '31', revision: 0 },
    { photoId: '32', revision: 2 }] };
  assert.match((await call('removePhotoBatch', range, group, { ...scope, scenicId: '1' })).error, /档案已变更/);
  assert.deepEqual((await call('removePhotoBatch', range, group, scope)).data,
    { requestId: group.requestId, removedCount: 2 });
  assert.equal((await call('snapshot')).data.config.activeScenicProfileId, firstId);
  assert.equal(wire.includes(other), false);
  assert.match((await call('__proto__')).error, /不支持/);
  const settings = await call('saveConfig', { printDpi: 360, printers: { ORIGINAL: '受控打印机' } });
  const saved = fs.readFileSync(configPath, 'utf8');
  assert.equal(saved.includes(secret) || saved.includes(other) || saved.includes('retired-shared-token'), false);
  assert.equal(Object.hasOwn(JSON.parse(saved), 'token'), false);
  assert.equal(settings.data.config.printDpi, 360);
  assert.equal(JSON.parse(fs.readFileSync(configPath, 'utf8')).printDpi, 360);
  assert.match((await call('saveConfig', { printDpi: 300.5 })).error, /72–1200/);
  assert.equal((await call('snapshot')).data.config.printDpi, 360);
  const zipPath = path.join(temp, 'print-11.zip');
  const zip = await call('downloadJobZip', '11', zipPath);
  assert.deepEqual(zip.data, { jobId: '11', count: 1, path: zipPath });
  assert.deepEqual(zipEvents, [
    { completed: 0, total: 1, saving: false },
    { completed: 1, total: 1, saving: false },
    { completed: 1, total: 1, saving: true },
  ].map(data => ({ event: 'zipProgress', id: zip.id, data })));
  const printing = call('printJobs', ['9']);
  // 同一管道紧接着发修改请求，必须拒绝并保持原配置。
  const concurrent = await call('saveConfig', { printers: { ORIGINAL: '禁止生效' } });
  assert.match(concurrent.error, /任务处理中/);
  const result = await printing;
  assert.equal(beginCount, 1);
  assert.equal(resultCount, 2); // 原回写及刷新时的结果补传，均无再次送打。
  assert.equal(fs.readFileSync(marker, 'utf8'), '360\n');
  assert.match(JSON.stringify(result), /回写失败/);
  assert.equal(wire.includes(secret), false);
  assert.equal((await call('snapshot')).data.config.printers.ORIGINAL, '受控打印机');
  assert.match((await call('printJobs', ['9'])).error, /中断记录/);
  failResult = false;
  assert.equal((await call('recoverPrintJob', '9', [])).data.state.recoveryJobs.length, 0);
  assert.equal(fs.readFileSync(marker, 'utf8'), '360\n');
  // 界面崩溃、读写管道都关闭时，另一张已开始的工单仍须完成回写。
  void call('printJobs', ['10']);
  const deadline = Date.now() + 10000;
  while (beginCount < 2 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(beginCount, 2);
  const exited = new Promise((resolve) => child.once('exit', resolve));
  child.stdin.end();
  child.stdout.destroy();
  await exited;
  assert.equal(resultCount, 4);
  assert.equal(fs.readFileSync(marker, 'utf8'), '360\n360\n');
  assert.equal(fs.existsSync(path.join(temp, '.runtime/print-desktop.lock')), false);
});
