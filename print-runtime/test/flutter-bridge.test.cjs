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
test('Flutter桥：真实密钥校验、脱敏、互斥与回写失败不重打', async (t) => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'flutter-print-test-'));
  let beginCount = 0;
  let resultCount = 0;
  let failResult = true;
  const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json');
    if (req.headers['x-print-agent-token'] !== 'controlled-secret') {
      res.end(JSON.stringify({ code: 401, message: '密钥无效' })); return;
    }
    let data;
    if (req.url === '/print-agents/me') data = { scenicId: '1', scenicName: '隔离测试景区' };
    else if (req.url.startsWith('/print-agents/jobs?')) data = { list: [], total: 0 };
    else if (req.url === '/print-agents/jobs/9/begin') {
      beginCount++;
      data = { id: '9', target: 'PHOTOS', items: [{ kind: 'ORIGINAL', copies: 1, fileUrl: '/image' }] };
    } else if (req.url === '/image') {
      res.setHeader('Content-Type', 'image/jpeg'); res.end(Buffer.from([255, 216, 255, 217])); return;
    } else if (req.url === '/print-agents/jobs/9/result') {
      resultCount++;
      res.end(JSON.stringify(failResult ? { code: 503, message: '受控回写失败' } : { code: 200, data: true })); return;
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
  readline.createInterface({ input: child.stdout }).on('line', (line) => {
    wire += line;
    const response = JSON.parse(line);
    if (response.id != null) { pending.get(response.id)?.(response); pending.delete(response.id); }
  });
  const call = (method, ...args) => new Promise((resolve) => {
    const id = ++sequence; pending.set(id, resolve);
    child.stdin.write(`${JSON.stringify({ id, method, args })}\n`);
  });
  assert.equal((await call('snapshot')).data.configured, false);
  assert.match((await call('configure', { token: 'bad' })).error, /401/);
  assert.equal(fs.existsSync(configPath), false);
  const configured = await call('configure', { token: 'controlled-secret' });
  assert.equal(configured.data.configured, true);
  assert.equal(configured.data.config.token, '[已配置]');
  assert.equal(configured.data.config.printDpi, 300);
  assert.equal(configured.data.state.autoPrint, false);
  assert.match((await call('__proto__')).error, /不支持/);
  const marker = path.join(temp, 'submitted');
  const settings = await call('saveConfig', { statusCommand: null, resultRetries: 1, printDpi: 360,
    printers: { ORIGINAL: '受控打印机' }, command: [process.execPath, '-e',
      'require("node:fs").appendFileSync(process.argv[1], process.env.LVPAI_PRINT_DPI + "\\n");setTimeout(()=>{},200)', marker] });
  assert.equal(settings.data.config.printDpi, 360);
  assert.equal(JSON.parse(fs.readFileSync(configPath, 'utf8')).printDpi, 360);
  assert.match((await call('saveConfig', { printDpi: 300.5 })).error, /72–1200/);
  assert.equal((await call('snapshot')).data.config.printDpi, 360);
  const printing = call('printJobs', ['9']);
  // 同一管道紧接着发修改请求，必须拒绝并保持原配置。
  const concurrent = await call('saveConfig', { printers: { ORIGINAL: '禁止生效' } });
  assert.match(concurrent.error, /任务处理中/);
  const result = await printing;
  assert.equal(beginCount, 1);
  assert.equal(resultCount, 1);
  assert.equal(fs.readFileSync(marker, 'utf8'), '360\n');
  assert.match(JSON.stringify(result), /回写失败/);
  assert.equal(wire.includes('controlled-secret'), false);
  assert.equal((await call('snapshot')).data.config.printers.ORIGINAL, '受控打印机');
  // 界面崩溃、读写管道都关闭时，已开始的打印仍须完成回写且不得再送第二次。
  failResult = false;
  void call('printJobs', ['9']);
  const deadline = Date.now() + 10000;
  while (beginCount < 2 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(beginCount, 2);
  const exited = new Promise((resolve) => child.once('exit', resolve));
  child.stdin.end();
  child.stdout.destroy();
  await exited;
  assert.equal(resultCount, 2);
  assert.equal(fs.readFileSync(marker, 'utf8'), '360\n360\n');
  assert.equal(fs.existsSync(path.join(temp, '.runtime/print-desktop.lock')), false);
});
