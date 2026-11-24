import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lvpai_ftp_client/ui/card_tail_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zxing_lib/oned.dart';
import 'package:zxing_lib/zxing.dart';

void main() {
  testWidgets('窄窗可框选和整图扫条码，识别结果可用于归集', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 610));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const code = 'TEST00002522';
    final matrix = Code128Writer().encode(
      code,
      BarcodeFormat.code128,
      760,
      160,
    );
    final image = img.Image(width: 800, height: 300);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        if (matrix.get(x, y)) image.setPixelRgb(x + 20, y + 110, 0, 0, 0);
      }
    }
    final bytes = img.encodePng(image);
    CardCodeChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showCardTailDialog(
                  context,
                  readPhoto: () async => bytes,
                  guidance: '测试识别',
                  allowUse: true,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(finder, findsOneWidget);
    }

    await tester.runAsync(() async {
      await tester.tap(find.text('打开'));
      await tester.pump();
    });
    final preview = find.byKey(const ValueKey('card-tail-image'));
    await waitFor(preview);
    await tester.pumpAndSettle();
    final bounds = tester.getRect(preview);
    final drag = await tester.startGesture(
      bounds.topLeft + const Offset(20, 10),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(150, 28));
    await drag.up();
    await tester.pump();
    expect(find.text('已框选识别区域'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '识别尾号'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('清除选框'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('整图识别'));
      await tester.pump();
    });
    expect(find.text('正在识别取片码'), findsOneWidget);
    expect(find.text('正在同时读取条形码和六位尾号'), findsOneWidget);
    final scanProgress = find.byKey(const ValueKey('card-tail-scan-progress'));
    expect(scanProgress, findsOneWidget);
    expect(tester.getRect(preview), bounds);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '整图识别'))
          .onPressed,
      isNull,
    );
    await waitFor(find.textContaining('已识别条形码'));
    expect(scanProgress, findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.text('核对后用于补录'));
      await tester.pump();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(result, (code: code, barcode: code));
    expect(tester.takeException(), isNull);
  });

  testWidgets('照片读取失败时不提供设置取片码操作', (tester) async {
    final photo = Completer<Uint8List>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCardTailDialog(
                context,
                readPhoto: () => photo.future,
                guidance: '',
                allowUse: true,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    expect(find.text('正在加载照片'), findsOneWidget);
    final progress = find.byKey(const ValueKey('card-tail-photo-progress'));
    expect(progress, findsOneWidget);
    photo.completeError(StateError('原图已移动'));
    await tester.pumpAndSettle();
    expect(progress, findsNothing);
    expect(find.text('照片加载失败'), findsOneWidget);
    expect(find.text('原图已移动'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '整图识别'))
          .onPressed,
      isNull,
    );
    expect(find.text('设置取片码'), findsNothing);
    expect(find.text('核对后用于补录'), findsNothing);
  });
}
