import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/app.dart';
import 'package:lvpai_ftp_client/profile_store.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('仅使用 COS 直传，旧 FTP 档案不影响 $width 宽度配置', (tester) async {
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
      expect(find.text('请填写 HTTPS 服务地址、机位 ID 和有效机位密钥'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'https://hilvpai.com');
      await tester.enterText(fields.at(1), '317');
      await tester.enterText(fields.at(2), 'a' * 64);
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();

      expect(find.text('COS 直传设置'), findsOneWidget);
      expect(find.text('开始监听'), findsOneWidget);
      expect(find.text('test-inbox'), findsOneWidget);
      final saved = await const ProfileStore().loadCos();
      expect(saved?.stationId, '317');

      await tester.tap(find.text('COS 直传设置'));
      await tester.pumpAndSettle();
      expect(find.text('切回 FTP'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
