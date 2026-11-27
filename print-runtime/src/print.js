'use strict';

const path = require('node:path');
const { spawn } = require('node:child_process');
const { appRoot } = require('./paths');
const { parseCupsJobId, usesMacPrintScript } = require('./mac-printer');
const { KIND_KEYS } = require('./config');

/**
 * 6 寸照片和开头片使用同一个本机队列。
 */
function resolvePrinter(config, kind, skipPrint = config.skipPrint) {
  if (!KIND_KEYS.includes(kind)) throw new Error(`不支持的照片类型：${kind}`);
  return skipPrint ? config.printer || '' : requirePrinter(config);
}

function requirePrinter(config) {
  if (!config.printer) {
    throw new Error('请先在打印设置中选择并保存本机打印机');
  }
  return config.printer;
}

/**
 * 将命令模板中的占位符替换为实际值；{scriptDir} 为 scripts 目录。
 */
function buildCommandArgs(config, item, file, printer) {
  const scriptDir = config.scriptDir || path.join(appRoot(), 'scripts');
  const values = {
    file,
    kind: item.kind,
    copies: String(item.copies != null ? item.copies : 1),
    printer,
    label: item.label || item.kind,
    scriptDir,
  };
  return config.command.map((part) =>
    part.replace(/\{(file|kind|copies|printer|label|scriptDir)\}/g, (_, key) => values[key]),
  );
}

/**
 * 运行打印命令；退出码 0 为受理成功。保留可用于逐张跟踪的 CUPS 作业 ID。
 */
function runPrintCommand(config, item, file, printer, documentName) {
  const args = buildCommandArgs(config, item, file, printer);
  const macScript = usesMacPrintScript(config.command);
  return new Promise((resolve, reject) => {
    const child = spawn(args[0], args.slice(1), {
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, LVPAI_PRINT_DPI: String(config.printDpi ?? 300),
        LVPAI_PRINT_HIGH_QUALITY: config.highPrintQuality === true ? '1' : '0',
        ...(macScript ? { LVPAI_PRINT_NODE: process.execPath } : {}),
        LVPAI_PRINT_DOCUMENT_NAME: documentName || '' },
    });
    let output = '';
    let stdout = '';
    child.stdout.on('data', (chunk) => {
      output = (output + chunk).slice(-300);
      stdout = (stdout + chunk).slice(-4096);
    });
    child.stderr.on('data', (chunk) => {
      output = (output + chunk).slice(-300);
    });
    child.on('error', (error) => {
      reject(new Error(`无法启动打印命令：${error.message}`));
    });
    child.on('close', (code) => {
      if (code === 0) {
        resolve({ printer, kind: item.kind, cupsJobId: parseCupsJobId(stdout, printer) });
        return;
      }
      const error = new Error(`打印命令退出码${code}：${output.trim()}`);
      if (macScript && code === 2) error.beforeSubmission = true;
      reject(error);
    });
  });
}

/**
 * 汇总本单使用过的打印机，供 result.printer 回写。
 * 库字段约 128 字：按 kind 去重后拼接，超长则改为「张数@打印机名」。
 */
function summarizePrinters(used) {
  if (!used || used.length === 0) return '';
  const parts = [];
  const seen = new Set();
  for (const entry of used) {
    const key = `${entry.kind}=${entry.printer}`;
    if (seen.has(key)) continue;
    seen.add(key);
    parts.push(key);
  }
  const joined = parts.join(';');
  if (joined.length <= 120) return joined;
  const names = [...new Set(used.map((entry) => entry.printer).filter(Boolean))];
  const compact = `${used.length}p@${names.join(',')}`;
  return compact.slice(0, 120);
}

module.exports = {
  resolvePrinter,
  requirePrinter,
  buildCommandArgs,
  runPrintCommand,
  summarizePrinters,
};
