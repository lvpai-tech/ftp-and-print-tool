import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/printing/print_bridge.dart';
import 'package:lvpai_ftp_client/workstation_session.dart';

class _PrintBridge extends PrintBridge {
  bool stopped = false;
  bool failShutdown = false;

  void finishPrinting() {
    snapshot = {};
    notifyListeners();
  }

  @override
  Future<void> shutdown() async {
    if (failShutdown) throw StateError('cannot shut down');
    expect(busy, isFalse);
    stopped = true;
  }
}

void main() {
  test('更新等待收图队列关闭及当前打印完成，禁止重复准备', () async {
    final bridge = _PrintBridge()
      ..snapshot = {
        'state': {'printBusy': true},
      };
    final session = WorkstationSession(bridge);
    final paused = Completer<void>();
    session.updateUploads = (_) => paused.future;

    final ready = session.prepareForUpdate();
    expect(session.updating, isTrue);
    expect(bridge.stopped, isFalse);
    await expectLater(session.prepareForUpdate(), throwsStateError);
    paused.complete();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.stopped, isFalse);
    bridge.finishPrinting();
    await ready;
    expect(bridge.stopped, isTrue);
  });

  test('关闭打印内核失败后恢复监听并可重试', () async {
    final bridge = _PrintBridge()..failShutdown = true;
    final session = WorkstationSession(bridge);
    final transitions = <bool>[];
    session.updateUploads = (paused) async => transitions.add(paused);

    await expectLater(session.prepareForUpdate(), throwsStateError);
    expect(transitions, [true, false]);
    expect(session.updating, isFalse);
    bridge.failShutdown = false;
    await session.prepareForUpdate();
    expect(bridge.stopped, isTrue);
  });
}
