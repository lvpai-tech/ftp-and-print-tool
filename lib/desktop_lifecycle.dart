import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'branding.dart';
import 'ui/app_dialogs.dart';
import 'workstation_session.dart';

enum _ExitPhase { idle, shuttingDown, showingNotice }

/// 一个托盘管理整个客户端；上传/监听/打印期间不能直接退出。
class DesktopLifecycle with WindowListener, TrayListener {
  DesktopLifecycle(this.session, this.navigatorKey);
  final WorkstationSession session;
  final GlobalKey<NavigatorState> navigatorKey;
  _ExitPhase _exitPhase = _ExitPhase.idle;

  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1440, 900),
        minimumSize: Size(820, 600),
        title: workstationTitle,
        center: true,
      ),
      _showWindow,
    );
    windowManager.addListener(this);
    trayManager.addListener(this);
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/printing/tray.ico'
          : 'assets/printing/tray.png',
      isTemplate: !Platform.isWindows,
    );
    await trayManager.setToolTip(workstationTitle);
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: '打开上传与打印工作台'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: '退出客户端'),
        ],
      ),
    );
    await windowManager.setPreventClose(true);
  }

  @override
  void onWindowClose() {
    windowManager.hide();
  }

  @override
  Future<void> onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show') {
      await _showWindow();
      return;
    }
    if (menuItem.key != 'exit') return;
    if (session.updating) {
      await _showWindow();
      return;
    }
    if (_exitPhase == _ExitPhase.showingNotice) {
      await _showWindow();
      return;
    }
    if (_exitPhase == _ExitPhase.shuttingDown) return;

    try {
      if (!session.canExit()) {
        await _showExitNotice(
          title: '当前无法退出',
          message: '照片监听、上传或打印仍在进行。请停止监听，等当前任务完成后再退出。',
        );
        return;
      }
      _exitPhase = _ExitPhase.shuttingDown;
      try {
        await session.printBridge.shutdown();
        await trayManager.destroy();
        await windowManager.destroy();
      } catch (error) {
        await _showExitNotice(
          title: '退出失败',
          message: '请核对当前任务后重试。\n${appErrorMessage(error)}',
        );
      }
    } finally {
      _exitPhase = _ExitPhase.idle;
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _showExitNotice({
    required String title,
    required String message,
  }) async {
    _exitPhase = _ExitPhase.showingNotice;
    await _showWindow();
    final context = navigatorKey.currentContext;
    if (context != null && context.mounted) {
      await showAppMessage(context, title: title, message: message);
    }
  }
}
