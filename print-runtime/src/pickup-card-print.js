'use strict';

const { execFile } = require('node:child_process');
const { open } = require('node:fs/promises');
const path = require('node:path');
const { promisify } = require('node:util');
const { CUPS_SOCKET, parseCupsJobId } = require('./mac-printer');

const execute = promisify(execFile);
const unknown = '送打结果无法确认，请核对系统队列和已出卡片后再决定是否补打';

async function printPickupCardPdf(root, printer, file) {
  const source = await open(file);
  try {
    const header = Buffer.alloc(5);
    await source.read(header);
    if (header.toString('ascii') !== '%PDF-') throw new Error('取片卡文件不是有效的 PDF');
  } finally {
    await source.close();
  }
  if (process.platform === 'win32') {
    try {
      await execute('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        path.join(root, 'scripts', 'print-pickup-card.ps1')], {
        env: { ...process.env, LVPAI_PICKUP_PRINTER: printer, LVPAI_PICKUP_PDF: file },
        windowsHide: true, timeout: 15 * 60_000,
      });
      return { submitted: true };
    } catch (error) {
      if (error.code === 21) throw new Error('所选打印机未提供 54 × 90 mm 纸型，请在驱动中添加卡纸规格后重试');
      if (error.code === 22) throw new Error('无法读取取片卡 PDF，或页面尺寸不是 54 × 90 mm');
      throw new Error(unknown);
    }
  }
  if (process.platform === 'darwin') {
    const options = { env: { ...process.env, CUPS_SERVER: CUPS_SOCKET, LC_ALL: 'C' }, timeout: 30_000 };
    const { stdout: capabilities } = await execute('/usr/bin/lpoptions', ['-p', printer, '-l'], options);
    const sizes = capabilities.split('\n').find((line) => line.startsWith('PageSize/'))
      ?.split(': ').at(1)?.trim().split(/\s+/).map((value) => value.replace(/^\*/, '')) ?? [];
    const media = sizes.find((size) => /(?:^|_)54x90(?:mm)?$/i.test(size)) ??
      (sizes.includes('Custom') ? 'Custom.54x90mm' : null);
    if (!media) throw new Error('所选打印机未提供 54 × 90 mm 或自定义纸型，请检查系统打印机配置');
    try {
      const { stdout } = await execute('/usr/bin/lp', ['-d', printer, '-n', '1',
        '-t', path.basename(file), '-o', `media=${media}`, '-o', 'sides=one-sided',
        '-o', 'print-scaling=none', '-o', 'ipp-attribute-fidelity=true', '--', file], options);
      const jobId = parseCupsJobId(stdout, printer);
      if (jobId == null) throw new Error(unknown);
      return { submitted: true, jobId: `${printer}-${jobId}` };
    } catch (_) {
      throw new Error(unknown);
    }
  }
  throw new Error('当前平台仅支持下载取片卡文件');
}

module.exports = { printPickupCardPdf };
