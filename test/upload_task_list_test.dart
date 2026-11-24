import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/auto_upload/folder_uploader.dart';
import 'package:lvpai_ftp_client/ui/upload_task_list.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('入库照片只出现在照片归属，传输中的任务仍可查阅', (tester) async {
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

    Future<void> render() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              UploadTaskList(
                folder: folder,
                waiting: const {},
                needingOrder: const [],
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

    await render();
    expect(find.text('取片卡 394373'), findsOneWidget);
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
    expect(find.text('取片卡 394373'), findsOneWidget);
    expect(find.byTooltip('识别取片卡尾号'), findsNothing);
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

    final handle = find.byTooltip('按住拖动选择下一张').at(1);
    final target = find.text('拖到这里选为下一张');
    final drag = await tester.startGesture(tester.getCenter(handle));
    await drag.moveBy(const Offset(0, -24));
    await tester.pump();
    await drag.moveTo(tester.getCenter(target));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('ending.jpg'),
      ),
      findsOneWidget,
    );
    expect(confirmed, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(confirmed, isEmpty);

    await tester.tap(find.text('选为下一张').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认顺序'));
    await tester.pumpAndSettle();
    expect(confirmed, [second]);

    final remove = find.byTooltip('从上传队列移除').last;
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(removed, [later]);

    await render([]);
    expect(find.text('确认上传顺序'), findsNothing);
    expect(find.text('visitor-2.jpg'), findsOneWidget);
    expect(find.text('等待进入上传队列'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byTooltip('识别取片卡尾号'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byTooltip('识别取片卡尾号'));
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
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final strip = find.byType(Scrollbar);
    expect(strip, findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await tester.drag(strip, const Offset(-240, 0));
      await tester.pumpAndSettle();
    }
    expect(find.text('photo-6.jpg').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
