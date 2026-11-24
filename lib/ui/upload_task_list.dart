import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../auto_upload/folder_uploader.dart';
import '../printing/job_query_time.dart';
import 'app_dialogs.dart';
import 'design.dart';

class UploadTaskList extends StatelessWidget {
  const UploadTaskList({
    super.key,
    required this.folder,
    required this.waiting,
    required this.needingOrder,
    required this.jobs,
    required this.onConfirmNext,
    required this.onReview,
    this.onDiscard,
    this.batchTimeline,
  });

  final String folder;
  final Map<String, String?> waiting;
  final List<String> needingOrder;
  final List<AutoJob> jobs;
  final ValueChanged<String>? onConfirmNext;
  final ValueChanged<AutoJob> onReview;
  final Future<void> Function(String, String?)? onDiscard;
  final Widget? batchTimeline;

  Future<void> _discard(BuildContext context, String source) async {
    final signature = waiting[source];
    final confirmed = await showAppConfirm(
      context,
      title: '移除待上传照片',
      message: '${p.relative(source, from: folder)}\n\n本次不上传这张照片，磁盘原片会保留。',
      action: '移除',
    );
    if (!context.mounted || !confirmed) return;
    try {
      await onDiscard?.call(source, signature);
    } catch (error) {
      if (context.mounted) {
        await showAppMessage(
          context,
          title: '移除失败',
          message: appErrorMessage(error),
        );
      }
    }
  }

  Future<void> _confirm(BuildContext context, String source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认下一张上传的照片'),
        scrollable: true,
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ColoredBox(
                color: WorkstationStyle.bg,
                child: SizedBox(
                  width: double.infinity,
                  height: 204,
                  child: _sourcePhoto(
                    source,
                    signature: waiting[source],
                    cacheWidth: 640,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(p.relative(source, from: folder)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认顺序'),
          ),
        ],
      ),
    );
    if (context.mounted && confirmed == true) onConfirmNext?.call(source);
  }

  @override
  Widget build(BuildContext context) {
    final unordered = needingOrder.toSet();
    final preparing = waiting.keys
        .where((source) => !unordered.contains(source))
        .toList();
    final transferJobs = batchTimeline == null
        ? jobs
        : jobs.where(
            (job) => job.state != 'ingested' && job.state != 'grouped',
          );
    // Group nearby file timestamps for display while preserving queue order.
    final dated = <List<AutoJob>>[];
    for (final job in transferJobs) {
      final stamp = _fileStamp(job.signature);
      final prior = dated.isEmpty
          ? null
          : _fileStamp(dated.last.last.signature);
      if (dated.isEmpty || !_sameTimeGroup(stamp, prior)) dated.add([]);
      dated.last.add(job);
    }
    final waitingSpan = _FileSpan(
      preparing.map((source) => _fileStamp(waiting[source])),
    );
    final orderSpan = _FileSpan(
      needingOrder.map((source) => _fileStamp(waiting[source])),
    );
    final jobSpans = [
      for (final group in dated)
        _FileSpan(group.map((job) => _fileStamp(job.signature))),
    ];
    final empty = waiting.isEmpty && needingOrder.isEmpty && dated.isEmpty;
    final incoming = <Widget>[
      Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            '上传队列',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: WorkstationStyle.ink,
            ),
          ),
          Text(
            empty ? '本机暂无上传任务' : '文件修改时间 · 北京时间',
            style: const TextStyle(color: WorkstationStyle.muted, fontSize: 12),
          ),
        ],
      ),
      const SizedBox(height: 10),
      if (needingOrder.isNotEmpty)
        _TaskGroup(
          key: const ValueKey('order'),
          stamp: orderSpan.latest,
          title: '确认上传顺序',
          note: '同时发现多张照片，请选出下一张',
          count: needingOrder.length,
          attention: true,
          extra: onConfirmNext == null
              ? null
              : DragTarget<String>(
                  onWillAcceptWithDetails: (details) =>
                      unordered.contains(details.data),
                  onAcceptWithDetails: (details) =>
                      _confirm(context, details.data),
                  builder: (context, candidates, _) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: candidates.isEmpty
                          ? WorkstationStyle.warnSoft
                          : WorkstationStyle.accentSoft,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '拖到这里选为下一张',
                      style: TextStyle(
                        color: candidates.isEmpty
                            ? WorkstationStyle.warn
                            : WorkstationStyle.accent,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
          photoBuilder: (_, index) {
            final source = needingOrder[index];
            return _PhotoTile(
              name: p.relative(source, from: folder),
              time: _clock(_fileStamp(waiting[source])),
              photo: _sourcePhoto(source, signature: waiting[source]),
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onConfirmNext != null)
                    Draggable<String>(
                      data: source,
                      maxSimultaneousDrags: 1,
                      feedback: Material(
                        borderRadius: BorderRadius.circular(8),
                        color: WorkstationStyle.bg,
                        child: SizedBox(
                          width: 120,
                          height: 84,
                          child: _sourcePhoto(
                            source,
                            signature: waiting[source],
                          ),
                        ),
                      ),
                      child: const Tooltip(
                        message: '按住拖动选择下一张',
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: ColoredBox(
                            color: WorkstationStyle.card,
                            child: Icon(
                              Icons.drag_indicator,
                              size: 18,
                              color: WorkstationStyle.accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (onDiscard != null)
                    _RemovePhotoButton(
                      onPressed: () => _discard(context, source),
                    ),
                ],
              ),
              caption: const SizedBox.shrink(),
              footer: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: WorkstationStyle.accent,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: onConfirmNext == null
                    ? null
                    : () => _confirm(context, source),
                child: const Text('选为下一张'),
              ),
            );
          },
        ),
      if (needingOrder.isNotEmpty && preparing.isNotEmpty)
        _TimeGap(between: orderSpan.gapTo(waitingSpan)),
      if (preparing.isNotEmpty)
        _TaskGroup(
          key: const ValueKey('preparing'),
          stamp: waitingSpan.latest,
          title: '已发现的照片',
          note: needingOrder.isEmpty ? '等待进入上传队列' : '等待前面的照片确认顺序',
          count: preparing.length,
          photoBuilder: (_, index) {
            final source = preparing[index];
            return _PhotoTile(
              name: p.relative(source, from: folder),
              time: _clock(_fileStamp(waiting[source])),
              photo: _sourcePhoto(source, signature: waiting[source]),
              action: onDiscard == null
                  ? null
                  : _RemovePhotoButton(
                      onPressed: () => _discard(context, source),
                    ),
              caption: const _TileStatus(
                label: '待准备',
                color: WorkstationStyle.muted,
                background: WorkstationStyle.bg,
              ),
            );
          },
        ),
    ];
    return SliverMainAxisGroup(
      slivers: [
        SliverList.list(children: incoming),
        SliverList.builder(
          itemCount: dated.length,
          itemBuilder: (context, group) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TimeGap(
                between:
                    (group > 0
                            ? jobSpans[group - 1]
                            : preparing.isNotEmpty
                            ? waitingSpan
                            : orderSpan)
                        .gapTo(jobSpans[group]),
              ),
              _TaskGroup(
                key: ObjectKey(dated[group].last),
                stamp: jobSpans[group].latest,
                title: '上传任务',
                note: '最近入队在前',
                count: dated[group].length,
                photoBuilder: (context, index) {
                  final job = dated[group][index];
                  return _JobPhoto(
                    key: ValueKey(job.id),
                    job: job,
                    onReview: () => onReview(job),
                  );
                },
              ),
            ],
          ),
        ),
        if (batchTimeline != null)
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ?batchTimeline,
      ],
    );
  }
}

DateTime? _fileStamp(String? signature) {
  if (signature == null) return null;
  final separator = signature.lastIndexOf(':');
  if (separator < 0) return null;
  final micros = int.tryParse(signature.substring(separator + 1));
  if (micros == null || micros.abs() > 8640000000000000000) return null;
  return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
}

DateTime _beijing(DateTime stamp) => stamp.add(const Duration(hours: 8));
String? _clock(DateTime? stamp) =>
    stamp == null ? null : formatWallClock(_beijing(stamp)).split(' ').last;

bool _sameTimeGroup(DateTime? stamp, DateTime? previous) {
  if (stamp == null || previous == null) return stamp == previous;
  return DateUtils.isSameDay(_beijing(stamp), _beijing(previous)) &&
      stamp.difference(previous).abs() < const Duration(minutes: 1);
}

class _FileSpan {
  _FileSpan(Iterable<DateTime?> stamps) {
    for (final stamp in stamps.nonNulls) {
      if (earliest == null || stamp.isBefore(earliest!)) earliest = stamp;
      if (latest == null || stamp.isAfter(latest!)) latest = stamp;
    }
  }

  DateTime? earliest, latest;

  Duration? gapTo(_FileSpan next) {
    if (earliest == null || next.earliest == null) return null;
    if (earliest!.isAfter(next.latest!)) {
      return earliest!.difference(next.latest!);
    }
    if (next.earliest!.isAfter(latest!)) {
      return next.earliest!.difference(latest!);
    }
    return null;
  }
}

class _TimeGap extends StatelessWidget {
  const _TimeGap({required this.between});
  final Duration? between;

  @override
  Widget build(BuildContext context) {
    final gap = between;
    if (gap == null || gap.inSeconds < 1) return const SizedBox.shrink();
    final days = gap.inDays;
    final hours = gap.inHours % 24;
    final minutes = gap.inMinutes % 60;
    final seconds = gap.inSeconds % 60;
    final parts = [
      if (days > 0) '$days 天',
      if (hours > 0) '$hours 小时',
      if (minutes > 0) '$minutes 分',
      '$seconds 秒',
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 15, bottom: 9),
      child: Row(
        children: [
          const Icon(Icons.schedule, size: 14, color: WorkstationStyle.muted),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              '间隔 ${parts.join(' ')}',
              style: const TextStyle(
                color: WorkstationStyle.muted,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskGroup extends StatelessWidget {
  const _TaskGroup({
    super.key,
    required this.stamp,
    required this.title,
    required this.note,
    required this.count,
    required this.photoBuilder,
    this.attention = false,
    this.extra,
  });

  final DateTime? stamp;
  final String title, note;
  final int count;
  final IndexedWidgetBuilder photoBuilder;
  final bool attention;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final color = attention ? WorkstationStyle.warn : WorkstationStyle.accent;
    final wall = stamp == null
        ? null
        : formatWallClock(_beijing(stamp!)).split(' ');
    final markerLabel = Padding(
      padding: const EdgeInsets.only(top: 11, bottom: 8, right: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: 8),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: const SizedBox.square(dimension: 8),
            ),
          ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  wall?.last ?? '时间未知',
                  style: const TextStyle(
                    color: WorkstationStyle.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (wall != null)
                  Text(
                    wall.first,
                    style: const TextStyle(
                      color: WorkstationStyle.muted,
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: WorkstationStyle.card,
        borderRadius: BorderRadius.circular(WorkstationStyle.radius),
        border: Border.all(
          color: attention
              ? color.withValues(alpha: .35)
              : WorkstationStyle.line,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: WorkstationStyle.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                ?extra,
                StatusTag(
                  label: '$count 张',
                  color: attention ? color : WorkstationStyle.muted,
                  soft: attention
                      ? WorkstationStyle.warnSoft
                      : WorkstationStyle.bg,
                ),
                Text(
                  note,
                  style: const TextStyle(
                    color: WorkstationStyle.muted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const Divider(height: 16, color: WorkstationStyle.line),
            _PhotoStrip(
              count: count,
              photoBuilder: photoBuilder,
              hasAction: attention,
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final markerWidth = MediaQuery.textScalerOf(context).scale(108);
          if (constraints.maxWidth - markerWidth >= 400) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: markerWidth, child: markerLabel),
                Expanded(child: card),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [markerLabel, card],
          );
        },
      ),
    );
  }
}

class _PhotoStrip extends StatefulWidget {
  const _PhotoStrip({
    required this.count,
    required this.photoBuilder,
    required this.hasAction,
  });

  final int count;
  final IndexedWidgetBuilder photoBuilder;
  final bool hasAction;

  @override
  State<_PhotoStrip> createState() => _PhotoStripState();
}

class _PhotoStripState extends State<_PhotoStrip> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    const gap = 10.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = scaler
            .scale(146)
            .clamp(146.0, constraints.maxWidth.clamp(146.0, 240.0));
        final overflow =
            widget.count * (width + gap) - gap > constraints.maxWidth;
        final textHeight = scaler.scale(widget.hasAction ? 103 : 84);
        return SizedBox(
          height: 84 + textHeight + (overflow ? 12 : 0),
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: overflow,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context)
                  .copyWith(scrollbars: false),
              child: ListView.separated(
                controller: _scroll,
                primary: false,
                scrollDirection: Axis.horizontal,
                itemCount: widget.count,
                padding: EdgeInsets.only(bottom: overflow ? 12 : 0),
                itemBuilder: (context, index) => SizedBox(
                  width: width,
                  child: widget.photoBuilder(context, index),
                ),
                separatorBuilder: (context, index) =>
                    const SizedBox(width: gap),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.name,
    required this.photo,
    required this.caption,
    this.footer,
    this.action,
    this.time,
  });

  final String name;
  final Widget photo, caption;
  final Widget? footer, action;
  final String? time;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 84,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: WorkstationStyle.bg,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: WorkstationStyle.line),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              photo,
              if (action case final action?)
                Positioned(right: 3, bottom: 3, child: action),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Tooltip(
          message: name,
          child: Text(
            p.basename(name),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: WorkstationStyle.ink,
              fontSize: 12,
              height: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 4),
        if (time case final time?)
          Text(
            time,
            style: const TextStyle(
              color: WorkstationStyle.muted,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        caption,
        ?footer,
      ],
    );
  }
}

class _RemovePhotoButton extends StatelessWidget {
  const _RemovePhotoButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '从上传队列移除',
    icon: const Icon(Icons.delete_outline, size: 18),
    style: IconButton.styleFrom(
      backgroundColor: WorkstationStyle.card,
      foregroundColor: WorkstationStyle.muted,
      minimumSize: const Size.square(34),
      padding: const EdgeInsets.all(7),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    onPressed: onPressed,
  );
}

class _TileStatus extends StatelessWidget {
  const _TileStatus({
    required this.label,
    required this.color,
    required this.background,
    this.detail = '',
  });

  final String label, detail;
  final Color color, background;

  @override
  Widget build(BuildContext context) {
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    return detail.isEmpty ? tag : Tooltip(message: detail, child: tag);
  }
}

class _JobPhoto extends StatefulWidget {
  const _JobPhoto({super.key, required this.job, required this.onReview});

  final AutoJob job;
  final VoidCallback onReview;

  @override
  State<_JobPhoto> createState() => _JobPhotoState();
}

class _JobPhotoState extends State<_JobPhoto> {
  Future<Uint8List?>? _normalizedPreview;

  Widget _fallbackPreview(AutoJob job) {
    if (!job.normalized) return _sourcePhoto(job.source);
    return FutureBuilder<Uint8List?>(
      future: _normalizedPreview ??= job.readNormalizedThumbnail(),
      builder: (context, snapshot) => snapshot.hasData
          ? Image.memory(
              snapshot.data!,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => _photoPlaceholder,
            )
          : _photoPlaceholder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final (label, color, background) = switch (job.state) {
      'done' => ('上传成功', WorkstationStyle.ok, WorkstationStyle.okSoft),
      'grouped' => ('已归卡', WorkstationStyle.ok, WorkstationStyle.okSoft),
      'accepted' => (
        '已上传 · 等待入库',
        WorkstationStyle.warn,
        WorkstationStyle.warnSoft,
      ),
      'ingested' => (
        '已入库 · 等待归卡',
        WorkstationStyle.warn,
        WorkstationStyle.warnSoft,
      ),
      'uploading' => (
        '上传中 ${(job.progress * 100).round()}%',
        WorkstationStyle.accent,
        WorkstationStyle.accentSoft,
      ),
      'failed' => ('上传失败', WorkstationStyle.bad, WorkstationStyle.badSoft),
      _ => (
        job.attempts == 0 ? '等待上传' : '等待重试（${job.attempts}/3）',
        WorkstationStyle.warn,
        WorkstationStyle.warnSoft,
      ),
    };
    return _PhotoTile(
      name: job.relative,
      time: _clock(_fileStamp(job.signature)),
      photo: Image.file(
        File(job.snapshot),
        fit: BoxFit.contain,
        cacheWidth: 240,
        errorBuilder: (context, error, stackTrace) => _fallbackPreview(job),
      ),
      action: IconButton(
        tooltip: '识别取片卡尾号',
        style: IconButton.styleFrom(
          backgroundColor: WorkstationStyle.card,
          foregroundColor: WorkstationStyle.muted,
          minimumSize: const Size.square(34),
          padding: const EdgeInsets.all(7),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: widget.onReview,
        icon: const Icon(Icons.document_scanner_outlined, size: 18),
      ),
      caption: _TileStatus(
        label: label,
        color: color,
        background: background,
        detail: job.error,
      ),
      footer: job.state == 'uploading'
          ? Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: job.progress,
                minHeight: 3,
                backgroundColor: WorkstationStyle.accentSoft,
                color: WorkstationStyle.accent,
              ),
            )
          : null,
    );
  }
}

const _photoPlaceholder = Icon(
  Icons.photo_outlined,
  color: WorkstationStyle.muted,
);

Widget _sourcePhoto(String path, {String? signature, int cacheWidth = 240}) =>
    Image(
      image: ResizeImage(
        _SourceImage(File(path), signature),
        width: cacheWidth,
      ),
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => _photoPlaceholder,
    );

// A camera may still be writing a file when the first preview is built.
class _SourceImage extends FileImage {
  const _SourceImage(super.file, this.signature);

  final String? signature;

  @override
  bool operator ==(Object other) =>
      other is _SourceImage && super == other && signature == other.signature;

  @override
  int get hashCode => Object.hash(super.hashCode, signature);
}
