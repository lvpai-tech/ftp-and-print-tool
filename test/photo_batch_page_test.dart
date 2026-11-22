import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/printing/ui/photo_batch_page.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('拖动和补录各自确认，取消时不写入', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1120, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final writes = <Map<String, dynamic>>[];
    final batches = <Map<String, dynamic>>[
      {
        'id': 'pending-1',
        'receivedAt': '2026-11-22T02:01:00Z',
        'status': 'MISSING_END',
        'photos': <Map<String, dynamic>>[
          {
            'id': '1',
            'ending': false,
            'revision': 0,
            'receivedAt': '2026-11-22T02:01:00Z',
            'thumbnailUrl': 'https://example.invalid/pending.jpg',
          },
        ],
      },
      {
        'id': 'card-2',
        'receivedAt': '2026-11-22T02:04:05Z',
        'status': 'CARD',
        'cardTail': '1234',
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
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoBatchPage(
          scenicName: '测试景区',
          call: (method, args) async => switch (method) {
            'listBatchStations' => <Map<String, dynamic>>[
              {'id': '17', 'code': 'A17', 'name': '测试机位'},
            ],
            'listPhotoBatches' => <String, dynamic>{'batches': batches},
            'correctPhotoBatch' => () {
              expect(args.first, '17');
              final request = args.last as Map<String, dynamic>;
              writes.add(request);
              return <String, dynamic>{
                'requestId': request['requestId'],
                'cardTail': '1234',
                'assignedCount': 1,
              };
            }(),
            _ => throw StateError(method),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> dragToCard() async {
      final source = find
          .byWidgetPredicate((widget) => widget is Draggable)
          .first;
      final from = tester.getCenter(source);
      final target = find
          .byWidgetPredicate((widget) => widget is DragTarget)
          .last;
      final to = tester.getCenter(target);
      final gesture = await tester.startGesture(from);
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await dragToCard();
    expect(find.text('确认移动照片'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);

    await dragToCard();
    await tester.tap(find.text('确认移动'));
    await tester.pumpAndSettle();
    expect(writes.single['targetPhotoId'], '2');
    expect(writes.single['targetCardId'], '99');

    await tester.tap(find.text('补录取片码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '1234');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));

    await tester.tap(find.text('补录取片码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '1234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认归批'));
    await tester.pumpAndSettle();
    expect(writes.last['cardCode'], '1234');
    expect(writes.last['photos'], [
      {'photoId': '1', 'revision': 0},
    ]);
  });
}
