'use strict';

const http = require('node:http');
const { URL } = require('node:url');
const { normalizeConfig, saveConfig, redactConfig, toWritableConfig } = require('./config');

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve(null);
      try {
        resolve(JSON.parse(raw));
      } catch (error) {
        reject(new Error(`请求体不是合法JSON：${error.message}`));
      }
    });
    request.on('error', reject);
  });
}

function sendJson(response, status, data) {
  const body = JSON.stringify(data);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  response.end(body);
}

function sendHtml(response, html) {
  response.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  response.end(html);
}

function pageHtml() {
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>旅派打印代理</title>
  <style>
    :root {
      --bg: #0f1419;
      --panel: #1a222c;
      --text: #e8eef4;
      --muted: #8b9aab;
      --accent: #3d9cf0;
      --ok: #3ecf8e;
      --warn: #f0b429;
      --bad: #f07178;
      --line: #2a3542;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
      background: radial-gradient(1200px 600px at 10% -10%, #1c2a3a, var(--bg));
      color: var(--text); min-height: 100vh; padding: 24px;
    }
    h1 { font-size: 1.4rem; margin: 0 0 4px; letter-spacing: 0.02em; }
    .sub { color: var(--muted); margin-bottom: 20px; font-size: 0.9rem; }
    .grid { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); }
    section {
      background: color-mix(in srgb, var(--panel) 92%, transparent);
      border: 1px solid var(--line); border-radius: 12px; padding: 16px 18px;
    }
    h2 { font-size: 0.95rem; margin: 0 0 12px; color: var(--muted); font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; }
    .row { display: flex; justify-content: space-between; gap: 12px; padding: 6px 0; border-bottom: 1px solid var(--line); }
    .row:last-child { border-bottom: 0; }
    .label { color: var(--muted); }
    .value { font-family: ui-monospace, Consolas, monospace; text-align: right; word-break: break-all; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 0.8rem; }
    .badge.ok { background: rgba(62,207,142,0.15); color: var(--ok); }
    .badge.warn { background: rgba(240,180,41,0.15); color: var(--warn); }
    .badge.bad { background: rgba(240,113,120,0.15); color: var(--bad); }
    .actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
    button, .btn {
      background: var(--accent); color: #041018; border: 0; border-radius: 8px;
      padding: 8px 14px; font-weight: 600; cursor: pointer;
    }
    button.secondary { background: #2a3542; color: var(--text); }
    button.danger { background: var(--bad); color: #1a0506; }
    label { display: block; margin: 10px 0 4px; color: var(--muted); font-size: 0.85rem; }
    input, textarea {
      width: 100%; background: #101820; border: 1px solid var(--line); color: var(--text);
      border-radius: 8px; padding: 8px 10px; font-family: ui-monospace, Consolas, monospace;
    }
    table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
    th, td { text-align: left; padding: 6px 4px; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { color: var(--muted); font-weight: 500; }
    .msg { margin-top: 10px; color: var(--ok); min-height: 1.2em; }
    .msg.err { color: var(--bad); }
    .wide { grid-column: 1 / -1; }
  </style>
</head>
<body>
  <h1>旅派工作台打印代理</h1>
  <p class="sub">仅本机 127.0.0.1 · 纯 PHOTOS 队列 · 不碰小票</p>
  <div class="grid">
    <section>
      <h2>运行状态</h2>
      <div id="status"></div>
      <div class="actions">
        <button type="button" id="btnRefresh">刷新任务列表</button>
        <button type="button" class="secondary" id="btnAutoOn">开自动打印</button>
        <button type="button" class="secondary" id="btnAutoOff">关自动打印</button>
        <button type="button" class="secondary" id="btnReload">重载配置</button>
      </div>
      <div class="msg" id="actionMsg"></div>
    </section>
    <section>
      <h2>打印机路由</h2>
      <div id="printers"></div>
    </section>
    <section class="wide">
      <h2>最近结果</h2>
      <div id="history"></div>
    </section>
    <section class="wide">
      <h2>配置（保存后热加载调度）</h2>
      <form id="cfgForm">
        <label>运营 API 根 (base)</label>
        <input name="base" required />
        <label>Token（留空表示不修改）</label>
        <input name="token" type="password" autocomplete="off" placeholder="••••" />
        <label>景区 scenicIds（逗号分隔）</label>
        <input name="scenicIds" />
        <label>pollMs / idleBackoffMs / resultRetries</label>
        <input name="timing" placeholder="3000,12000,5" />
        <label>allowDefaultPrinter（true/false）</label>
        <input name="allowDefaultPrinter" />
        <label>defaultPrinter</label>
        <input name="defaultPrinter" />
        <label>printers JSON</label>
        <textarea name="printers" rows="5"></textarea>
        <label>command JSON 数组</label>
        <textarea name="command" rows="6"></textarea>
        <div class="actions">
          <button type="submit">保存并热加载</button>
        </div>
        <div class="msg" id="cfgMsg"></div>
      </form>
    </section>
  </div>
  <script>
    function badge(phase, autoPrint) {
      if (phase === 'printing') return '<span class="badge ok">打印中</span>';
      if (phase === 'listing') return '<span class="badge ok">查询中</span>';
      if (phase === 'error') return '<span class="badge bad">错误</span>';
      if (phase === 'stopped') return '<span class="badge bad">已停止</span>';
      return '<span class="badge ok">' + (autoPrint ? '自动打印开' : '在线') + '</span>';
    }
    function esc(s) {
      return String(s == null ? '' : s)
        .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }
    async function api(path, opts) {
      const res = await fetch(path, opts);
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || res.statusText);
      return data;
    }
    function showMsg(el, text, err) {
      el.textContent = text || '';
      el.className = err ? 'msg err' : 'msg';
    }
    async function refresh() {
      const data = await api('/api/state');
      const s = data.state || {};
      const cfg = data.config || {};
      document.getElementById('status').innerHTML = [
        ['状态', badge(s.phase, s.autoPrint)],
        ['阶段', esc(s.phase)],
        ['自动打印', s.autoPrint ? '开' : '关'],
        ['当前任务', s.currentJob ? esc(s.currentJob.id) + '（' + s.currentJob.itemCount + ' 项）' : '无'],
        ['列表条数', esc((s.jobPage && s.jobPage.total) || 0)],
        ['最近错误', esc(s.lastError || '无')],
        ['API', esc(cfg.base)],
        ['景区', esc((cfg.scenicIds || []).join(',') || '（服务端授权）')],
      ].map(([k,v]) => '<div class="row"><span class="label">'+k+'</span><span class="value">'+v+'</span></div>').join('');

      const printers = cfg.printers || {};
      const rows = Object.keys(printers).length
        ? Object.entries(printers).map(([k,v]) => '<div class="row"><span class="label">'+esc(k)+'</span><span class="value">'+esc(v)+'</span></div>').join('')
        : '<div class="row"><span class="label">（未配置）</span></div>';
      const fallback = cfg.allowDefaultPrinter
        ? '<div class="row"><span class="label">兜底</span><span class="value">'+esc(cfg.defaultPrinter)+'</span></div>'
        : '<div class="row"><span class="label">兜底</span><span class="value">关闭</span></div>';
      document.getElementById('printers').innerHTML = rows + fallback;

      const hist = data.history || [];
      document.getElementById('history').innerHTML = hist.length
        ? '<table><tr><th>时间</th><th>任务</th><th>结果</th><th>打印机</th><th>原因</th></tr>'
          + hist.map(h => '<tr><td>'+esc(h.at)+'</td><td>'+esc(h.jobId)+'</td><td>'+esc(h.state)
            +'</td><td>'+esc(h.printer)+'</td><td>'+esc(h.reason)+'</td></tr>').join('')
          + '</table>'
        : '<p class="sub">暂无记录</p>';

      const form = document.getElementById('cfgForm');
      form.base.value = cfg.base || '';
      form.token.value = '';
      form.scenicIds.value = (cfg.scenicIds || []).join(',');
      form.timing.value = [cfg.autoPrintMs || 300000, cfg.listRefreshMs || 30000, cfg.resultRetries].join(',');
      form.allowDefaultPrinter.value = String(!!cfg.allowDefaultPrinter);
      form.defaultPrinter.value = cfg.defaultPrinter || '';
      form.printers.value = JSON.stringify(cfg.printers || {}, null, 2);
      form.command.value = JSON.stringify(cfg.command || [], null, 2);
    }
    async function act(path, msgEl) {
      try {
        await api(path, { method: 'POST' });
        showMsg(msgEl, '已执行', false);
        await refresh();
      } catch (e) {
        showMsg(msgEl, e.message, true);
      }
    }
    document.getElementById('btnRefresh').onclick = () => act('/api/refresh', document.getElementById('actionMsg'));
    document.getElementById('btnAutoOn').onclick = () => act('/api/auto-print?on=1', document.getElementById('actionMsg'));
    document.getElementById('btnAutoOff').onclick = () => act('/api/auto-print?on=0', document.getElementById('actionMsg'));
    document.getElementById('btnReload').onclick = () => act('/api/reload', document.getElementById('actionMsg'));
    document.getElementById('cfgForm').onsubmit = async (ev) => {
      ev.preventDefault();
      const form = ev.target;
      const msg = document.getElementById('cfgMsg');
      try {
        const [autoPrintMs, listRefreshMs, resultRetries] = String(form.timing.value || '').split(',').map(s => s.trim());
        const body = {
          base: form.base.value.trim(),
          scenicIds: form.scenicIds.value.split(',').map(s => s.trim()).filter(Boolean),
          autoPrintMs: Number(autoPrintMs || 300000),
          listRefreshMs: Number(listRefreshMs || 30000),
          resultRetries: Number(resultRetries || 5),
          allowDefaultPrinter: /^(1|true|yes)$/i.test(form.allowDefaultPrinter.value.trim()),
          defaultPrinter: form.defaultPrinter.value.trim(),
          printers: JSON.parse(form.printers.value || '{}'),
          command: JSON.parse(form.command.value || '[]'),
        };
        if (form.token.value.trim()) body.token = form.token.value.trim();
        await api('/api/config', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
        showMsg(msg, '已保存并热加载', false);
        await refresh();
      } catch (e) {
        showMsg(msg, e.message, true);
      }
    };
    refresh().catch((e) => { document.getElementById('status').textContent = e.message; });
    setInterval(() => refresh().catch(() => {}), 2000);
  </script>
</body>
</html>`;
}

/**
 * 本机状态/配置 HTTP 服务，默认只绑 127.0.0.1。
 */
function createStatusServer(deps) {
  const getScheduler = () => deps.scheduler;
  const getHistory = () => deps.history;
  const getConfig = () => deps.getConfig();
  const setConfig = deps.setConfig;
  const reloadFromDisk = deps.reloadFromDisk;

  const server = http.createServer(async (request, response) => {
    try {
      const host = getConfig().statusHost || '127.0.0.1';
      const url = new URL(request.url || '/', `http://${host}`);
      const method = request.method || 'GET';

      if (method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
        return sendHtml(response, pageHtml());
      }

      if (method === 'GET' && url.pathname === '/api/state') {
        return sendJson(response, 200, {
          state: getScheduler().getState(),
          config: redactConfig(getConfig()),
          history: getHistory().list(),
        });
      }

      if (method === 'POST' && url.pathname === '/api/refresh') {
        await getScheduler().refreshJobs();
        return sendJson(response, 200, { ok: true });
      }
      if (method === 'POST' && url.pathname === '/api/auto-print') {
        const on = url.searchParams.get('on') === '1';
        getScheduler().setAutoPrint(on);
        return sendJson(response, 200, { ok: true, autoPrint: on });
      }
      if (method === 'POST' && url.pathname === '/api/reload') {
        const next = reloadFromDisk();
        setConfig(next);
        getScheduler().setConfig(next);
        return sendJson(response, 200, { ok: true, config: redactConfig(next) });
      }
      if (method === 'POST' && url.pathname === '/api/config') {
        const body = await readBody(request);
        if (!body || typeof body !== 'object') {
          return sendJson(response, 400, { error: '需要JSON配置体' });
        }
        const current = toWritableConfig(getConfig());
        const merged = {
          ...current,
          ...body,
          token: body.token && String(body.token).trim() ? body.token : current.token,
        };
        const next = normalizeConfig(merged, {
          configPath: getConfig().configPath,
          scriptDir: getConfig().scriptDir,
        });
        saveConfig(next);
        setConfig(next);
        getScheduler().setConfig(next);
        return sendJson(response, 200, { ok: true, config: redactConfig(next) });
      }

      sendJson(response, 404, { error: 'not found' });
    } catch (error) {
      sendJson(response, 500, { error: String(error.message || error).slice(0, 480) });
    }
  });

  function listen() {
    const cfg = getConfig();
    const host = cfg.statusHost || '127.0.0.1';
    if (host !== '127.0.0.1' && host !== 'localhost') {
      throw new Error(`状态页仅允许绑定 127.0.0.1（当前：${host}）`);
    }
    return new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(cfg.statusPort, host, () => {
        server.removeListener('error', reject);
        resolve({ host, port: cfg.statusPort, url: `http://${host}:${cfg.statusPort}/` });
      });
    });
  }

  function close() {
    return new Promise((resolve) => server.close(() => resolve()));
  }

  return { server, listen, close };
}

module.exports = { createStatusServer, pageHtml };
