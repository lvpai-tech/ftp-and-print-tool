'use strict';
/** 原生界面只读验收夹具；写接口全部拒绝，不能用于业务运行。 */
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const directory = path.join(root, '.local/print-flutter/native-smoke');
fs.mkdirSync(directory, { recursive: true });
const requests = [];
const server = http.createServer((req, res) => {
  requests.push({ method: req.method, url: req.url });
  fs.writeFileSync(path.join(directory, 'requests.json'), JSON.stringify(requests, null, 2));
  res.setHeader('Content-Type', 'application/json');
  if (req.method !== 'GET') {
    res.statusCode = 409;
    res.end(JSON.stringify({ code: 409, message: '原生只读验收禁止出纸或修改工单' }));
    return;
  }
  const data = req.url.startsWith('/print-agents/jobs?') ? {
    total: 3, pageNum: 1, pageSize: 20, list: [
      { id: '9007199254740993', cardTail: '4987', status: 'QUEUED', contentSummary: '开头片 1 · 原片 2 · 创意成片 6', createdAt: '2026-11-19 14:20:00' },
      { id: '9007199254740994', cardTail: '1907', status: 'FAILED', contentSummary: '开头片 1 · 原片 4', completedSheets: 2, totalSheets: 5, errorReason: '受控场景：缺纸，请核对实物后继续', createdAt: '2026-11-19 14:10:00' },
      { id: '9007199254740995', cardTail: '2820', status: 'PRINTED', contentSummary: '开头片 1 · 原片 2', completedSheets: 3, totalSheets: 3, createdAt: '2026-11-19 14:00:00' },
    ],
  } : { id: '9007199254740993', items: [] };
  res.end(JSON.stringify({ code: 200, data }));
});
server.listen(0, '127.0.0.1', () => {
  const configPath = path.join(directory, 'config.json');
  const config = JSON.parse(fs.readFileSync(path.join(root, 'print-desktop/config.example.json'), 'utf8'));
  Object.assign(config, { base: `http://127.0.0.1:${server.address().port}`, token: 'isolated-native-smoke',
    autoPrint: false, scenicName: '隔离自动化测试 · 非业务数据', scenicIds: ['1'], printers: {} });
  fs.writeFileSync(configPath, JSON.stringify(config));
  const exe = path.join(root, 'ftp-client/build/windows/x64/runner/Release/lvpai_ftp_client.exe');
  const log = fs.openSync(path.join(directory, 'desktop.log'), 'w');
  const child = spawn(exe, [], { env: { ...process.env, PRINT_AGENT_CONFIG: configPath,
    PRINT_AGENT_BASE: config.base }, stdio: ['ignore', log, log], windowsHide: true });
  fs.closeSync(log);
  fs.writeFileSync(path.join(directory, 'process.json'), JSON.stringify({ pid: child.pid, exe }));
  console.log(`只读验收窗口 PID ${child.pid}`);
  child.once('exit', () => server.close());
  child.once('error', (error) => { console.error(error); server.close(); process.exitCode = 1; });
});
