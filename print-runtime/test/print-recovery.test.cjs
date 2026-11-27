'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const { createScheduler } = require('../src/scheduler');
const { createPrintRecovery } = require('../src/print-recovery');
const { recoveryQueueState } = require('../src/printer-status');

test('仅匹配同一作业标题及已记录编号，明确完成才可自动恢复', () => {
  const printer = { printerStatus: 'Idle', jobs: [{ id: 2, documentName: 'lvpai-current', status: 'Complete' }] };
  assert.equal(recoveryQueueState(printer, 'lvpai-current', 2), 'DONE');
  assert.equal(recoveryQueueState(printer, 'lvpai-other', 2), 'UNAVAILABLE');
  assert.equal(recoveryQueueState(printer, 'lvpai-current', 3), 'UNAVAILABLE');
  assert.equal(recoveryQueueState({ ...printer, printerStatus: 'Printing' }, 'lvpai-current', 2), 'UNAVAILABLE');
  const transferred = { ...printer, jobs: [{ ...printer.jobs[0], status: 'Unconfirmed' }] };
  assert.equal(recoveryQueueState(transferred, 'lvpai-current', 2), 'UNAVAILABLE');
});

async function waitFor(check) {
  const deadline = Date.now() + 5000;
  while (!check()) {
    if (Date.now() >= deadline) throw new Error('等候受控打印进程超时');
    await delay(20);
  }
}

async function fixture(t, hold) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'print-disruption-'));
  const marker = path.join(directory, 'spool.jsonl');
  const queueFile = path.join(directory, 'queue.json');
  fs.writeFileSync(marker, '');
  fs.writeFileSync(queueFile, '[]');
  const attempts = [];
  const reports = [];
  const items = [1, 2, 3].map(photo => ({ kind: 'ORIGINAL', copies: 1, label: `原片 ${photo}`,
    fileUrl: `/print-agents/jobs/41/files/PHOTO/${photo}` }));
  const row = { id: '41', attempt: 1, totalSheets: 3, completedSheets: 0 };
  let stoppedAt = '';
  let state = 'QUEUED';
  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, 'http://localhost');
    const json = data => response.end(JSON.stringify({ code: 200, data }));
    if (url.pathname === '/print-agents/jobs') {
      const list = state === 'QUEUED' ? [{ ...row, status: state }] : [];
      return json({ list, pageNum: 1, pageSize: 20, total: list.length });
    }
    if (url.pathname.endsWith('/begin')) {
      attempts.push('begin');
      state = 'CLAIMED';
      return json({ ...row, status: state, items });
    }
    if (url.pathname.endsWith('/preview')) {
      return json({ ...row, status: state, items: items.map(item => ({ ...item,
        fileUrl: item.fileUrl.replace('/files/', '/preview-files/'),
      })) });
    }
    if (url.pathname.endsWith('/recover')) {
      attempts.push('recover');
      const payload = JSON.parse(await request.setEncoding('utf8').toArray().then(parts => parts.join('')));
      assert.equal(payload.attempt, 1);
      state = 'CLAIMED';
      return json({ ...row, status: state, items });
    }
    if (url.pathname.endsWith('/result')) {
      const result = JSON.parse(await request.setEncoding('utf8').toArray().then(parts => parts.join('')));
      reports.push(result);
      if (hold === 'result' && !stoppedAt) { stoppedAt = 'result'; return; }
      state = result.status;
      return json({ ...row, status: state });
    }
    const number = url.pathname.split('/').at(-1);
    if (hold === 'before' && !stoppedAt) { stoppedAt = 'before'; return; }
    response.setHeader('Content-Type', 'image/jpeg');
    return response.end(number);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const command = `const fs = require('node:fs'); const [marker, file, hold] = process.argv.slice(1);
    const id = Number(fs.readFileSync(file, 'utf8'));
    const name = process.env.LVPAI_PRINT_DOCUMENT_NAME;
    fs.appendFileSync(marker, JSON.stringify({ id, name }) + '\\n');
    if (hold !== String(id)) console.log('request id is printer-' + id + ' (1 file)');
    else setTimeout(() => {}, 2000);`;
  const check = `const fs = require('node:fs'); const [queue, marker, id, hold] = process.argv.slice(1);
    const statuses = JSON.parse(fs.readFileSync(queue));
    const line = fs.readFileSync(marker, 'utf8').trim().split('\\n').filter(Boolean).map(JSON.parse);
    const jobs = line.filter(entry => !id || entry.id === Number(id)).flatMap(entry => {
      const status = statuses[entry.id] ?? (hold === String(entry.id) ? 'Pending' : 'Complete');
      return status === 'missing' ? [] : [{ id: entry.id, documentName: entry.name, status }];
    });
    console.log(JSON.stringify({ printerStatus: 'Idle', jobs }));`;
  const waitingSheet = hold === 'after' ? '2' : '';
  const config = { base: `http://127.0.0.1:${server.address().port}`, token: 'print-recovery-test',
    lockDir: directory, printer: 'printer', resultRetries: 1,
    printerSheetSettleMs: 0, printerWatchMaxMs: 3000, printerPollMs: 25,
    command: [process.execPath, '-e', command, marker, '{file}', waitingSheet],
    statusCommand: [process.execPath, '-e', check, queueFile, marker, '{jobId}', waitingSheet] };
  const script = `const { createScheduler } = require(process.argv[1]);
    const scheduler = createScheduler({config: JSON.parse(process.argv[2]), includePrintIssues: true, log(){}});
    scheduler.printJobIds(['41']).catch(error => { console.error(error); process.exitCode = 1; });`;
  const child = spawn(process.execPath, ['-e', script, require.resolve('../src/scheduler'), JSON.stringify(config)],
    { windowsHide: true, stdio: 'ignore' });
  const exited = once(child, 'exit');
  t.after(async () => {
    child.kill();
    await exited;
    server.closeAllConnections();
    server.close();
    fs.rmSync(directory, { recursive: true, force: true });
  });
  const paper = () => fs.readFileSync(marker, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  await waitFor(() => stoppedAt || (hold === 'after' && paper().length === 2));
  child.kill();
  await exited;
  state = 'UNKNOWN';
  const newConfig = { ...config, command: [...config.command.slice(0, -1), ''] };
  const scheduler = createScheduler({ config: newConfig, includePrintIssues: true, log() {} });
  await scheduler.refreshJobs();
  return { scheduler, attempts, reports, paper, config, queueFile };
}

test('打印进程在下载后送打前被杀，重启后只送一次已知未提交的照片', { timeout: 15000 }, async (t) => {
  const { scheduler, paper, attempts } = await fixture(t, 'before');
  assert.equal(paper().length, 0);
  assert.deepEqual(scheduler.recoveryDetails('41').sheets.map(sheet => sheet.state), ['READY', 'READY', 'READY']);
  await assert.rejects(scheduler.printJobIds(['41']), /中断记录/);
  await scheduler.recoverPrintJob('41', [0, 1, 2]);
  assert.deepEqual(paper().map(sheet => sheet.id), [1, 2, 3]);
  assert.deepEqual(attempts, ['begin', 'recover']);
  assert.deepEqual(scheduler.getState().recoveryJobs, []);
});

test('已送打但尚未取得编号时强制退出，排队作业禁止补印，核对后只补缺少的照片',
  { timeout: 15000 }, async (t) => {
    const { scheduler, paper, attempts, queueFile, config } = await fixture(t, 'after');
    const record = createPrintRecovery(config).jobs.get('41');
    assert.equal(record.sheets[1].spoolId, null);
    assert.deepEqual(scheduler.recoveryDetails('41').sheets.map(sheet => sheet.state), ['DONE', 'UNCERTAIN', 'READY']);
    // 队列查询没有编号时按与已刷盘记录一致的作业标题匹配。
    const activeQueue = [null, null, 'Pending'];
    fs.writeFileSync(queueFile, JSON.stringify(activeQueue));
    await assert.rejects(scheduler.recoverPrintJob('41', [1, 2]), /仍在系统打印队列/);
    fs.writeFileSync(queueFile, JSON.stringify([null, null, 'missing']));
    await scheduler.recoverPrintJob('41', [2]);
    assert.deepEqual(paper().map(sheet => sheet.id), [1, 2, 3]);
    assert.deepEqual(attempts, ['begin', 'recover']);
  });

test('全部送打后回写前强杀，重启自动补传结果而不重送', { timeout: 15000 }, async (t) => {
  const { scheduler, attempts, paper, reports } = await fixture(t, 'result');
  assert.deepEqual(paper().map(sheet => sheet.id), [1, 2, 3]);
  assert.deepEqual(attempts, ['begin']);
  assert.deepEqual(reports.map(result => [result.status, result.completedSheets]), [['PRINTED', 3], ['PRINTED', 3]]);
  assert.deepEqual(scheduler.getState().recoveryJobs, []);
});
