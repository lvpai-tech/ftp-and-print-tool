import 'dart:async';

import 'package:flutter/foundation.dart';

import 'diagnostics/crash_journal.dart';
import 'printing/print_bridge.dart';

/// 统一工作台退出门禁；导航切换不停止上传或打印。
class WorkstationSession extends ChangeNotifier {
  WorkstationSession(this.printBridge, {this.crashJournal});
  final PrintBridge printBridge;
  final CrashJournal? crashJournal;
  bool transferActive = false;
  bool transferUploading = false;
  bool? transferConfigured;
  String? notice;
  bool updating = false;
  Future<void> Function(bool paused)? updateUploads;

  void setTransferActive(bool active) {
    if (transferActive == active) return;
    transferActive = active;
    crashJournal?.record(
      active ? CrashEvent.uploadListening : CrashEvent.uploadStopped,
    );
    notifyListeners();
  }

  void report(String message) {
    notice = message;
    notifyListeners();
  }

  void setTransferUploading(bool active) {
    if (transferUploading == active) return;
    transferUploading = active;
    crashJournal?.record(
      active ? CrashEvent.uploadStarted : CrashEvent.uploadIdle,
    );
    notifyListeners();
  }

  void setTransferConfigured(bool configured) {
    if (transferConfigured == configured) return;
    transferConfigured = configured;
    notifyListeners();
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }

  bool canExit() => !transferActive && !printBridge.busy;

  Future<void> prepareForUpdate() async {
    if (updating) throw StateError('正在准备更新');
    final pause = updateUploads;
    if (pause == null) throw StateError('工作台尚未初始化，请稍后重试');
    updating = true;
    report('正在等当前上传和打印结束，完成后会安装并重启工作台。');
    try {
      await pause(true);
      final idle = Completer<void>();
      void check() {
        if (!printBridge.busy && !idle.isCompleted) idle.complete();
      }

      printBridge.addListener(check);
      try {
        check();
        await idle.future.timeout(
          const Duration(minutes: 20),
          onTimeout: () => throw StateError('打印尚未结束，请稍后重试更新'),
        );
      } finally {
        printBridge.removeListener(check);
      }
      await printBridge.shutdown();
    } catch (_) {
      await recoverAfterUpdateFailure();
      rethrow;
    }
  }

  Future<void> recoverAfterUpdateFailure({bool restartPrinting = false}) async {
    try {
      if (restartPrinting) await printBridge.start();
      await updateUploads?.call(false);
    } finally {
      updating = false;
      clearNotice();
    }
  }
}
