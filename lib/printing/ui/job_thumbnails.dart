import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../ui/app_dialogs.dart';
import '../../ui/design.dart';
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

typedef _ThumbKey = ({String jobId, String contentSummary});
typedef _ScenicScope = ({String base, String profileId, String scenicIds});

/// 列表行销毁后，当前景区的缩略图和下载任务仍可被新行复用。
class _JobThumbnailCache {
  _JobThumbnailCache(this.scope);

  static final _scopedCaches = Expando<_JobThumbnailCache>();
  static const _maxEntries = 64;
  static const _maxBytes = 16 * 1024 * 1024;

  final _ScenicScope scope;
  final _entries = <_ThumbKey, _ThumbCacheEntry>{};
  final _inflight = <_ThumbKey, Future<_ThumbCacheEntry>>{};
  int _storedBytes = 0;

  static _JobThumbnailCache forBridge(PrintBridge bridge) {
    final config = bridge.config;
    final scope = (
      base: '${config['base'] ?? ''}',
      profileId: '${config['activeScenicProfileId'] ?? ''}',
      scenicIds: (config['scenicIds'] as List?)?.join(',') ?? '',
    );
    final existing = _scopedCaches[bridge];
    if (existing != null && existing.scope == scope) return existing;
    return _scopedCaches[bridge] = _JobThumbnailCache(scope);
  }

  _ThumbCacheEntry? peek(_ThumbKey key) {
    final entry = _entries.remove(key);
    if (entry != null) _entries[key] = entry;
    return entry;
  }

  Future<_ThumbCacheEntry> load(
    PrintBridge bridge,
    _ThumbKey key, {
    List<String>? originalUrls,
    int? originalPhotoCount,
  }) {
    final cached = peek(key);
    if (cached != null) return Future.value(cached);
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future =
        _ThumbScheduler.run(
              () => originalUrls == null
                  ? _download(bridge, key.jobId)
                  : _downloadOriginals(
                      bridge,
                      originalUrls,
                      originalPhotoCount!,
                    ),
            )
            .then((entry) {
              _remember(key, entry);
              return entry;
            })
            .whenComplete(() {
              _inflight.remove(key);
            });
    _inflight[key] = future;
    return future;
  }

  void _remember(_ThumbKey key, _ThumbCacheEntry entry) {
    if (entry.byteCount > _maxBytes) return;
    _entries[key] = entry;
    _storedBytes += entry.byteCount;
    while (_entries.length > _maxEntries || _storedBytes > _maxBytes) {
      final evicted = _entries.remove(_entries.keys.first)!;
      _storedBytes -= evicted.byteCount;
    }
  }

  void _checkScope(PrintBridge bridge) {
    if (!identical(this, forBridge(bridge))) {
      throw StateError('景区已切换，请重新加载缩略图');
    }
  }

  Future<_ThumbCacheEntry> _download(PrintBridge bridge, String jobId) async {
    _checkScope(bridge);
    final job = await bridge.call('previewJob', [jobId]);
    _checkScope(bridge);
    if (job is! Map) throw StateError('预览清单无效');
    final raw = (job['items'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final photos = raw.where((item) => item['kind'] != 'COVER').toList();
    final loaded = <_ThumbItem>[];
    for (final item in photos.take(3)) {
      final url = '${item['fileUrl'] ?? ''}';
      if (url.isEmpty) continue;
      loaded.add(
        await _downloadItem(
          bridge,
          '$url${url.contains('?') ? '&' : '?'}thumbnail=true',
          '${item['label'] ?? item['kind'] ?? '照片'}',
          (item['copies'] as num?)?.toInt() ?? 1,
        ),
      );
    }
    final count = raw.fold<int>(
      0,
      (sum, item) => sum + ((item['copies'] as num?)?.toInt() ?? 1),
    );
    final displayed = loaded.fold<int>(0, (sum, item) => sum + item.copies);
    return _ThumbCacheEntry(items: loaded, remaining: count - displayed);
  }

  Future<_ThumbCacheEntry> _downloadOriginals(
    PrintBridge bridge,
    List<String> urls,
    int count,
  ) async {
    final loaded = <_ThumbItem>[];
    for (final url in urls) {
      loaded.add(await _downloadItem(bridge, url, '原片', 1));
    }
    return _ThumbCacheEntry(items: loaded, remaining: count - loaded.length);
  }

  Future<_ThumbItem> _downloadItem(
    PrintBridge bridge,
    String url,
    String label,
    int copies,
  ) async {
    _checkScope(bridge);
    final image = await bridge.call('previewJobImage', [url]);
    _checkScope(bridge);
    if (image is! Map || image['dataUrl'] is! String) {
      throw StateError('缩略图响应无效');
    }
    final dataUrl = image['dataUrl'] as String;
    return _ThumbItem(
      label: label,
      copies: copies,
      bytes: base64Decode(dataUrl.split(',').last),
    );
  }
}

class _ThumbCacheEntry {
  _ThumbCacheEntry({required this.items, required this.remaining})
    : byteCount = items.fold(0, (sum, item) => sum + item.bytes.lengthInBytes);

  final List<_ThumbItem> items;
  final int remaining;
  final int byteCount;
}

class JobThumbnails extends StatefulWidget {
  const JobThumbnails({
    super.key,
    required this.bridge,
    required this.jobId,
    required this.contentSummary,
    required VoidCallback this.onOpenPreview,
  }) : originalUrls = null,
       originalPhotoCount = null;

  JobThumbnails.originals({
    super.key,
    required this.bridge,
    required String receiptId,
    required List<String> this.originalUrls,
    required int this.originalPhotoCount,
  }) : jobId = 'receipt:$receiptId',
       contentSummary = '$originalPhotoCount:${originalUrls.join(',')}',
       onOpenPreview = null;

  final PrintBridge bridge;
  final String jobId;
  final String contentSummary;
  final VoidCallback? onOpenPreview;
  final List<String>? originalUrls;
  final int? originalPhotoCount;

  @override
  State<JobThumbnails> createState() => _JobThumbnailsState();
}

class _JobThumbnailsState extends State<JobThumbnails> {
  late _JobThumbnailCache _cache;
  late _ThumbKey _key;
  _ThumbCacheEntry? _entry;
  String? _error;
  int _attempt = 0;

  _ThumbKey get _widgetKey =>
      (jobId: widget.jobId, contentSummary: widget.contentSummary);

  @override
  void initState() {
    super.initState();
    _useCache(_JobThumbnailCache.forBridge(widget.bridge), _widgetKey);
  }

  @override
  void didUpdateWidget(covariant JobThumbnails oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cache = _JobThumbnailCache.forBridge(widget.bridge);
    if (!identical(_cache, cache) || _key != _widgetKey) {
      _useCache(cache, _widgetKey);
    }
  }

  void _useCache(_JobThumbnailCache cache, _ThumbKey key) {
    _attempt++;
    _cache = cache;
    _key = key;
    _entry = cache.peek(key);
    _error = null;
    if (_entry == null) unawaited(_load());
  }

  Future<void> _load() async {
    final attempt = ++_attempt;
    try {
      final entry = await _cache.load(
        widget.bridge,
        _key,
        originalUrls: widget.originalUrls,
        originalPhotoCount: widget.originalPhotoCount,
      );
      if (!mounted || attempt != _attempt) return;
      setState(() => _entry = entry);
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() => _error = appErrorMessage(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    final openPreview = widget.onOpenPreview;
    if (_error != null && entry == null) {
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (openPreview != null)
            TextButton(onPressed: openPreview, child: const Text('查看照片'))
          else
            const Text('原片缩略图加载失败'),
          IconButton(
            tooltip: '重试缩略图：$_error',
            onPressed: () {
              setState(() => _error = null);
              unawaited(_load());
            },
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ],
      );
    }
    if (entry == null) {
      if (openPreview == null) return const Text('原片缩略图加载中…');
      return TextButton(onPressed: openPreview, child: const Text('图片加载中'));
    }
    if (entry.items.isEmpty) {
      return TextButton(onPressed: openPreview, child: const Text('查看打印预览'));
    }
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: openPreview == null
          ? _tiles(entry)
          : Tooltip(
              message: '查看照片',
              child: TextButton(
                onPressed: openPreview,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  minimumSize: const Size(44, 44),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(6)),
                  ),
                ),
                child: _tiles(entry),
              ),
            ),
    );
  }

  Widget _tiles(_ThumbCacheEntry entry) => Wrap(
    spacing: 4,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final item in entry.items)
        Container(
          width: 36,
          height: 44,
          decoration: BoxDecoration(
            color: WorkstationStyle.bg,
            border: Border.all(color: WorkstationStyle.line),
            borderRadius: BorderRadius.circular(4),
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.memory(
            item.bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            semanticLabel: '${item.label} ×${item.copies}',
          ),
        ),
      if (entry.remaining > 0)
        Text(
          '+${entry.remaining}',
          style: const TextStyle(color: muted, fontSize: 12),
        ),
    ],
  );
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
