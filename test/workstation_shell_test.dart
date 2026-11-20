import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/app.dart';
import 'package:lvpai_ftp_client/ui/transfer_page.dart';
import 'package:lvpai_ftp_client/workstation_session.dart';
import 'package:material_ui/material_ui.dart';

import 'printing_workstation_test.dart' show ControlledBridge;

Finder keyed(String key) => find.byKey(ValueKey(key));

Future<void> open(WidgetTester tester, String key) async {
  await tester.ensureVisible(keyed(key));
  await tester.tap(keyed(key));
  // 避免无尽动画导致 pumpAndSettle 超时（打印页/状态刷新可能持续重建）。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

class WorkstationBridge extends ControlledBridge {
  static const printer = '隔离测试打印机';
  static const alternatePrinter = '备用测试打印机';

  WorkstationBridge() {
    snapshot['config']['printers'] = {'COVER': printer};
  }

  void setPrinting(bool printing) {
    snapshot['state'] = {...state, 'printBusy': printing};
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    if (method == 'listPrinters') {
      calls.add(method);
      return [printer, alternatePrinter];
    }
    if (method == 'printerStatus') {
      calls.add(method);
      expect(args, [printer]);
      return {'printerStatus': 'Normal', 'jobs': []};
    }
    return super.call(method, args);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final width in [420.0, 820.0, 1280.0, 1600.0]) {
    testWidgets('工作台 ${width.toInt()}：首页进出并保留上传页', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = WorkstationBridge();
      await tester.pumpWidget(PhotoFtpApp(session: WorkstationSession(bridge)));
      await tester.pumpAndSettle();

      expect(find.text('照片工作台'), findsOneWidget);
      expect(keyed('open-upload'), findsOneWidget);
      expect(keyed('open-print'), findsOneWidget);
      await open(tester, 'open-upload');
      expect(find.byType(TransferPage), findsOneWidget);
      expect(find.text('自动上传模式'), findsOneWidget);
      final transferState = tester.state(find.byType(TransferPage));
      await tester.tap(find.byTooltip('返回工作台'));
      await tester.pumpAndSettle();
      await open(tester, 'open-print');
      expect(find.text('#9007199254740993'), findsOneWidget);
      await open(tester, 'print-open-config');
      await tester.tap(keyed('print-inspect-printers'));
      await tester.pumpAndSettle();
      expect(find.text('隔离测试打印机：正常（0 项任务）'), findsOneWidget);
      expect(bridge.calls, contains('printerStatus'));
      expect(bridge.calls, isNot(contains('printJobs')));
      expect(bridge.calls, isNot(contains('autoPrint')));
      await tester.tap(find.byTooltip('返回工作台'));
      await tester.pumpAndSettle();
      await open(tester, 'open-upload');
      expect(tester.state(find.byType(TransferPage)), same(transferState));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('窄窗打印机下拉可浏览、选择与键盘关闭', (tester) async {
    tester.view.physicalSize = const Size(420, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = WorkstationBridge();
    await tester.pumpWidget(PhotoFtpApp(session: WorkstationSession(bridge)));
    await tester.pumpAndSettle();
    await open(tester, 'open-print');
    await open(tester, 'print-open-config');
    final field = find.byType(DropdownMenu<String>).first;
    final arrow = find.descendant(
      of: field,
      matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
    );
    await tester.ensureVisible(arrow);
    await tester.tap(arrow);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsWidgets);
    expect(
      find.text(WorkstationBridge.alternatePrinter).hitTestable(),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.text(WorkstationBridge.alternatePrinter).hitTestable(),
      findsNothing,
    );
    await tester.tap(arrow);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(WorkstationBridge.alternatePrinter).hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: field,
        matching: find.text(WorkstationBridge.alternatePrinter),
      ),
      findsOneWidget,
    );
    expect(bridge.calls, isNot(contains('saveConfig')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('两项任务可以同时显示运行并各自更新', (tester) async {
    final bridge = WorkstationBridge();
    final session = WorkstationSession(bridge);
    await tester.pumpWidget(PhotoFtpApp(session: session));
    await tester.pumpAndSettle();
    await open(tester, 'open-upload');
    expect(find.text('请先配置机位连接'), findsOneWidget);

    session.setTransferActive(true);
    session.setTransferUploading(true);
    bridge.setPrinting(true);
    await tester.pump();
    await tester.tap(find.byTooltip('返回工作台'));
    await tester.pump();
    expect(tester.widget<Text>(keyed('status-upload')).data, '上传任务正在运行');
    expect(tester.widget<Text>(keyed('status-print')).data, '打印中');
    await tester.ensureVisible(keyed('open-print'));
    await tester.tap(keyed('open-print'));
    await tester.pump();
    expect(find.text('#9007199254740993'), findsOneWidget);
    await tester.tap(find.byTooltip('返回工作台'));
    await tester.pump();
    await open(tester, 'open-upload');
    expect(find.byType(TransferPage), findsOneWidget);

    bridge.setPrinting(false);
    await tester.pump();
    await tester.tap(find.byTooltip('返回工作台'));
    await tester.pump();
    expect(tester.widget<Text>(keyed('status-upload')).data, '上传任务正在运行');
    expect(tester.widget<Text>(keyed('status-print')).data, '未运行');
  });

  test('退出检查分别保护上传与打印', () {
    final bridge = ControlledBridge();
    final session = WorkstationSession(bridge);
    expect(session.canExit(), true);
    session.setTransferActive(true);
    expect(session.canExit(), false);
    session.setTransferActive(false);
    bridge.working = true;
    expect(session.canExit(), false);
    bridge.working = false;
    expect(session.canExit(), true);
  });

  testWidgets('打印不可用时，上传仍能打开机位配置', (tester) async {
    final bridge = ControlledBridge()
      ..connected = false
      ..error = '隔离测试内核故障';
    await tester.pumpWidget(PhotoFtpApp(session: WorkstationSession(bridge)));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(keyed('status-print')).data, '暂不可用');
    await open(tester, 'open-upload');
    await tester.tap(find.text('去配置机位'));
    await tester.pumpAndSettle();
    expect(find.text('测试连接'), findsOneWidget);
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请填写主机'), findsOneWidget);
  });
}
