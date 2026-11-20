import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../print_bridge.dart';
import 'design.dart';

/// 与 Electron 列表一致：最多 2 行并发、每行最多 3 张非开头片缩略图。
class _ThumbScheduler {
  static var active = 0;
  static final _queue = <Future<void> Function()>[];

  static Future<T> run<T>(Future<T> Function() task) {
    final done = Completer<T>();
    _queue.add(() async {
      try {
        done.complete(await task());
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    _drain();
    return done.future;
  }

  static void _drain() {
    while (active < 2 && _queue.isNotEmpty) {
      active++;
      final next = _queue.removeAt(0);
      unawaited(
        next().whenComplete(() {
          active--;
          _drain();
        }),
      );
    }
  }
}

class JobThumbnails extends StatefulWidget {
  const JobThumbnails({
    super.key,
    required this.bridge,
    required this.jobId,
    required this.contentSummary,
    required this.onOpenPreview,
  });

  final PrintBridge bridge;
  final String jobId;
  final String contentSummary;
  final VoidCallback onOpenPreview;

  @override
  State<JobThumbnails> createState() => _JobThumbnailsState();
}

class _JobThumbnailsState extends State<JobThumbnails> {
  List<_ThumbItem>? items;
  int remaining = 0;
  String? error;
  var attempt = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant JobThumbnails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jobId != widget.jobId ||
        oldWidget.contentSummary != widget.contentSummary) {
      load();
    }
  }

  Future<void> load() async {
    final token = ++attempt;
    setState(() {
      items = null;
      remaining = 0;
      error = null;
    });
    try {
      final result = await _ThumbScheduler.run(() async {
        final job = await widget.bridge.call('previewJob', [widget.jobId]);
        if (job is! Map) throw StateError('预览清单无效');
        final raw = (job['items'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final photos = raw.where((item) => item['kind'] != 'COVER').toList();
        final loaded = <_ThumbItem>[];
        for (final item in photos.take(3)) {
          if (token != attempt) return null;
          final url = '${item['fileUrl'] ?? ''}';
          if (url.isEmpty) continue;
          final image = await widget.bridge.call('previewJobImage', [
            '$url${url.contains('?') ? '&' : '?'}thumbnail=true',
          ]);
          if (image is! Map || image['dataUrl'] is! String) {
            throw StateError('缩略图响应无效');
          }
          final dataUrl = image['dataUrl'] as String;
          final bytes = base64Decode(dataUrl.split(',').last);
          loaded.add(
            _ThumbItem(
              label: '${item['label'] ?? item['kind'] ?? '照片'}',
              copies: (item['copies'] as num?)?.toInt() ?? 1,
              bytes: bytes,
            ),
          );
        }
        final count = raw.fold<int>(
          0,
          (sum, item) => sum + ((item['copies'] as num?)?.toInt() ?? 1),
        );
        final displayed = loaded.fold<int>(0, (sum, item) => sum + item.copies);
        return (items: loaded, remaining: count - displayed);
      });
      if (!mounted || token != attempt || result == null) return;
      setState(() {
        items = result.items;
        remaining = result.remaining;
      });
    } catch (e) {
      if (!mounted || token != attempt) return;
      setState(() => error = e is StateError ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return TextButton(
        onPressed: load,
        style: TextButton.styleFrom(foregroundColor: Colors.red),
        child: const Text('图片加载失败，重试'),
      );
    }
    if (items == null) {
      return const Text('缩略图加载中…', style: TextStyle(color: muted, fontSize: 12));
    }
    if (items!.isEmpty) {
      return const Text('无照片条目', style: TextStyle(color: muted, fontSize: 12));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in items!)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: widget.onOpenPreview,
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 64,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: const Color(0xfffafafa),
                        border: Border.all(color: const Color(0xfff0f0f0)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.memory(item.bytes, fit: BoxFit.contain),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.label} ×${item.copies}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (remaining > 0)
          Text('另 $remaining 张', style: const TextStyle(color: muted, fontSize: 12)),
      ],
    );
  }
}

class _ThumbItem {
  const _ThumbItem({
    required this.label,
    required this.copies,
    required this.bytes,
  });
  final String label;
  final int copies;
  final Uint8List bytes;
}
