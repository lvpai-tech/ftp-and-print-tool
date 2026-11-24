'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const { probePrinter, recoveryQueueState } = require('./printer-status');

function createPrintRecovery(config) {
  const scope = createHash('sha256')
    .update(JSON.stringify([config.base, config.activeScenicProfileId || config.token])).digest('hex');
  const directory = path.join(config.lockDir, 'print-recovery', scope);
  const jobs = new Map();
  let error = '';
  try {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    for (const name of fs.readdirSync(directory)) {
      if (!/^[1-9]\d*\.json$/.test(name)) continue;
      const record = JSON.parse(fs.readFileSync(path.join(directory, name), 'utf8'));
      if (record.version !== 1 || typeof record.id !== 'string' || `${record.id}.json` !== name
          || !Array.isArray(record.sheets) || !record.sheets.length
          || !Number.isSafeInteger(record.attempt) || record.attempt < 1
          || !record.sheets.every(sheet => typeof sheet?.fileUrl === 'string' && typeof sheet.kind === 'string'
            && ['READY', 'UNCERTAIN', 'DONE'].includes(sheet.state))
          || (record.result && (record.result.attempt !== record.attempt
            || !['PRINTED', 'FAILED'].includes(record.result.status)))) {
        throw new Error('无法读取打印恢复记录');
      }
      jobs.set(record.id, record);
    }
  } catch {
    error = '无法读取本机打印恢复记录，请检查本机存储后重启工作台';
  }

  function save(record) {
    if (error) throw new Error(error);
    const file = path.join(directory, `${record.id}.json`);
    const temporary = `${file}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(record), { mode: 0o600, flush: true });
    fs.renameSync(temporary, file);
    if (process.platform !== 'win32') {
      const fd = fs.openSync(directory, 'r');
      try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    }
    jobs.set(record.id, record);
    return record;
  }

  function remove(id) {
    fs.rmSync(path.join(directory, `${id}.json`), { force: true });
    jobs.delete(id);
  }

  function begin(job, sheets, startAt, row) {
    const id = String(job.id);
    if (!/^[1-9]\d*$/.test(id) || !Number.isSafeInteger(job.attempt) || job.attempt < 1 || !sheets.length) {
      throw new Error('缺少有效的工单领取次数或打印清单，未送打');
    }
    if (jobs.has(id)) throw new Error('此工单有中断记录，请先核对打印');
    return save({ version: 1, id, attempt: job.attempt, createdAt: row?.createdAt, cardTail: row?.cardTail,
      sheets: sheets.map((item, index) => ({ ...sheetIdentity(item), label: item.label,
        state: index < startAt ? 'DONE' : 'READY' })) });
  }

  function mark(record, index, values) {
    return save({ ...record, sheets: record.sheets.map((sheet, i) => i === index ? { ...sheet, ...values } : sheet) });
  }

  function beforeSubmit(record, index, printer, kind) {
    return mark(record, index, { state: 'UNCERTAIN', printer, spoolId: null,
      documentName: `lvpai-${kind}-${randomUUID()}` });
  }

  function seal(record, result) {
    return save({ ...record, result });
  }

  return { jobs, error, begin, beforeSubmit, mark, seal, save, remove };
}

function sheetIdentity(item) {
  return { kind: item.kind, fileUrl: item.fileUrl.replace('/preview-files/', '/files/') };
}

function matchesSheets(record, sheets) {
  return record.sheets.length === sheets.length && sheets.every((item, index) => {
    const expected = sheetIdentity(item);
    return record.sheets[index].fileUrl === expected.fileUrl && record.sheets[index].kind === expected.kind;
  });
}

async function readRecoveryQueue(config, sheet) {
  if (!Array.isArray(config.statusCommand)) return 'UNAVAILABLE';
  try {
    const snapshot = await probePrinter(config, sheet.printer, sheet.spoolId);
    return recoveryQueueState(snapshot, sheet.documentName, sheet.spoolId);
  } catch {
    return 'UNAVAILABLE';
  }
}

module.exports = { createPrintRecovery, matchesSheets, readRecoveryQueue };
