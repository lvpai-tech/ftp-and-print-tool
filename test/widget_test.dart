import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/profile_store.dart';
import 'package:lvpai_ftp_client/ui/transfer_page.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const apiBase = String.fromEnvironment(
    'LVPAI_WORKSTATION_API_BASE',
    defaultValue: 'https://hilvpai.com',
  );
  final gateway = Uri.parse(apiBase);
  late Directory support;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    support = await Directory.systemTemp.createTemp('station-ui-');
  });

  tearDown(() async {
    await support.delete(recursive: true);
  });

  Future<void> showUpload(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: TransferPage(supportDirectory: () async => support)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settleStorage(
    WidgetTester tester,
    Future<void> Function() operation,
  ) async {
    await operation();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(1280, 900),
  ]) {
    testWidgets('首次申请入口和手动绑定在 ${size.width}×${size.height} 可用', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'ftp.profile.v1': jsonEncode({'host': 'ftp.invalid'}),
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showUpload(tester);
      expect(find.text('申请机位'), findsOneWidget);

      await tester.tap(find.text('手动绑定机位'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();
      expect(find.text('请填写机位 ID 和有效机位密钥'), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '317');
      await tester.enterText(fields.at(1), 'a' * 64);
      await settleStorage(tester, () => tester.tap(find.text('保存配置')));
      final saved = (await const ProfileStore().loadStations(gateway)).single;
      expect(saved.stationId, '317');
      expect(find.text('机位 317'), findsOneWidget);
      expect(find.text('申请机位'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 75));
      });
    });
  }

  testWidgets('现有机位可查看原收图路径，仍可同时管理其他机位', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'cos.auto.profile.v1': jsonEncode({
        'api': gateway.origin,
        'stationId': '317',
        'token': 'a' * 64,
        'stationCode': 'A17',
      }),
      'ftp.watch.v1': jsonEncode({'folder': 'test-inbox', 'recursive': true}),
    });
    await showUpload(tester);
    expect(find.text('A17'), findsOneWidget);
    await tester.tap(find.text('A17'));
    await tester.pumpAndSettle();
    expect(find.text('test-inbox'), findsOneWidget);
    expect(find.text('切换到托管目录'), findsOneWidget);
    expect(find.text('恢复旧目录监听'), findsOneWidget);
    await tester.tap(find.text('更新机位密钥'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).readOnly, isTrue);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, '317');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回机位列表'));
    await tester.pumpAndSettle();
    expect(find.text('申请机位'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 75));
    });
  });

  testWidgets('另一个服务的机位凭据和目录不会进入当前列表', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'cos.auto.profile.v1': jsonEncode({
        'api': 'https://old-upload.example',
        'stationId': '317',
        'token': 'a' * 64,
      }),
    });
    await showUpload(tester);
    expect(find.text('申请机位'), findsOneWidget);
    expect(find.text('机位 317'), findsNothing);
    await tester.tap(find.text('手动绑定机位'));
    await tester.pumpAndSettle();
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.controller?.text, isEmpty);
    }
  });
}
