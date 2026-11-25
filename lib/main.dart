import 'dart:developer' as developer;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'auto_upload/folder_access.dart';
import 'desktop_lifecycle.dart';
import 'diagnostics/crash_journal.dart';
import 'diagnostics/crash_reporting.dart';
import 'printing/print_bridge.dart';
import 'release/desktop_update.dart';
import 'workstation_account.dart';
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
    account: WorkstationAccount.configured(),
  );
  if (Platform.isMacOS) {
    connectMacUpdater(session);
    try {
      if (await FolderAccess().isUnsandboxedMacDistribution()) {
        // The picker otherwise requires sandbox entitlements before opening.
        await FilePicker.skipEntitlementsChecks();
      }
    } catch (error, stackTrace) {
      developer.log(
        'macOS photo picker configuration failed',
        error: error,
        stackTrace: stackTrace,
      );
      session.report('照片选择器初始化失败，请重启工作台后重试。');
    }
  }
  final navigatorKey = GlobalKey<NavigatorState>();
  runApp(PhotoFtpApp(session: session, navigatorKey: navigatorKey));
  try {
    await DesktopLifecycle(session, navigatorKey).initialize();
    journal?.record(CrashEvent.desktopReady);
  } catch (error) {
    journal?.record(CrashEvent.desktopInitFailed);
    session.report('桌面托盘或窗口初始化失败：$error');
  }
}
