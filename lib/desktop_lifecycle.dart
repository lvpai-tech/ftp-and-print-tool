import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'workstation_session.dart';

/// 一个托盘管理整个客户端；上传/监听/打印期间不能直接退出。
class DesktopLifecycle with WindowListener, TrayListener {
  DesktopLifecycle(this.session);
  final WorkstationSession session;

  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1440, 900),
        minimumSize: Size(820, 600),
        title: '帧集 · 上传与打印工作台',
        center: true,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    windowManager.addListener(this);
    trayManager.addListener(this);
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/printing/tray.ico'
          : 'assets/printing/tray.png',
      isTemplate: !Platform.isWindows,
    );
    await trayManager.setToolTip('帧集 · 上传与打印工作台');
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
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show') {
      onTrayIconMouseDown();
      return;
    }
    if (menuItem.key == 'exit') {
      if (!session.canExit()) {
        onTrayIconMouseDown();
        return;
      }
      try {
        await session.printBridge.shutdown();
        await trayManager.destroy();
        await windowManager.destroy();
      } catch (error) {
        session.report('退出失败，请核对当前任务后重试：$error');
        onTrayIconMouseDown();
      }
    }
  }
}
