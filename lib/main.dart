import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'desktop_lifecycle.dart';
import 'diagnostics/crash_journal.dart';
import 'diagnostics/crash_reporting.dart';
import 'printing/print_bridge.dart';
import 'release/desktop_update.dart';
import 'workstation_session.dart';
import 'workstation_storage.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows && !Platform.isMacOS) {
    runApp(const PhotoFtpApp());
    return;
  }
  final bridge = PrintBridge();
  final journal = await startCrashReporting(
    compatibility: args.contains('--graphics-compatibility'),
    bridge: bridge,
  );
  final session = WorkstationSession(
    bridge,
    crashJournal: journal,
    checkUploadStorage: Platform.isMacOS ? checkMacUploadStorage : null,
  );
  if (Platform.isMacOS) connectMacUpdater(session);
  final navigatorKey = GlobalKey<NavigatorState>();
  runApp(PhotoFtpApp(session: session, navigatorKey: navigatorKey));
  try {
    await DesktopLifecycle(session, navigatorKey).initialize();
    journal?.record(CrashEvent.desktopReady);
  } catch (error) {
    journal?.record(CrashEvent.desktopInitFailed);
    session.report('桌面托盘或窗口初始化失败：$error');
  }
  // 打印内核失败只在打印页面显式报错，不阻塞原有 FTP 工作。
  await bridge.start();
}
