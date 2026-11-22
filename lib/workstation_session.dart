import 'package:flutter/foundation.dart';
import 'printing/print_bridge.dart';

/// 统一工作台退出门禁；导航切换不停止上传或打印。
class WorkstationSession extends ChangeNotifier {
  WorkstationSession(this.printBridge);
  final PrintBridge printBridge;
  bool transferActive = false;
  bool transferUploading = false;
  bool? transferConfigured;
  String? notice;

  void setTransferActive(bool active) {
    if (transferActive == active) return;
    transferActive = active;
    notifyListeners();
  }

  void report(String message) {
    notice = message;
    notifyListeners();
  }

  void setTransferUploading(bool active) {
    if (transferUploading == active) return;
    transferUploading = active;
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
}
