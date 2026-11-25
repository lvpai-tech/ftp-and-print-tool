import 'dart:async';

// The platform interface lets the test exercise the real save-picker call.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lvpai_ftp_client/printing/print_bridge.dart';
import 'package:lvpai_ftp_client/printing/ui/preview_dialog.dart';

class _SavePicker extends FileSelectorPlatform {
  FileSaveLocation? location = const FileSaveLocation('print-599.zip');

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async => location;
}

class _PreviewBridge extends PrintBridge {
  final downloads = <Completer<Json>>[];
  @override
  ZipExportProgress? zipProgress;

  void reportZipProgress(ZipExportProgress progress) {
    zipProgress = progress;
    notifyListeners();
  }

  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    switch (method) {
      case 'previewJob':
        return {
          'items': [
            for (final index in [1, 2])
              {
                'kind': 'ORIGINAL',
                'label': '原片',
                'copies': 1,
                'fileUrl': '/preview-files/PHOTO/$index',
              },
          ],
        };
      case 'previewJobImage':
        return {
          'dataUrl': 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
        };
      case 'downloadJobZip':
        expect(args, ['599', 'print-599.zip']);
        final download = Completer<Json>();
        downloads.add(download);
        return download.future;
      default:
        throw StateError('Unexpected operation: $method');
    }
  }
}

void main() {
  late _SavePicker picker;
  late _PreviewBridge bridge;

  setUp(() {
    final original = FileSelectorPlatform.instance;
    picker = _SavePicker();
    FileSelectorPlatform.instance = picker;
    bridge = _PreviewBridge();
    addTearDown(bridge.dispose);
    addTearDown(() => FileSelectorPlatform.instance = original);
  });

  Future<void> openPreview(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PreviewDialog(
                  bridge: bridge,
                  jobId: '599',
                  cardTail: '3094',
                  perform: (method, [args = const []]) async {
                    await bridge.run(method, args);
                    return true;
                  },
                ),
              ),
              child: const Text('打开预览'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开预览'));
    await tester.pumpAndSettle();
  }

  testWidgets('下载响应未返回时仍可翻页并关闭预览', (tester) async {
    await openPreview(tester);
    await tester.tap(find.text('下载本单 ZIP'));
    await tester.pump();

    expect(bridge.downloads, hasLength(1));
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '关闭预览',
            ),
          )
          .onPressed,
      isNotNull,
    );
    final progress = find.widgetWithText(FilledButton, '正在导出 ZIP…');
    expect(tester.widget<FilledButton>(progress).onPressed, isNull);
    bridge.reportZipProgress((completed: 1, total: 2, saving: false));
    await tester.pump();
    expect(find.text('已下载 1 / 2 张'), findsOneWidget);
    bridge.reportZipProgress((completed: 2, total: 2, saving: true));
    await tester.pump();
    expect(find.text('正在保存 ZIP…'), findsOneWidget);
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    expect(find.byType(PreviewDialog), findsNothing);

    bridge.downloads.single.completeError(StateError('连接已断开'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消保存和下载超时后都可重新下载', (tester) async {
    await openPreview(tester);
    final download = find.text('下载本单 ZIP');
    picker.location = null;
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(bridge.downloads, isEmpty);

    picker.location = const FileSaveLocation('print-599.zip');
    await tester.tap(download);
    await tester.pump();
    bridge.downloads.single.completeError(StateError('下载 ZIP 超时，请重试'));
    await tester.pumpAndSettle();
    expect(find.text('下载 ZIP 超时，请重试'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    await tester.tap(download);
    await tester.pump();
    expect(bridge.downloads, hasLength(2));
    bridge.downloads.last.complete({'path': 'print-599.zip'});
    await tester.pumpAndSettle();
    expect(find.text('ZIP 已保存：print-599.zip'), findsOneWidget);
  });
}
