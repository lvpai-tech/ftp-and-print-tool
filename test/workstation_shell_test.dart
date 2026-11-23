import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/app.dart';
import 'package:lvpai_ftp_client/desktop_lifecycle.dart';
import 'package:lvpai_ftp_client/ui/transfer_page.dart';
import 'package:lvpai_ftp_client/workstation_session.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tray_manager/tray_manager.dart';

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
      expect(find.text('帧集快拍'), findsOneWidget);
      expect(find.text('一分钟拍大片'), findsOneWidget);
      final background = find.image(
        const AssetImage('assets/branding/workstation-scenic.webp'),
      );
      expect(tester.getRect(background), Offset.zero & Size(width, 900));
      expect(tester.widget<Text>(keyed('status-upload')).data, '机位待配置');
      expect(tester.widget<Text>(keyed('status-print')).data, '自动打印已关闭');
      expect(keyed('open-upload'), findsOneWidget);
      expect(keyed('open-print'), findsOneWidget);
      await open(tester, 'open-upload');
      expect(find.byType(TransferPage), findsOneWidget);
      expect(find.text('申请机位'), findsOneWidget);
      final transferState = tester.state(find.byType(TransferPage));
      await tester.tap(find.byTooltip('返回工作台'));
      await tester.pumpAndSettle();
      await open(tester, 'open-print');
      expect(find.text('#9007199254740993'), findsOneWidget);
      await open(tester, 'print-settings-button');
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

  for (final size in [const Size(375, 800), const Size(1000, 680)]) {
    testWidgets('打印设置在 ${size.width} 宽可校验和保存 DPI', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = WorkstationBridge();
      await tester.pumpWidget(PhotoFtpApp(session: WorkstationSession(bridge)));
      await tester.pumpAndSettle();
      await open(tester, 'open-print');
      await open(tester, 'print-settings-button');
      final field = keyed('print-dpi-field');
      final save = find.text('保存打印设置');
      await tester.ensureVisible(field);
      expect(tester.widget<TextFormField>(field).controller!.text, '300');
      await tester.enterText(field, '300.5');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('请输入 72–1200 之间的整数'), findsOneWidget);
      expect(bridge.calls, isNot(contains('saveConfig')));
      await tester.ensureVisible(field);
      await tester.enterText(field, '360');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(bridge.arguments['saveConfig'], [
        {
          'printers': {'COVER': WorkstationBridge.printer},
          'printDpi': 360,
        },
      ]);
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
    expect(find.text('申请机位'), findsOneWidget);

    session.setTransferActive(true);
    session.setTransferUploading(true);
    bridge.setPrinting(true);
    await tester.pump();
    await tester.tap(find.byTooltip('返回工作台'));
    await tester.pump();
    expect(tester.widget<Text>(keyed('status-upload')).data, '上传中');
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
    expect(tester.widget<Text>(keyed('status-upload')).data, '上传中');
    expect(tester.widget<Text>(keyed('status-print')).data, '自动打印已关闭');
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

  testWidgets('托盘退出受阻时唤起窗口，只弹一次，任务完成后可以重试', (tester) async {
    final nativeCalls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    const trayChannel = MethodChannel('tray_manager');
    var minimized = true;
    var trayDestroyFails = true;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      nativeCalls.add('window:${call.method}');
      if (call.method == 'isMinimized') return minimized;
      if (call.method == 'restore') minimized = false;
      return null;
    });
    messenger.setMockMethodCallHandler(trayChannel, (call) async {
      nativeCalls.add('tray:${call.method}');
      if (call.method == 'destroy' && trayDestroyFails) {
        throw PlatformException(code: 'test', message: '托盘暂时无法关闭');
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(trayChannel, null);
    });

    final bridge = WorkstationBridge();
    final session = WorkstationSession(bridge);
    final navigatorKey = GlobalKey<NavigatorState>();
    final lifecycle = DesktopLifecycle(session, navigatorKey);
    final exit = MenuItem(key: 'exit', label: '退出客户端');
    await tester.pumpWidget(
      PhotoFtpApp(session: session, navigatorKey: navigatorKey),
    );
    await tester.pumpAndSettle();

    session.setTransferActive(true);
    final blocked = lifecycle.onTrayMenuItemClick(exit);
    await tester.pumpAndSettle();
    expect(nativeCalls, [
      'window:isMinimized',
      'window:restore',
      'window:show',
      'window:focus',
    ]);
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(find.text('当前无法退出'), findsOneWidget);
    expect(find.textContaining('等当前任务完成后再退出'), findsOneWidget);
    expect(find.byType(MaterialBanner), findsNothing);

    // 即使任务在弹窗打开时完成，也需要等用户关闭提示后再发起退出。
    session.setTransferActive(false);
    await lifecycle.onTrayMenuItemClick(exit);
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    expect(bridge.calls, isNot(contains('shutdown')));
    expect(nativeCalls, isNot(contains('window:destroy')));

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await blocked;
    expect(dialog, findsNothing);

    final failed = lifecycle.onTrayMenuItemClick(exit);
    await tester.pumpAndSettle();
    expect(find.text('退出失败'), findsOneWidget);
    expect(find.textContaining('托盘暂时无法关闭'), findsOneWidget);
    expect(nativeCalls, isNot(contains('window:destroy')));
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await failed;

    trayDestroyFails = false;
    await lifecycle.onTrayMenuItemClick(exit);
    expect(bridge.calls, contains('shutdown'));
    expect(nativeCalls.sublist(nativeCalls.length - 2), [
      'tray:destroy',
      'window:destroy',
    ]);
  });

  testWidgets('Windows 首页卸载入口在检查更新旁，确认后打开程序文件夹', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const launchChannel = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <Uri>[];
    var launchSucceeds = true;
    messenger.setMockMethodCallHandler(launchChannel, (call) async {
      expectSync(call.method, 'launch');
      launched.add(Uri.parse(call.arguments['url'] as String));
      return launchSucceeds;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(launchChannel, null);
    });

    final bridge = WorkstationBridge();
    final session = WorkstationSession(bridge)..setTransferActive(true);
    await tester.pumpWidget(PhotoFtpApp(session: session));
    await tester.pumpAndSettle();

    final uninstall = find.text('卸载客户端…');
    final update = find.text('检查更新');
    expect(uninstall, findsOneWidget);
    expect(tester.getCenter(uninstall).dy, tester.getCenter(update).dy);
    expect(
      tester.getCenter(uninstall).dx,
      greaterThan(tester.getCenter(update).dx),
    );
    await tester.tap(uninstall);
    await tester.pumpAndSettle();
    expect(find.text('卸载客户端'), findsOneWidget);
    expect(find.textContaining('请保留收图文件夹和照片'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(launched, isEmpty);

    await tester.tap(uninstall);
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开程序文件夹'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final folder = File(Platform.resolvedExecutable).parent.path;
    expect(launched.map((uri) => uri.toFilePath()), [folder]);

    launchSucceeds = false;
    await tester.tap(uninstall);
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开程序文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('无法打开程序文件夹'), findsOneWidget);
    expect(find.textContaining(folder), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(session.transferActive, isTrue);
    expect(bridge.calls, isNot(contains('shutdown')));
    await open(tester, 'open-upload');
    expect(uninstall, findsNothing);
  }, skip: !Platform.isWindows);

  testWidgets('打印不可用时，上传仍能打开机位配置', (tester) async {
    final bridge = ControlledBridge()
      ..connected = false
      ..error = '隔离测试内核故障';
    await tester.pumpWidget(PhotoFtpApp(session: WorkstationSession(bridge)));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(keyed('status-print')).data, '暂不可用');
    await open(tester, 'open-upload');
    await tester.tap(find.text('手动绑定机位'));
    await tester.pumpAndSettle();
    expect(find.text('COS 自动直传'), findsOneWidget);
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(find.text('请填写机位 ID 和有效机位密钥'), findsOneWidget);
  });
}
