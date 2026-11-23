import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/app.dart';
import 'package:lvpai_ftp_client/profile_store.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const apiBase = String.fromEnvironment(
    'LVPAI_WORKSTATION_API_BASE',
    defaultValue: 'https://hilvpai.com',
  );

  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('仅使用 COS 直传，旧 FTP 档案不影响 $width 宽度配置', (tester) async {
      const folderAccess = MethodChannel('ai.lvpai.ftp/folder-access');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(folderAccess, (call) async {
        return switch (call.method) {
          'restore' => 'authorized-inbox',
          'release' => null,
          _ => throw MissingPluginException(call.method),
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(folderAccess, null));
      FlutterSecureStorage.setMockInitialValues({
        'ftp.profile.v1': jsonEncode({'host': 'ftp.invalid'}),
        'ftp.watch.v1': jsonEncode({'folder': 'test-inbox', 'recursive': true}),
      });
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const PhotoFtpApp());
      await tester.pumpAndSettle();

      expect(find.text('请先配置机位连接'), findsOneWidget);
      expect(find.text('手动上传模式'), findsNothing);
      expect(find.text('开始监听'), findsNothing);

      await tester.tap(find.text('去配置机位'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();
      expect(find.text('请填写机位 ID 和有效机位密钥'), findsOneWidget);

      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.at(0), '317');
      await tester.enterText(fields.at(1), 'a' * 64);
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();

      expect(find.text('COS 直传设置'), findsOneWidget);
      expect(find.text('开始监听'), findsOneWidget);
      final folder = Platform.isMacOS ? 'authorized-inbox' : 'test-inbox';
      expect(find.text(folder), findsOneWidget);
      final saved = await const ProfileStore().loadCos();
      expect(saved?.api.origin, Uri.parse(apiBase).origin);
      expect(saved?.stationId, '317');

      await tester.tap(find.text('COS 直传设置'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(fields.at(0)).controller?.text, '317');
      expect(find.text('切回 FTP'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('旧版同服务机位配置可直接开始监听', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'cos.auto.profile.v1': jsonEncode({
        'api': apiBase,
        'stationId': '317',
        'token': 'a' * 64,
      }),
    });

    await tester.pumpWidget(const PhotoFtpApp());
    await tester.pumpAndSettle();

    expect(find.text('去配置机位'), findsNothing);
    expect(find.text('开始监听'), findsOneWidget);
  });

  testWidgets('旧版其他服务的机位配置不会用于当前服务', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'cos.auto.profile.v1': jsonEncode({
        'api': 'https://old-upload.example',
        'stationId': '317',
        'token': 'a' * 64,
      }),
    });

    await tester.pumpWidget(const PhotoFtpApp());
    await tester.pumpAndSettle();

    expect(find.text('已保存的机位配置属于其他服务，请填写当前服务的机位凭据'), findsOneWidget);
    expect(find.text('开始监听'), findsNothing);
    await tester.tap(find.text('去配置机位'));
    await tester.pumpAndSettle();
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.controller?.text, isEmpty);
    }
  });
}
