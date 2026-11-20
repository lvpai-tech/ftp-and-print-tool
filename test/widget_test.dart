import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lvpai_ftp_client/app.dart';

void main() {
  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('未配置引导与抽屉表单在 $width 宽度可布局，空主机拒绝连接', (
      tester,
    ) async {
      // 只隔离布局测试的操作系统存储，真实 FTP 另有独立集成测试。
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const PhotoFtpApp());
      await tester.pumpAndSettle();

      expect(find.text('机位尚未配置'), findsOneWidget);
      expect(find.text('请先配置机位连接'), findsOneWidget);
      expect(find.text('自动上传模式'), findsOneWidget);
      expect(find.text('手动上传模式'), findsOneWidget);
      expect(find.text('请先配置机位连接'), findsOneWidget);

      final openConfig = find.text('机位连接 · 未配置').evaluate().isNotEmpty
          ? find.text('机位连接 · 未配置')
          : find.text('未配置');
      await tester.tap(openConfig);
      await tester.pumpAndSettle();
      expect(find.text('测试连接'), findsOneWidget);
      expect(find.text('保存配置'), findsOneWidget);

      await tester.ensureVisible(find.text('测试连接'));
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      expect(find.text('请填写主机'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
