import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/printing/ui/job_thumbnails.dart';
import 'package:material_ui/material_ui.dart';

import 'printing_workstation_test.dart';

const _jobId = '9007199254740993';
const _summary = '开头片 1 · 原片 2 · 创意 6';
const _requests = ['previewJob', 'previewJobImage', 'previewJobImage'];

class _DelayedThumbnailBridge extends ControlledBridge {
  final firstImage = Completer<void>();
  bool _isFirstImage = true;

  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    final response = await super.call(method, args);
    if (method == 'previewJobImage' && _isFirstImage) {
      _isFirstImage = false;
      await firstImage.future;
    }
    return response;
  }
}

Widget _queue(ControlledBridge bridge, ScrollController scroll) {
  return MaterialApp(
    home: Scaffold(
      body: ListView.builder(
        controller: scroll,
        itemCount: 20,
        itemExtent: 120,
        itemBuilder: (context, index) {
          if (index != 0) return const SizedBox.shrink();
          return JobThumbnails(
            bridge: bridge,
            jobId: _jobId,
            contentSummary: _summary,
            onOpenPreview: () {},
          );
        },
      ),
    ),
  );
}

void main() {
  testWidgets('已加载的缩略图滚出再滚回时无需重新请求', (tester) async {
    final bridge = ControlledBridge();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_queue(bridge, scroll));
    await tester.pumpAndSettle();
    final row = find.byType(JobThumbnails);
    final firstState = tester.state(row);
    expect(find.byType(Image), findsNWidgets(2));
    expect(bridge.calls, _requests);

    scroll.jumpTo(1200);
    await tester.pump();
    expect(row, findsNothing);
    expect(firstState.mounted, isFalse);

    scroll.jumpTo(0);
    await tester.pump();
    expect(bridge.calls, _requests);
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('缩略图下载期间滚回来时复用同一次请求', (tester) async {
    final bridge = _DelayedThumbnailBridge();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_queue(bridge, scroll));
    await tester.pump();
    expect(bridge.calls, ['previewJob', 'previewJobImage']);

    scroll.jumpTo(1200);
    await tester.pump();
    expect(find.byType(JobThumbnails), findsNothing);
    scroll.jumpTo(0);
    await tester.pump();
    expect(bridge.calls, ['previewJob', 'previewJobImage']);

    bridge.firstImage.complete();
    await tester.pumpAndSettle();
    expect(bridge.calls, _requests);
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('同一档案换绑景区时丢弃旧景区的下载结果', (tester) async {
    final bridge = _DelayedThumbnailBridge();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_queue(bridge, scroll));
    await tester.pump();
    final firstRequests = ['previewJob', 'previewJobImage'];
    expect(bridge.calls, firstRequests);

    bridge.snapshot['config'] = {
      ...bridge.config,
      'scenicIds': ['2'],
    };
    await tester.pumpWidget(_queue(bridge, scroll));
    await tester.pumpAndSettle();
    expect(bridge.calls, [...firstRequests, ..._requests]);
    expect(find.byType(Image), findsNWidgets(2));

    bridge.firstImage.complete();
    await tester.pumpAndSettle();
    expect(bridge.calls, [...firstRequests, ..._requests]);
    expect(find.byType(Image), findsNWidgets(2));
  });
}
