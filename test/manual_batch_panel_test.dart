import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lvpai_ftp_client/manual_batch/batch_workspace.dart';
import 'package:lvpai_ftp_client/ui/manual_batch_panel.dart';
import 'package:lvpai_ftp_client/transfer.dart';

import 'manual_batch_test.dart' as fixtures;

void main() {
  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('手动批次在$width宽度可增减并核对上传，未确认不连接FTP', (tester) async {
      const folderAccess = MethodChannel('ai.lvpai.ftp/folder-access');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(folderAccess, (call) async {
        expect(call.method, 'release');
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(folderAccess, null));

      late Directory root;
      late BatchWorkspace work;
      await tester.runAsync(() async {
        root = await Directory(
          '${Directory.current.parent.path}/test-results/ftp-manual-ui/'
          '${DateTime.now().microsecondsSinceEpoch}-$width',
        ).create(recursive: true);
        work = BatchWorkspace(storage: Directory('${root.path}/state'));
        await work.open();
        await work.addFiles([
          await fixtures.photo(root, 'visitor'),
          await fixtures.photo(root, 'card', secret: 'TEST00002522'),
        ]);
      });
      final pixelRatio = width == 768 ? 2.0 : 1.0;
      tester.view.physicalSize = Size(width * pixelRatio, 1200 * pixelRatio);
      tester.view.devicePixelRatio = pixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var profileSaved = false;
      bool? active;
      final screenshotKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: screenshotKey,
            child: Scaffold(
              body: SingleChildScrollView(
                child: ManualBatchPanel(
                  workspace: work,
                  readProfile: () => ServerProfile(
                    name: 'test',
                    host: '127.0.0.1',
                    port: 1,
                    user: 'unused',
                    password: 'unused',
                    directory: '/',
                  ),
                  saveProfile: (_) async {
                    profileSaved = true;
                  },
                  onActiveChanged: (value) => active = value,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            screenshotKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final screenshot = await boundary.toImage();
        final data = await screenshot.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await File(
          '${root.path}/workspace.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        screenshot.dispose();
      });
      expect(active, isFalse, reason: '草稿不能锁住服务器配置和模式切换');
      final thumbnail = find.byType(Image).first;
      final thumbnailProvider = tester.widget<Image>(thumbnail).image;
      expect(thumbnailProvider, isA<ResizeImage>());
      final resized = thumbnailProvider as ResizeImage;
      expect(resized.width, (160 * pixelRatio).round());
      await tester.ensureVisible(thumbnail);
      await tester.tap(thumbnail);
      await tester.pumpAndSettle();
      final preview = find.descendant(
        of: find.byType(InteractiveViewer),
        matching: find.byType(Image),
      );
      expect(tester.widget<Image>(preview).image, resized.imageProvider);
      Navigator.of(tester.element(preview)).pop();
      await tester.pumpAndSettle();
      expect(preview, findsNothing);

      await tester.ensureVisible(find.text('移出批次').first);
      await tester.runAsync(() async {
        await tester.tap(find.text('移出批次').first);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(work.unassigned.length, 1);
      expect(work.batches.single.photoIds.length, 1);
      await tester.ensureVisible(find.text('加入当前批次'));
      await tester.runAsync(() async {
        await tester.tap(find.text('加入当前批次'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(work.batches.single.photoIds.length, 2);
      await tester.ensureVisible(find.text('上传此批次'));
      await tester.tap(find.text('上传此批次'));
      await tester.pumpAndSettle();
      expect(find.text('确认上传该批次'), findsOneWidget);
      expect(find.textContaining('1 张游客照和1张结束照'), findsOneWidget);
      await tester.tap(find.text('继续调整'));
      await tester.pumpAndSettle();
      expect(profileSaved, isFalse);
      expect(work.batches.single.state, 'draft');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.runAsync(() async {
        await work.close();
        work.dispose();
      });
    });
  }
}
