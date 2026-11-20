import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'desktop_lifecycle.dart';
import 'printing/print_bridge.dart';
import 'workstation_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows && !Platform.isMacOS) {
    runApp(const PhotoFtpApp());
    return;
  }
  final bridge = PrintBridge();
  final session = WorkstationSession(bridge);
  runApp(PhotoFtpApp(session: session));
  try {
    await DesktopLifecycle(session).initialize();
  } catch (error) {
    session.report('桌面托盘或窗口初始化失败：$error');
  }
  // 打印内核失败只在打印页面显式报错，不阻塞原有 FTP 工作。
  await bridge.start();
}
