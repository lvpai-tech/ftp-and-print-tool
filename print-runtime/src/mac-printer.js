'use strict';

const http = require('node:http');
const os = require('node:os');

const CUPS_SOCKET = '/private/var/run/cupsd';
const CANCEL_JOB = 0x0008;
const GET_JOB_ATTRIBUTES = 0x0009;
const GET_JOBS = 0x000a;
const GET_PRINTER_ATTRIBUTES = 0x000b;
const NOT_FOUND = 0x0406;
const INTEGER = 0x21;
const ENUM = 0x23;
const BOOLEAN = 0x22;
const NAME = 0x42;
const KEYWORD = 0x44;
const URI = 0x45;
const MAX_RESPONSE_BYTES = 1024 * 1024;

const DEVICE_FAULTS = new Map([
  ['media-empty', 'PaperOut'], ['media-needed', 'PaperOut'], ['media-jam', 'PaperJam'],
  ['paused', 'Paused'], ['moving-to-paused', 'Paused'], ['offline', 'Offline'],
  ['shutdown', 'Offline'], ['service-off-line', 'Offline'],
  ['door-open', 'DoorOpen'], ['cover-open', 'DoorOpen'],
  ['toner-empty', 'NoToner'], ['marker-supply-empty', 'NoToner'],
  ['output-area-full', 'OutputBinFull'], ['interlock-open', 'DoorOpen'],
]);

function usesMacPrintScript(command) {
  return command.some((arg) => /(?:^|[\\/])print-image-mac\.sh$/.test(arg));
}

function parseCupsJobId(output, printer) {
  // lp 本地化的是说明文字，作业标识仍为 queue-number。
  const queue = printer.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const ids = new Set([...output.matchAll(new RegExp(`(?:^|[^\\w.-])${queue}-([1-9]\\d*)\\b`, 'gi'))]
    .map((match) => Number(match[1])));
  const [id] = ids;
  return ids.size === 1 && id <= 0x7fffffff ? id : null;
}

// RFC 8010 operation attributes. Only scalar values and repeated keywords are requested.
function encodeRequest(operation, attributes) {
  const parts = [Buffer.from([1, 1, operation >> 8, operation & 0xff, 0, 0, 0, 1, 1])];
  for (const [tag, name, values] of [
    [0x47, 'attributes-charset', ['utf-8']],
    [0x48, 'attributes-natural-language', ['en']],
    ...attributes,
  ]) {
    for (const [index, value] of values.entries()) {
      const key = Buffer.from(index === 0 ? name : '');
      const data = typeof value === 'number' ? Buffer.alloc(4) : Buffer.from(value);
      if (typeof value === 'number') data.writeInt32BE(value);
      const lengths = Buffer.alloc(4);
      lengths.writeUInt16BE(key.length);
      lengths.writeUInt16BE(data.length, 2);
      parts.push(Buffer.from([tag]), lengths.subarray(0, 2), key, lengths.subarray(2), data);
    }
  }
  return Buffer.concat([...parts, Buffer.from([3])]);
}

function decodeResponse(buffer) {
  if (buffer.length < 9 || buffer.readInt32BE(4) !== 1) throw new Error('CUPS 返回无效 IPP 响应');
  const status = buffer.readUInt16BE(2);
  const groups = [];
  let offset = 8;
  let group;
  let name;

  function readField() {
    if (offset + 2 > buffer.length) throw new Error('CUPS 返回不完整的 IPP 属性');
    const length = buffer.readUInt16BE(offset);
    offset += 2;
    if (offset + length > buffer.length) throw new Error('CUPS 返回不完整的 IPP 属性');
    const field = buffer.subarray(offset, offset + length);
    offset += length;
    return field;
  }

  while (offset < buffer.length) {
    const tag = buffer[offset++];
    if (tag === 3) return { status, groups };
    if (tag <= 0x0f) {
      group = { tag, attributes: new Map() };
      groups.push(group);
      name = undefined;
      continue;
    }
    const key = readField();
    const data = readField();
    if (key.length) name = key.toString();
    if (!group || !name) throw new Error('CUPS 返回无效的 IPP 属性');
    let value;
    if ((tag === INTEGER || tag === ENUM) && data.length === 4) value = data.readInt32BE();
    if (tag === BOOLEAN && data.length === 1 && data[0] <= 1) value = data[0] === 1;
    if ([0x41, NAME, KEYWORD].includes(tag)) value = data.toString();
    if (value !== undefined) {
      const previous = group.attributes.get(name) || [];
      group.attributes.set(name, [...previous, value]);
    }
  }
  throw new Error('CUPS 返回不完整的 IPP 响应');
}

function requestCups(operation, resource, attributes, socketPath = CUPS_SOCKET) {
  const payload = encodeRequest(operation, attributes);
  return new Promise((resolve, reject) => {
    const request = http.request({
      socketPath, path: resource, method: 'POST', agent: false,
      headers: { Host: 'localhost', 'Content-Type': 'application/ipp', 'Content-Length': payload.length },
      signal: AbortSignal.timeout(5000),
    }, async (response) => {
      try {
        if (response.statusCode !== 200) throw new Error(`CUPS HTTP ${response.statusCode}`);
        const chunks = [];
        let size = 0;
        for await (const chunk of response) {
          size += chunk.length;
          if (size > MAX_RESPONSE_BYTES) throw new Error('CUPS IPP 响应超出限制');
          chunks.push(chunk);
        }
        resolve(decodeResponse(Buffer.concat(chunks)));
      } catch (error) {
        response.destroy();
        reject(error);
      }
    });
    request.on('error', reject);
    request.end(payload);
  });
}

function faultFlags(reasons) {
  const faults = new Set();
  for (const reason of reasons) {
    if (typeof reason !== 'string' || !reason.length) throw new Error('CUPS 返回无效的状态原因');
    const keyword = reason.replace(/-(error|warning|report)$/, '');
    const flag = DEVICE_FAULTS.get(keyword);
    if (flag) faults.add(flag);
    else if (reason.endsWith('-error')) faults.add('Error');
  }
  return faults;
}

function printerFlags(attributes) {
  const state = attributes.get('printer-state')?.[0];
  const reasons = attributes.get('printer-state-reasons');
  const acceptsJobs = attributes.get('printer-is-accepting-jobs')?.[0];
  if (![3, 4, 5].includes(state) || !reasons?.length || typeof acceptsJobs !== 'boolean') {
    throw new Error('CUPS 未返回完整的打印机状态');
  }
  const flags = faultFlags(reasons);
  if (!acceptsJobs) flags.add('NotAvailable');
  if (state === 5 && !flags.size) flags.add('Paused');
  if (state === 4) flags.add('Printing');
  if (!flags.size) flags.add('Idle');
  return flags;
}

function jobSnapshot(attributes, deviceFlags) {
  const id = attributes.get('job-id')?.[0];
  const state = attributes.get('job-state')?.[0];
  const reasons = attributes.get('job-state-reasons');
  if (!Number.isInteger(id) || id < 1 || !Number.isInteger(state) || state < 3 || state > 9 || !reasons?.length) {
    throw new Error('CUPS 未返回有效的作业状态');
  }
  const flags = faultFlags(reasons);
  if (state === 9 && reasons.includes('queued-in-device')) flags.add('Unconfirmed');
  if (state === 4) flags.add('Paused');
  if (state === 6 && !flags.size && !deviceFlags.has('PaperOut')) flags.add('Blocked');
  if (state === 7) flags.add('Deleted');
  if (state === 8 || reasons.includes('job-completed-with-errors')) flags.add('Error');
  if (state === 9 && !flags.has('Unconfirmed') && !flags.has('Error')) flags.add('Complete');

  return {
    id,
    documentName: attributes.get('job-name')?.[0] || '',
    status: [...flags].join(', ') || (state === 3 ? 'Pending' : 'Processing'),
  };
}

function queueTarget(printer, jobId) {
  if (!printer || /[\s/#?]/.test(printer) || printer === '.' || printer === '..') {
    throw new Error('缺少有效的 CUPS 打印队列');
  }
  const resource = `/printers/${encodeURIComponent(printer)}`;
  const attributes = [[URI, 'printer-uri', [`ipp://localhost${resource}`]]];
  if (jobId != null) {
    if (!Number.isInteger(jobId) || jobId < 1 || jobId > 0x7fffffff) throw new Error('无效的 CUPS 作业编号');
    attributes.push([INTEGER, 'job-id', [jobId]]);
  }
  attributes.push([NAME, 'requesting-user-name', [os.userInfo().username]]);
  return { resource, attributes };
}

async function probeMacPrinter(printer, jobId, request = requestCups) {
  const { resource, attributes: destination } = queueTarget(printer);
  const jobTarget = jobId == null ? null : queueTarget(printer, jobId);
  const requested = (names) => [KEYWORD, 'requested-attributes', names];
  const jobFields = requested(['job-id', 'job-state', 'job-state-reasons', 'job-name']);
  const [device, queue] = await Promise.all([
    request(GET_PRINTER_ATTRIBUTES, resource, [...destination,
      requested(['printer-state', 'printer-state-reasons', 'printer-is-accepting-jobs'])]),
    jobId == null
      ? request(GET_JOBS, resource, [...destination, [INTEGER, 'limit', [50]], jobFields])
      : request(GET_JOB_ATTRIBUTES, resource, [...jobTarget.attributes, jobFields]),
  ]);
  if (device.status >= 0x0100) throw new Error(`无法读取 CUPS 打印机状态（IPP 0x${device.status.toString(16)}）`);
  const attributes = device.groups.find(({ tag }) => tag === 4)?.attributes;
  if (!attributes) throw new Error('CUPS 未返回打印机属性');
  const flags = printerFlags(attributes);
  if (queue.status >= 0x0100 && !(jobId != null && queue.status === NOT_FOUND)) {
    throw new Error(`无法读取 CUPS 作业状态（IPP 0x${queue.status.toString(16)}）`);
  }
  const jobs = queue.status === NOT_FOUND ? [] : queue.groups
    .filter(({ tag }) => tag === 2).map(({ attributes: job }) => jobSnapshot(job, flags));
  return { printer, printerStatus: [...flags].join(', '), jobs };
}

async function cancelMacJob(printer, jobId, request = requestCups) {
  if (jobId == null) return false;
  const { resource, attributes } = queueTarget(printer, jobId);
  const response = await request(CANCEL_JOB, resource, attributes);
  return response.status < 0x0100;
}

if (require.main === module) {
  const [printer, id] = process.argv.slice(2);
  probeMacPrinter(printer, id ? Number(id) : undefined).then((snapshot) => {
    process.stdout.write(`${JSON.stringify(snapshot)}\n`);
  }).catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}

module.exports = { CUPS_SOCKET, cancelMacJob, parseCupsJobId, probeMacPrinter, requestCups, usesMacPrintScript };
