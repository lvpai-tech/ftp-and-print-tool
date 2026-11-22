'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const { test } = require('node:test');
const { cancelMacJob, parseCupsJobId, probeMacPrinter, requestCups } = require('../src/mac-printer');
const { watchAfterSubmit, printerFaults, filterPrinterFaults, isOnlyPaperOut } = require('../src/printer-status');

function attribute(tag, name, value) {
  const key = Buffer.from(name);
  const bytes = typeof value === 'number' ? Buffer.alloc(4) : Buffer.from(value);
  if (typeof value === 'number') bytes.writeInt32BE(value);
  return Buffer.concat([Buffer.from([tag, 0, key.length]), key, Buffer.from([0, bytes.length]), bytes]);
}

function ippReply(status, ...groups) {
  return Buffer.concat([Buffer.from([1, 1, status >> 8, status & 255, 0, 0, 0, 1]), ...groups, Buffer.from([3])]);
}

test('CUPS IPP 查询读取设备缺纸、卡纸和指定作业，取消只提交该队列的作业 ID', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cups-test-'));
  const socket = process.platform === 'win32'
    ? `\\\\.\\pipe\\lvpai-cups-${path.basename(directory)}` : path.join(directory, 'test.sock');
  let jammed = false;
  let jobReason = 'job-completed-successfully';
  let deviceReason = 'media-empty-error';
  const requests = [];
  const server = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const bytes = Buffer.concat(chunks);
    const operation = bytes.readUInt16BE(2);
    requests.push({ operation, bytes, url: request.url });
    response.setHeader('Content-Type', 'application/ipp');
    if (operation === 0x000b) {
      response.end(ippReply(0, Buffer.from([4]),
        attribute(0x23, 'printer-state', 5),
        attribute(0x22, 'printer-is-accepting-jobs', [1]),
        attribute(0x44, 'printer-state-reasons', deviceReason),
        ...(jammed ? [attribute(0x44, '', 'media-jam-error')] : [])));
    } else if (operation === 0x0009 && jobReason != null) {
      response.end(ippReply(0, Buffer.from([2]),
        attribute(0x21, 'job-id', 42), attribute(0x23, 'job-state', 9),
        attribute(0x44, 'job-state-reasons', jobReason), attribute(0x42, 'job-name', 'lvpai-SIZE_6')));
    } else {
      response.end(ippReply(operation === 0x0009 ? 0x0406 : 0));
    }
  });
  t.after(() => { server.close(); fs.rmSync(directory, { recursive: true, force: true }); });
  server.listen(socket);
  await once(server, 'listening');
  const query = (operation, resource, attributes) => requestCups(operation, resource, attributes, socket);

  const paperOut = await probeMacPrinter('Photo-6', undefined, query);
  assert.equal(isOnlyPaperOut(printerFaults(paperOut)), true);
  assert.deepEqual(filterPrinterFaults(printerFaults(paperOut), { ignorePaperOut: true }), []);
  assert.ok(requests.some(({ operation }) => operation === 0x000a));
  jammed = true;
  const completed = await probeMacPrinter('Photo-6', 42, query);
  assert.deepEqual(filterPrinterFaults(printerFaults(completed), { ignorePaperOut: true }), ['卡纸']);
  assert.deepEqual(completed.jobs, [{ id: 42, documentName: 'lvpai-SIZE_6', status: 'Complete' }]);
  jobReason = 'job-completed-with-errors';
  assert.equal((await probeMacPrinter('Photo-6', 42, query)).jobs[0].status, 'Error');
  jobReason = 'queued-in-device';
  assert.equal((await probeMacPrinter('Photo-6', 42, query)).jobs[0].status, 'Unconfirmed');
  jobReason = null;
  assert.deepEqual((await probeMacPrinter('Photo-6', 42, query)).jobs, []);

  assert.equal(await cancelMacJob('Photo-6', 42, query), true);
  assert.equal(await cancelMacJob('Photo-6', undefined, query), false);
  const cancellations = requests.filter(({ operation }) => operation === 0x0008);
  assert.equal(cancellations.length, 1);
  assert.equal(cancellations[0].url, '/printers/Photo-6');
  assert.ok(cancellations[0].bytes.includes(attribute(0x21, 'job-id', 42)));
  assert.ok(cancellations[0].bytes.includes(attribute(0x45, 'printer-uri', 'ipp://localhost/printers/Photo-6')));
  // 无法解码设备状态时不能把空结果当作正常。
  deviceReason = '';
  jammed = false;
  await assert.rejects(probeMacPrinter('Photo-6', undefined, query), /无效的状态原因/);
});

test('lp 作业编号识别兼容本地化消息及指定队列', () => {
  assert.equal(parseCupsJobId('request id is Photo-6-42 (1 file(s))\n', 'Photo-6'), 42);
  assert.equal(parseCupsJobId('请求 ID 为 photo-6-42（1 个文件）\n', 'Photo-6'), 42);
  assert.equal(parseCupsJobId('request id is Other-Photo-6-42 (1 file(s))\n', 'Photo-6'), null);
  assert.equal(parseCupsJobId('Photo-6-42\nPhoto-6-43\n', 'Photo-6'), null);
});

test('逐张观察只接受本次 CUPS 作业的明确完成状态', async () => {
  const config = { printerPollMs: 1, printerWatchMaxMs: 2, printerSettleMs: 1 };
  const jobs = (id, status) => [{ id, documentName: 'lvpai-SIZE_6', status }];
  function watch(snapshotJobs) {
    let now = 0;
    return watchAfterSubmit({ ...config, statusCommand: [process.execPath, '-e',
      `const id = Number(process.argv[1]);
       if (id !== 42) process.exit(1);
       console.log(JSON.stringify({printerStatus:'Idle',jobs:${JSON.stringify(snapshotJobs)}}));`, '{jobId}'],
    }, ['Photo-6'], 0, { cupsJobId: 42, now: () => now, sleep: async () => { now += 1; } });
  }

  await watch(jobs(42, 'Complete'));
  await assert.rejects(watch(jobs(41, 'Complete')), /超时.*CUPS 作业 42/);
  await assert.rejects(watch(jobs(42, 'Unconfirmed')), /已转交设备/);
  await assert.rejects(watch(jobs(42, 'Deleted')), /已被取消/);
});
