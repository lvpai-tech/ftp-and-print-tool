'use strict';

/**
 * CLI 入口（无 Electron）：常驻控制台 + 可选本机状态页。
 * 客户向客户端请用：npm run desktop
 */
const { spawn } = require('node:child_process');
const { createRuntime } = require('./runtime');
const { createStatusServer } = require('./status-server');
const { resolveConfigPath } = require('./config');

function openBrowser(url) {
  if (process.platform === 'win32') {
    spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
    return;
  }
  if (process.platform === 'darwin') {
    spawn('open', [url], { detached: true, stdio: 'ignore' }).unref();
    return;
  }
  spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref();
}

function notifyWindows(title, body) {
  if (process.platform !== 'win32') return;
  const safeTitle = String(title).replace(/'/g, "''").slice(0, 80);
  const safeBody = String(body).replace(/'/g, "''").slice(0, 180);
  const script = `
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$template = '<toast><visual><binding template="ToastGeneric"><text>${safeTitle}</text><text>${safeBody}</text></binding></visual></toast>'
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml($template)
$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('旅派打印代理').Show($toast)
`;
  try {
    spawn(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
      { windowsHide: true, stdio: 'ignore', detached: true },
    ).unref();
  } catch {
    /* 通知失败不影响主流程 */
  }
}

async function main() {
  const args = process.argv.slice(2);
  const configPathArg = (() => {
    const idx = args.indexOf('--config');
    return idx >= 0 ? args[idx + 1] : undefined;
  })();
  const skipLock = args.includes('--no-lock');
  const noBrowser = args.includes('--no-browser');
  const noHttp = args.includes('--no-http');
  const bridge = await createRuntime({
    configPath: configPathArg,
    skipLock,
    onLog: (msg) => console.log(msg),
    notify: notifyWindows,
  });

  if (!noHttp) {
    const status = createStatusServer({
      scheduler: bridge.scheduler,
      history: bridge.history,
      getConfig: () => bridge.runtime.getConfig(),
      setConfig: (next) => bridge.runtime.setConfig(next),
      reloadFromDisk: () =>
        require('./config').loadConfig({
          configPath: bridge.runtime.getConfig().configPath || resolveConfigPath(configPathArg),
        }),
    });
    const listened = await status.listen();
    console.log(`[${new Date().toISOString()}] 状态页 ${listened.url}`);
    if (bridge.runtime.getConfig().openStatusOnStart && !noBrowser) {
      openBrowser(listened.url);
    }
  }

  bridge.start();
  console.log('打印代理已启动。客户向 UI：npm run desktop');
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = { main, openBrowser, notifyWindows };
