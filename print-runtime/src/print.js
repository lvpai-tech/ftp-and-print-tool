'use strict';

const path = require('node:path');
const { spawn } = require('node:child_process');
const { appRoot } = require('./paths');

/**
 * 按 item.kind 解析本机打印机名。缺映射且无兜底时抛错（整单 FAILED）。
 * COVER（开头片）与 SIZE_6 同为 6 寸纸（开头片横向 3:2），未单独配置时复用 SIZE_6 映射。
 */
function resolvePrinter(config, kind) {
  const printers = config.printers || {};
  const mapped = printers[kind] || (kind === 'COVER' ? printers.SIZE_6 : null);
  if (mapped) return mapped;
  if (config.allowDefaultPrinter && config.defaultPrinter) {
    return config.defaultPrinter;
  }
  throw new Error(`缺少打印机映射：${kind}`);
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
 * 运行打印命令；退出码 0 为受理成功。stdout/stderr 仅截取末尾用于失败原因，不含图片内容。
 */
function runPrintCommand(config, item, file, printer) {
  const args = buildCommandArgs(config, item, file, printer);
  return new Promise((resolve, reject) => {
    const child = spawn(args[0], args.slice(1), {
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    child.stdout.on('data', (chunk) => {
      output = (output + chunk).slice(-300);
    });
    child.stderr.on('data', (chunk) => {
      output = (output + chunk).slice(-300);
    });
    child.on('error', (error) => {
      reject(new Error(`无法启动打印命令：${error.message}`));
    });
    child.on('close', (code) => {
      if (code === 0) resolve({ printer, kind: item.kind });
      else reject(new Error(`打印命令退出码${code}：${output.trim()}`));
    });
  });
}

/**
 * 汇总本单使用过的打印机路由，供 result.printer 回写。
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
  buildCommandArgs,
  runPrintCommand,
  summarizePrinters,
};
