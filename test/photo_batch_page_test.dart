import 'dart:async';
import 'dart:ui' show PictureRecorder, PointerDeviceKind;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/printing/ui/photo_batch_page.dart';
import 'package:lvpai_ftp_client/ui/upload_task_list.dart';
import 'package:material_ui/material_ui.dart';

Widget _printBatchView({
  required Future<dynamic> Function(String, List<dynamic>) call,
  required String scenicName,
  String? initialStationId,
}) => Scaffold(
  body: PhotoBatchTimeline(
    call: call,
    scenicName: scenicName,
    initialStationId: initialStationId,
  ),
);

void main() {
  for (final inline in [false, true]) {
    testWidgets('${inline ? '上传任务列表' : '打印查看批次'}中拖动和批量归集各自确认，取消时不写入', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1120, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final writes = <Map<String, dynamic>>[];
      final moved = <Map<String, dynamic>>[];
      final removals = <Map<String, dynamic>>[];
      final groupRemovals = <Map<String, dynamic>>[];
      final batches = <Map<String, dynamic>>[
        {
          'id': 'pending-1',
          'receivedAt': '2026-11-22T02:01:00Z',
          'status': 'MISSING_END',
          'directory': 'incoming',
          'photos': <Map<String, dynamic>>[
            {
              'id': '1',
              'ending': false,
              'revision': 0,
              'receivedAt': '2026-11-22T02:01:00Z',
              'shotAt': '2026-11-22T10:01:00',
              'thumbnailUrl': 'https://example.invalid/pending.jpg',
              'previewUrl': 'https://example.invalid/pending-preview.jpg',
              'removalBlockedReason': '',
            },
            {
              'id': '3',
              'ending': false,
              'revision': 0,
              'blockedReason': '照片已用于打印',
              'receivedAt': '2026-11-22T02:01:05Z',
              'shotAt': '2026-11-22T10:03:05',
              'thumbnailUrl': 'https://example.invalid/blocked.jpg',
            },
          ],
        },
        {
          'id': 'card-2',
          'receivedAt': '2026-11-22T02:04:05Z',
          'status': 'CARD',
          'directory': 'aggregated',
          'cardTail': '123456',
          'targetPhotoId': '2',
          'targetCardId': '99',
          'photos': <Map<String, dynamic>>[
            {
              'id': '2',
              'ending': true,
              'revision': 0,
              'receivedAt': '2026-11-22T02:04:05Z',
              'thumbnailUrl': 'https://example.invalid/ending.jpg',
            },
          ],
        },
      ];
      Future<dynamic> call(String method, List<dynamic> args) async =>
          switch (method) {
            'listBatchStations' => <Map<String, dynamic>>[
              {'id': '18', 'code': 'A18', 'name': '其他机位'},
              {'id': '17', 'code': 'A17', 'name': '测试机位'},
            ],
            'listPhotoBatches' => () {
              expect((args.single as Map)['stationId'], '17');
              return <String, dynamic>{
                'batches': batches,
                'suspiciousIntervalSec': 120,
              };
            }(),
            'correctPhotoBatch' => () {
              expect(args.first, '17');
              final request = args.last as Map<String, dynamic>;
              writes.add(request);
              return <String, dynamic>{
                'requestId': request['requestId'],
                'cardTail': '123456',
                'assignedCount': 1,
              };
            }(),
            'previewPhotoBatchSplit' => () {
              final point = args.single as Map;
              expect(point['beforePhotoId'], '1');
              expect(point['afterPhotoId'], '3');
              return {
                'snapshot': 'a' * 64,
                'thresholdSec': 120,
                'managementOnly': true,
                'parts': [
                  {
                    'directory': 'incoming',
                    'photos': [(batches.first['photos'] as List).first],
                  },
                  {
                    'directory': 'incoming',
                    'photos': [(batches.first['photos'] as List).last],
                  },
                ],
              };
            }(),
            'savePhotoBatchSplit' => () {
              expect(args.last, {
                'beforePhotoId': '1',
                'afterPhotoId': '3',
                'snapshot': 'a' * 64,
                'thresholdSec': 120,
              });
              return {
                'messages': ['切分已保存'],
              };
            }(),
            'movePhotoBatchPhoto' => () {
              moved.add(args.last as Map<String, dynamic>);
              expect(args.last, {
                'photoId': '3',
                'revision': 0,
                'targetPhotoId': '2',
                'targetRevision': 0,
              });
              return {'photoId': '3', 'targetPhotoId': '2'};
            }(),
            'removeBatchPhoto' => () {
              expect(args.first, '17');
              expect(args[1], '1');
              final request = args.last as Map<String, dynamic>;
              removals.add(request);
              return {'requestId': request['requestId'], 'photoId': '1'};
            }(),
            'removePhotoBatch' => () {
              expect(args.first, containsPair('stationId', '17'));
              final request = args.last as Map<String, dynamic>;
              groupRemovals.add(request);
              batches.removeWhere((batch) => batch['id'] == 'pending-1');
              return {'requestId': request['requestId'], 'removedCount': 2};
            }(),
            'getBatchPhotoCapture' => () {
              expect(args, ['17', '1']);
              return {
                'collected': true,
                'artist': 'PH-023',
                'cameraMake': 'Canon',
                'cameraModel': 'EOS R6',
                'photographer': '张三',
                'assignmentSource': 'MANUAL',
              };
            }(),
            _ => throw StateError(method),
          };
      await tester.pumpWidget(
        MaterialApp(
          home: inline
              ? Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      UploadTaskList(
                        folder: '',
                        waiting: const {},
                        needingOrder: const [],
                        jobs: const [],
                        onConfirmNext: null,
                        onReview: (_) {},
                        batchTimeline: PhotoBatchTimeline.inline(
                          call: call,
                          scenicName: '测试景区',
                          stationId: '17',
                        ),
                      ),
                    ],
                  ),
                )
              : _printBatchView(
                  scenicName: '测试景区',
                  initialStationId: '17',
                  call: call,
                ),
        ),
      );
      await tester.pumpAndSettle();
      if (inline) {
        expect(find.text('上传队列'), findsOneWidget);
        expect(find.text('照片归属'), findsOneWidget);
        expect(find.text('设置取片批次'), findsNothing);
        expect(find.byTooltip('选择机位'), findsNothing);
        expect(find.textContaining('A17'), findsOneWidget);
      }
      await tester.tap(find.text('全部状态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已归集').last);
      await tester.pumpAndSettle();
      expect(find.text('10:01:00'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('已归集').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部状态').last);
      await tester.pumpAndSettle();
      final newer = find.text('10:04:05').first;
      final older = find.text('10:01:00').first;
      final gap = find.text('间隔 3 分 0 秒');
      expect(
        tester.getTopLeft(gap).dy,
        greaterThan(tester.getTopLeft(newer).dy),
      );
      expect(tester.getTopLeft(gap).dy, lessThan(tester.getTopLeft(older).dy));
      expect(
        tester.getCenter(find.text('游客照 10:01:00')).dx,
        lessThan(tester.getCenter(find.text('游客照 10:01:05')).dx),
      );

      final movablePhoto = find.byKey(const ValueKey('drag-photo-1'));
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      expect(find.byKey(const ValueKey('drag-photo-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('drag-photo-3')), findsOneWidget);
      final interval = tester.widget<IconButton>(
        find.byKey(const ValueKey('photo-interval-1-3')),
      );
      expect(interval.tooltip, '间隔 2 分 5 秒，超过 120 秒阈值');
      expect(
        interval.style!.foregroundColor!.resolve({}),
        const Color(0xffaa7900),
      );
      await tester.tap(find.byKey(const ValueKey('photo-interval-1-3')));
      await tester.pumpAndSettle();
      expect(find.text('切分结果预览'), findsOneWidget);
      await tester.tap(find.text('保存切分'));
      await tester.pumpAndSettle();
      expect(find.text('切分已保存'), findsOneWidget);

      Future<void> dragToCard(Finder source) async {
        final from = tester.getCenter(source);
        final target = find.ancestor(
          of: find.text('取片卡 123456'),
          matching: find.byWidgetPredicate((widget) => widget is DragTarget),
        );
        final to = Offset(
          tester.getCenter(newer).dx,
          tester.getCenter(target).dy,
        );
        final gesture = await tester.startGesture(
          from,
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        await gesture.moveTo(to);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await dragToCard(movablePhoto);
      expect(find.text('确认移动照片'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);

      await dragToCard(movablePhoto);
      await tester.tap(find.text('同时归入目标取片卡'));
      await tester.pump();
      await tester.tap(find.text('确认移动'));
      await tester.pumpAndSettle();
      expect(writes.single['targetPhotoId'], '2');
      expect(writes.single['targetCardId'], '99');
      await dragToCard(find.byKey(const ValueKey('drag-photo-3')));
      await tester.tap(find.text('确认移动'));
      await tester.pumpAndSettle();
      expect(moved, hasLength(1));
      expect(find.text('无法确认移动结果'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('photo-actions-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到其他批次'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, '选择目标批次'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(ListTile, '取片卡 123456 · 2026-11-22 10:04:05'),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认移动照片'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));

      await tester.tap(find.text('批量归集'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '设置取片批次'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<Checkbox>(find.byKey(const ValueKey('select-photo-2')))
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<Checkbox>(find.byKey(const ValueKey('select-photo-3')))
            .onChanged,
        isNull,
      );
      await tester.tap(find.text('选中本组可处理照片'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 张'), findsOneWidget);
      final assign = find.widgetWithText(FilledButton, '设置取片批次');
      await tester.tap(assign);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, '输入取片码'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '选择已有批次'));
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(FilledButton, '确认归集');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(find.widgetWithText(OutlinedButton, '选择目标批次'));
      await tester.pumpAndSettle();
      final targetOption = find.ancestor(
        of: find.textContaining('取片卡 123456 ·'),
        matching: find.byType(ListTile),
      );
      expect(targetOption, findsOneWidget);
      await tester.tap(targetOption);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));

      await tester.tap(assign);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '123456');
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认归集'));
      await tester.pumpAndSettle();
      expect(writes.last['cardCode'], '123456');
      expect(writes.last['photos'], [
        {'photoId': '1', 'revision': 0},
      ]);
      if (inline) {
        await tester.binding.setSurfaceSize(const Size(375, 650));
        await tester.pumpAndSettle();
        expect(find.text('上传队列'), findsOneWidget);
        expect(find.text('取片卡 123456'), findsOneWidget);
        expect(find.text('批量归集'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.binding.setSurfaceSize(const Size(1120, 850));
      await tester.pumpAndSettle();
      Future<void> selectPhotoAction(String id, String action) async {
        await tester.tap(find.byKey(ValueKey('photo-actions-$id')));
        await tester.pumpAndSettle();
        expect(find.text('识别取片码'), findsOneWidget);
        expect(find.text('删除照片'), findsOneWidget);
        expect(find.text('查询拍摄信息'), findsOneWidget);
        expect(find.text('查看图片'), findsOneWidget);
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
      }

      await selectPhotoAction('1', '查看图片');
      expect(find.text('游客照预览'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await selectPhotoAction('1', '查询拍摄信息');
      expect(find.textContaining('Canon EOS R6'), findsOneWidget);
      expect(find.textContaining('张三（人工）'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await selectPhotoAction('1', '识别取片码');
      expect(find.text('识别取片码'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await selectPhotoAction('2', '识别取片码');
      expect(find.text('当前照片没有可用于识别的大图。'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await selectPhotoAction('2', '删除照片');
      expect(find.text('删除这张照片？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await selectPhotoAction('1', '删除照片');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(removals, isEmpty);
      await selectPhotoAction('1', '删除照片');
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(removals.single['revision'], 0);
      final deleteGroup = find.widgetWithText(TextButton, '整批删除').last;
      await tester.tap(deleteGroup);
      await tester.pumpAndSettle();
      expect(find.text('整批删除？'), findsOneWidget);
      expect(find.textContaining('共 2 张照片'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(groupRemovals, isEmpty);
      await tester.tap(deleteGroup);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认删除'));
      await tester.pumpAndSettle();
      expect(groupRemovals.single['photos'], [
        {'photoId': '1', 'revision': 0},
        {'photoId': '3', 'revision': 0},
      ]);
      expect(find.widgetWithText(TextButton, '整批删除'), findsOneWidget);
    });
  }

  testWidgets('弹窗先显示列表缩略图，大图加载成功或失败时状态明确', (tester) async {
    const thumbnailUrl = 'https://example.invalid/batch-thumb.jpg';
    const previewUrl = 'https://example.invalid/batch-preview.jpg';
    const failedPreviewUrl = 'https://example.invalid/batch-preview-failed.jpg';
    final thumbnail = ResizeImage(const NetworkImage(thumbnailUrl), width: 240);
    final thumbnailKey = await thumbnail.obtainKey(ImageConfiguration.empty);
    final ready = Completer<ImageInfo>();
    final failed = Completer<ImageInfo>();
    final cache = PaintingBinding.instance.imageCache;

    ImageInfo pixel(int size) {
      final recorder = PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xff228866), BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(size, size);
      picture.dispose();
      return ImageInfo(image: image);
    }

    cache.putIfAbsent(
      thumbnailKey,
      () => OneFrameImageStreamCompleter(SynchronousFuture(pixel(1))),
    );
    cache.putIfAbsent(
      const NetworkImage(previewUrl),
      () => OneFrameImageStreamCompleter(ready.future),
    );
    cache.putIfAbsent(
      const NetworkImage(failedPreviewUrl),
      () => OneFrameImageStreamCompleter(failed.future),
    );
    addTearDown(() {
      cache.evict(thumbnailKey);
      cache.evict(const NetworkImage(previewUrl));
      cache.evict(const NetworkImage(failedPreviewUrl));
    });

    await tester.pumpWidget(
      MaterialApp(
        home: _printBatchView(
          scenicName: '测试景区',
          call: (method, args) async => switch (method) {
            'listBatchStations' => [
              {'id': '17', 'code': 'A17', 'name': '测试机位'},
            ],
            'listPhotoBatches' => {
              'batches': [
                {
                  'id': 'pending-1',
                  'receivedAt': '2026-11-22T02:01:00Z',
                  'status': 'MISSING_END',
                  'photos': [
                    for (final (index, url) in [
                      previewUrl,
                      failedPreviewUrl,
                    ].indexed)
                      {
                        'id': '${index + 1}',
                        'ending': false,
                        'receivedAt': '2026-11-22T02:01:00Z',
                        'thumbnailUrl': thumbnailUrl,
                        'previewUrl': url,
                      },
                  ],
                },
              ],
            },
            _ => throw StateError(method),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Draggable), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    final photos = find.byType(Image);
    final dialog = find.byType(AlertDialog);
    final displayed = find.descendant(
      of: dialog,
      matching: find.byType(RawImage),
    );
    await tester.tap(photos.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在加载大图…'), findsOneWidget);
    expect(tester.widget<RawImage>(displayed).image?.width, 1);

    ready.complete(pixel(2));
    await tester.pumpAndSettle();
    expect(find.text('正在加载大图…'), findsNothing);
    expect(tester.widget<RawImage>(displayed).image?.width, 2);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(photos.last);
    await tester.pump();
    failed.completeError(StateError('预览请求失败'));
    await tester.pumpAndSettle();
    expect(find.text('大图加载失败，请刷新批次后重试'), findsOneWidget);
    expect(tester.widget<RawImage>(displayed).image?.width, 1);
  });

  testWidgets('机位和日期菜单在按钮下方展开，选一天即查询北京时间整日', (tester) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final queries = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: _printBatchView(
          scenicName: '测试景区',
          call: (method, args) async => switch (method) {
            'listBatchStations' => [
              for (var number = 1; number <= 8; number++)
                {'id': '$number', 'code': 'A$number', 'name': '测试机位'},
            ],
            'listPhotoBatches' => () {
              queries.add(args.single as Map<String, dynamic>);
              return {'batches': <Map<String, dynamic>>[]};
            }(),
            _ => throw StateError(method),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final defaultFrom = queries.single['from'] as String;
    final defaultDay = DateTime.parse(
      '${defaultFrom.substring(0, 10)}T00:00:00Z',
    );
    expect(defaultFrom, endsWith('T00:00:00+08:00'));
    expect(
      DateTime.parse(queries.single['to'] as String)
          .difference(DateTime.parse(defaultFrom)),
      const Duration(days: 1),
    );

    final stationButton = find.byTooltip('选择机位');
    final dayButton = find.byTooltip('选择收图日期');
    final stationBounds = tester.getRect(stationButton);
    final dayBounds = tester.getRect(dayButton);
    await tester.tap(stationButton);
    await tester.pumpAndSettle();
    final lastStation = find.widgetWithText(ListTile, 'A8 · 测试机位');
    await tester.scrollUntilVisible(
      lastStation,
      60,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    await tester.pumpAndSettle();
    await tester.tap(lastStation);
    await tester.pumpAndSettle();
    expect(queries.last['stationId'], '8');
    expect(queries.last['from'], defaultFrom);

    await tester.tap(stationButton);
    await tester.pumpAndSettle();
    final stationOption = find.widgetWithText(ListTile, 'A1 · 测试机位');
    final stationOptionBounds = tester.getRect(stationOption);
    expect(stationOptionBounds.top, greaterThanOrEqualTo(stationBounds.bottom));
    expect(stationOptionBounds.right, lessThan(dayBounds.left));

    await tester.tap(dayButton);
    await tester.pumpAndSettle();
    expect(stationOption, findsNothing);
    expect(
      tester.getTopLeft(find.byTooltip('上个月')).dy,
      greaterThanOrEqualTo(dayBounds.bottom),
    );
    expect(find.textContaining(' · 今天'), findsOneWidget);
    await tester.tap(find.byTooltip('上个月'));
    await tester.pumpAndSettle();
    expect(queries, hasLength(2));
    final previousMonthLastDay = DateTime.utc(
      defaultDay.year,
      defaultDay.month,
      0,
    );
    await tester.tap(find.byKey(ValueKey(previousMonthLastDay)));
    await tester.pumpAndSettle();
    expect(queries, hasLength(3));
    expect(queries.last, {
      'stationId': '8',
      'from':
          '${previousMonthLastDay.toIso8601String().substring(0, 10)}T00:00:00+08:00',
      'to': '${defaultDay.toIso8601String().substring(0, 7)}-01T00:00:00+08:00',
    });
  });
}
