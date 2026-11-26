import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/auto_upload/folder_uploader.dart';
import 'package:lvpai_ftp_client/ui/upload_task_list.dart';
import 'package:lvpai_ftp_client/ui/workstation_form_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('默认展示照片批次，待确认提醒可切换到本机上传', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1120, 950));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final folder = p.absolute('inbox');
    AutoJob job(String state) => AutoJob(
      id: state,
      source: p.join(folder, '$state.jpg'),
      relative: '$state.jpg',
      signature: '',
      digest: '',
      snapshot: p.join(folder, '$state.snapshot'),
      state: state,
    );
    final jobs = [
      for (final state in [
        'grouped',
        'ingested',
        'accepted',
        'uploading',
        'failed',
        'pending',
      ])
        job(state),
    ];

    final source = p.join(folder, 'needs-order.jpg');
    Future<void> render({bool needsOrder = false}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              UploadTaskList(
                folder: folder,
                waiting: {if (needsOrder) source: null},
                needingOrder: [if (needsOrder) source],
                jobs: jobs,
                onConfirmNext: null,
                onReview: (_) {},
                batchTimeline: const SliverToBoxAdapter(
                  child: Text('取片卡 394373'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await render(needsOrder: true);
    expect(find.text('取片卡 394373'), findsOneWidget);
    expect(find.text('上传中 0%'), findsNothing);
    final reminder = find.text('待确认顺序');
    expect(
      tester.getCenter(reminder).dx,
      greaterThan(tester.getCenter(find.text('本机上传')).dx),
    );
    await tester.tap(reminder);
    await tester.pump();
    expect(find.text('取片卡 394373'), findsNothing);
    expect(find.text('确认上传顺序'), findsOneWidget);
    expect(find.text('已入队任务'), findsNothing);
    expect(find.text('grouped.jpg'), findsNothing);
    expect(find.text('ingested.jpg'), findsNothing);
    expect(find.text('已上传 · 等待入库'), findsOneWidget);
    expect(find.text('上传中 0%'), findsOneWidget);
    expect(find.text('上传失败'), findsOneWidget);
    expect(find.text('等待上传'), findsOneWidget);

    for (final job in jobs) {
      job.state = 'grouped';
    }
    await render();
    expect(find.text('本机暂无上传任务'), findsOneWidget);
    expect(find.byTooltip('照片操作'), findsNothing);
    expect(reminder, findsNothing);
    await tester.tap(find.text('照片批次'));
    await tester.pump();
    expect(find.text('取片卡 394373'), findsOneWidget);
    expect(find.text('本机暂无上传任务'), findsNothing);
  });

  testWidgets('确认顺序、待准备和已入队照片在同一列表显示', (tester) async {
    final folder = p.absolute('inbox');
    final first = p.join(folder, 'visitor-1.jpg');
    final second = p.join(folder, 'ending.jpg');
    final later = p.join(folder, 'visitor-2.jpg');
    final date = DateTime.utc(2026, 11, 23, 0, 29, 9);
    String signature(int minutes) =>
        '12:${date.add(Duration(minutes: minutes)).microsecondsSinceEpoch}';
    final uploaded = AutoJob(
      id: 'uploaded',
      source: p.join(folder, 'uploaded.jpg'),
      relative: 'uploaded.jpg',
      signature: '12:${date.microsecondsSinceEpoch}',
      digest: '',
      snapshot: p.join(folder, 'snapshot.jpg'),
      state: 'grouped',
    );
    final confirmed = <String>[];
    final reviewed = <AutoJob>[];
    final removed = <String>[];

    Future<void> render(List<String> needingOrder) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              UploadTaskList(
                folder: folder,
                waiting: {
                  first: signature(4),
                  second: signature(4),
                  later: signature(9),
                },
                needingOrder: needingOrder,
                jobs: [uploaded],
                onConfirmNext: confirmed.add,
                onReview: reviewed.add,
                onDiscard: (source, stamp) async {
                  expect(stamp, signature(9));
                  removed.add(source);
                },
              ),
            ],
          ),
        ),
      ),
    );

    await render([first, second]);
    expect(find.text('确认上传顺序'), findsOneWidget);
    expect(find.text('等待前面的照片确认顺序'), findsOneWidget);
    expect(find.text('visitor-1.jpg'), findsOneWidget);
    expect(find.text('ending.jpg'), findsOneWidget);
    expect(find.text('visitor-2.jpg'), findsOneWidget);
    expect(find.byType(Image), findsAtLeastNWidgets(3));
    expect(find.text('已归卡'), findsOneWidget);
    expect(find.text('2026-11-23'), findsNWidgets(3));
    expect(find.text('08:33:09'), findsAtLeastNWidgets(1));
    expect(find.text('间隔 5 分 0 秒'), findsOneWidget);
    expect(find.text('设置取片批次'), findsNothing);

    final thumbnail = find.byWidgetPredicate(
      (widget) => widget is Draggable<String> && widget.data == second,
    );
    await tester.tap(thumbnail);
    await tester.pumpAndSettle();
    expect(find.text('照片预览'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    final target = find.text('确认上传顺序');
    final dropArea = find.byType(DragTarget<String>);
    final dropAreaBeforeHover = tester.getRect(dropArea);
    final drag = await tester.startGesture(
      tester.getCenter(thumbnail),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, -24));
    await tester.pump();
    await drag.moveTo(tester.getCenter(target));
    await tester.pump();
    expect(find.text('松开后确认上传顺序').hitTestable(), findsOneWidget);
    expect(tester.getRect(dropArea), dropAreaBeforeHover);
    await drag.up();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(WorkstationFormDialog),
        matching: find.text('ending.jpg'),
      ),
      findsOneWidget,
    );
    expect(confirmed, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(confirmed, isEmpty);

    Finder actionsFor(String source) => find.descendant(
      of: find.byKey(ValueKey(source)),
      matching: find.byTooltip('照片操作'),
    );
    await tester.tap(actionsFor(second));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选为下一张'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认顺序'));
    await tester.pumpAndSettle();
    expect(confirmed, [second]);

    final remove = actionsFor(later);
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.text('选为下一张'), findsNothing);
    await tester.tap(find.text('从上传队列移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(removed, [later]);

    await render([]);
    expect(find.text('确认上传顺序'), findsNothing);
    expect(find.text('visitor-2.jpg'), findsOneWidget);
    expect(find.text('等待进入上传队列'), findsOneWidget);
    final review = actionsFor(uploaded.id);
    await tester.scrollUntilVisible(
      review,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(review);
    await tester.pumpAndSettle();
    await tester.tap(find.text('识别取片卡尾号'));
    await tester.pumpAndSettle();
    expect(reviewed, [uploaded]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口可以横向查看确认组里的后续照片', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final folder = p.absolute('inbox');
    final sources = List.generate(
      7,
      (index) => p.join(folder, 'photo-$index.jpg'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(20),
                sliver: UploadTaskList(
                  folder: folder,
                  waiting: {for (final source in sources) source: null},
                  needingOrder: sources,
                  jobs: const [],
                  onConfirmNext: (_) {},
                  onReview: (_) {},
                  batchTimeline: const SliverToBoxAdapter(
                    child: Text('照片批次内容'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('待确认顺序'));
    await tester.pumpAndSettle();
    final strip = find.byType(Scrollbar);
    expect(strip, findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await tester.dragFrom(
        tester.getTopLeft(strip) + const Offset(240, 70),
        const Offset(-220, 0),
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('photo-6.jpg').hitTestable(), findsOneWidget);
    final lastPhotoMenu = find.descendant(
      of: find.byKey(ValueKey(sources.last)),
      matching: find.byTooltip('照片操作'),
    );
    await tester.tap(lastPhotoMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('选为下一张'));
    await tester.pumpAndSettle();
    expect(find.text('确认顺序').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('关闭弹窗'));
    await tester.pumpAndSettle();
    expect(find.text('确认顺序'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
