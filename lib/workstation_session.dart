import 'dart:async';

import 'package:flutter/foundation.dart';

import 'diagnostics/crash_journal.dart';
import 'printing/print_bridge.dart';
import 'workstation_account.dart';

/// 统一工作台退出门禁；导航切换不停止上传或打印。
class WorkstationSession extends ChangeNotifier {
  WorkstationSession(
    this.printBridge, {
    this.crashJournal,
    this.checkUploadStorage,
    this.account,
  });
  final WorkstationAccount? account;
  WorkstationIdentity? identity;
  WorkstationScenic? scenic;
  bool closingWorkspace = false;
  bool workspaceLocked = false;
  List<String> activeStations = const [];
  final PrintBridge printBridge;
  final CrashJournal? crashJournal;
  final Future<void> Function()? checkUploadStorage;
  bool transferActive = false;
  bool transferUploading = false;
  bool? transferConfigured;
  String? transferIssue;
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

  void setTransferIssue(String? issue) {
    if (transferIssue == issue) return;
    transferIssue = issue;
    notifyListeners();
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }

  bool canExit() => !closingWorkspace && !transferActive && !printBridge.busy;

  List<String> get signOutBlockers => [
    if (transferActive || transferUploading || activeStations.isNotEmpty)
      activeStations.isEmpty
          ? '请停止所有机位的收图监听并等待上传结束。'
          : '请停止以下机位的收图监听并等待上传结束：${activeStations.join('、')}',
    if (printBridge.state['autoPrint'] == true) '请关闭自动打印。',
    if (printBridge.busy) '请等待当前打印操作结束。',
    if (printBridge.starting || updating || transferConfigured == null)
      '工作台正在初始化或更新，请稍后重试。',
  ];

  String? get personnelToken =>
      closingWorkspace || workspaceLocked ? null : account?.token;

  Future<void> startPrinting() {
    if (closingWorkspace ||
        (account != null && (scenic == null || account!.token == null))) {
      return Future.value();
    }
    return printBridge.start(
      personnelToken: account?.token,
      personnelOrigin: account?.origin,
      scenicId: scenic?.id,
    );
  }

  Future<void> closeWorkspace() async {
    closingWorkspace = true;
    workspaceLocked = true;
    notifyListeners();
    try {
      await printBridge.blockNewWork();
      await updateUploads?.call(true);
      await printBridge.waitUntilIdle();
      await printBridge.shutdown();
      transferActive = transferUploading = false;
      transferConfigured = null;
      transferIssue = null;
      activeStations = const [];
      notice = null;
      scenic = null;
    } finally {
      closingWorkspace = false;
      notifyListeners();
    }
  }

  Future<void> resumeWorkspace() async {
    if (printBridge.connected) await printBridge.call('resumePersonnel');
    await startPrinting();
    workspaceLocked = false;
    try {
      await updateUploads?.call(false);
    } catch (_) {
      workspaceLocked = true;
      await printBridge.blockNewWork();
      rethrow;
    }
  }

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
      if (restartPrinting) await startPrinting();
      await updateUploads?.call(false);
    } finally {
      updating = false;
      clearNotice();
    }
  }
}
