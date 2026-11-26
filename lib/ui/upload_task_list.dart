import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../auto_upload/folder_uploader.dart';
import '../printing/job_query_time.dart';
import 'app_dialogs.dart';
import 'design.dart';
import 'workstation_form_dialog.dart';

const _thumbnailHeight = 100.0;
const _thumbnailWidth = 136.0;

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
      builder: (context) => WorkstationFormDialog(
        title: '确认下一张上传的照片',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
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
            Text(p.relative(source, from: folder)),
          ],
        ),
        actions: [
          OutlinedButton(
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

  Widget _waitingPhoto(
    BuildContext context,
    String source, {
    required bool needsOrder,
  }) {
    final name = p.relative(source, from: folder);
    final signature = waiting[source];
    final canConfirm = needsOrder && onConfirmNext != null;
    return _PhotoTile(
      key: ValueKey(source),
      name: name,
      time: _clock(_fileStamp(signature)),
      photo: _sourcePhoto(source, signature: signature),
      dragSource: canConfirm ? source : null,
      onPreview: () => _showPhotoPreview(
        context,
        name: name,
        photo: _sourcePhoto(
          source,
          signature: signature,
          cacheWidth: 1440,
          unavailable: const Center(child: Text('无法读取本机照片')),
        ),
      ),
      actions: [
        if (canConfirm)
          (
            label: '选为下一张',
            icon: Icons.start,
            color: null,
            run: () => _confirm(context, source),
          ),
        if (onDiscard != null)
          (
            label: '从上传队列移除',
            icon: Icons.delete_outline,
            color: WorkstationStyle.bad,
            run: () => _discard(context, source),
          ),
      ],
      caption: const _TileStatus(
        label: '待准备',
        color: WorkstationStyle.muted,
        background: WorkstationStyle.bg,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final timeline = batchTimeline;
    if (timeline == null) return _queue(context);

    return DefaultTabController(
      length: 2,
      child: Builder(
        builder: (context) {
          final controller = DefaultTabController.of(context);
          return SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Material(
                    color: WorkstationStyle.card,
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      labelColor: WorkstationStyle.accent,
                      unselectedLabelColor: WorkstationStyle.muted,
                      indicatorColor: WorkstationStyle.accent,
                      dividerColor: WorkstationStyle.line,
                      tabs: [
                        const Tab(text: '照片批次'),
                        Tab(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 8,
                            children: [
                              const Text('本机上传'),
                              if (needingOrder.isNotEmpty)
                                const StatusTag(
                                  label: '待确认顺序',
                                  color: WorkstationStyle.warn,
                                  soft: WorkstationStyle.warnSoft,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final showQueue = controller.index == 1;
                  return SliverMainAxisGroup(
                    slivers: [
                      SliverOffstage(
                        offstage: showQueue,
                        sliver: ExcludeFocus(
                          excluding: showQueue,
                          child: TickerMode(
                            enabled: !showQueue,
                            child: timeline,
                          ),
                        ),
                      ),
                      if (showQueue) _queue(context),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _queue(BuildContext context) {
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
          if (batchTimeline == null)
            const Text(
              '上传队列',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: WorkstationStyle.ink,
              ),
            ),
          if (!empty)
            const Text(
              '文件修改时间 · 北京时间',
              style: TextStyle(color: WorkstationStyle.muted, fontSize: 12),
            ),
        ],
      ),
      const SizedBox(height: 10),
      if (empty)
        const Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            spacing: 8,
            children: [
              Icon(Icons.photo_library_outlined, color: WorkstationStyle.muted),
              Text('本机暂无上传任务', style: TextStyle(color: WorkstationStyle.muted)),
            ],
          ),
        ),
      if (needingOrder.isNotEmpty)
        _TaskGroup(
          key: const ValueKey('order'),
          stamp: orderSpan.latest,
          title: '确认上传顺序',
          note: onConfirmNext == null
              ? '同时发现多张照片，请选出下一张'
              : '将下一张照片拖到这里，或从照片菜单选择',
          count: needingOrder.length,
          attention: true,
          onDrop: onConfirmNext == null
              ? null
              : (source) => _confirm(context, source),
          dropSources: unordered,
          photoBuilder: (context, index) =>
              _waitingPhoto(context, needingOrder[index], needsOrder: true),
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
          photoBuilder: (context, index) =>
              _waitingPhoto(context, preparing[index], needsOrder: false),
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
    this.onDrop,
    this.dropSources = const {},
  });

  final DateTime? stamp;
  final String title, note;
  final int count;
  final IndexedWidgetBuilder photoBuilder;
  final bool attention;
  final ValueChanged<String>? onDrop;
  final Set<String> dropSources;
  static const _noteStyle = TextStyle(
    color: WorkstationStyle.muted,
    fontSize: 12,
  );

  Widget _header(Color color, {bool hovering = false}) => DecoratedBox(
    decoration: BoxDecoration(
      color: hovering ? WorkstationStyle.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
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
          StatusTag(
            label: '$count 张',
            color: attention ? color : WorkstationStyle.muted,
            soft: attention ? WorkstationStyle.warnSoft : WorkstationStyle.bg,
          ),
          if (onDrop != null)
            IndexedStack(
              index: hovering ? 1 : 0,
              alignment: Alignment.centerLeft,
              children: [
                Text(note, style: _noteStyle),
                Text(
                  '松开后确认上传顺序',
                  style: _noteStyle.copyWith(color: WorkstationStyle.accent),
                ),
              ],
            )
          else
            Text(note, style: _noteStyle),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final color = attention ? WorkstationStyle.warn : WorkstationStyle.accent;
    final wall = stamp == null
        ? null
        : formatWallClock(_beijing(stamp!)).split(' ');
    Widget marker(bool wide) => Padding(
      padding: wide
          ? const EdgeInsets.only(top: 11, right: 8)
          : const EdgeInsets.only(bottom: 6),
      child: Row(
        spacing: 8,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            height: 20,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: attention
                        ? WorkstationStyle.warnSoft
                        : WorkstationStyle.accentSoft,
                    width: 2,
                  ),
                ),
                child: const SizedBox.square(dimension: 12),
              ),
            ),
          ),
          Flexible(
            child: Wrap(
              direction: wide ? Axis.vertical : Axis.horizontal,
              spacing: wide ? 2 : 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
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
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (onDrop case final onDrop?)
              DragTarget<String>(
                onWillAcceptWithDetails: (details) =>
                    dropSources.contains(details.data),
                onAcceptWithDetails: (details) => onDrop(details.data),
                builder: (context, candidates, _) =>
                    _header(color, hovering: candidates.isNotEmpty),
              )
            else
              _header(color),
            const Divider(height: 14, color: WorkstationStyle.line),
            _PhotoStrip(count: count, photoBuilder: photoBuilder),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 600 &&
              MediaQuery.textScalerOf(context).scale(16) <= 22) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 116, child: marker(true)),
                Expanded(child: card),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [marker(false), card],
          );
        },
      ),
    );
  }
}

class _PhotoStrip extends StatefulWidget {
  const _PhotoStrip({required this.count, required this.photoBuilder});

  final int count;
  final IndexedWidgetBuilder photoBuilder;

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
            .scale(_thumbnailWidth)
            .clamp(
              _thumbnailWidth,
              constraints.maxWidth.clamp(_thumbnailWidth, 240.0),
            );
        final overflow =
            widget.count * (width + gap) - gap > constraints.maxWidth;
        final textHeight = scaler.scale(65);
        return SizedBox(
          height: _thumbnailHeight + textHeight + (overflow ? 12 : 0),
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

typedef _PhotoAction = ({
  String label,
  IconData icon,
  Color? color,
  VoidCallback run,
});

Future<void> _showPhotoPreview(
  BuildContext context, {
  required String name,
  required Widget photo,
}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('照片预览'),
    content: SizedBox(
      width: 680,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          SizedBox(
            width: double.infinity,
            height: MediaQuery.sizeOf(context).height * .52,
            child: InteractiveViewer(child: photo),
          ),
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  ),
);

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    super.key,
    required this.name,
    required this.photo,
    required this.onPreview,
    required this.actions,
    required this.caption,
    this.footer,
    this.dragSource,
    this.time,
  });

  final String name;
  final Widget photo, caption;
  final VoidCallback onPreview;
  final List<_PhotoAction> actions;
  final Widget? footer;
  final String? dragSource, time;

  @override
  Widget build(BuildContext context) {
    Widget preview({bool dragging = false}) => Material(
      color: WorkstationStyle.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: WorkstationStyle.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        mouseCursor: dragSource == null
            ? null
            : dragging
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.grab,
        onTap: onPreview,
        child: photo,
      ),
    );
    return Column(
      children: [
        SizedBox(
          height: _thumbnailHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (dragSource case final source?)
                Draggable<String>(
                  data: source,
                  maxSimultaneousDrags: 1,
                  affinity: Axis.vertical,
                  dragAnchorStrategy: pointerDragAnchorStrategy,
                  feedback: Material(
                    elevation: 3,
                    child: SizedBox.square(dimension: 68, child: photo),
                  ),
                  childWhenDragging: Opacity(
                    opacity: .45,
                    child: preview(dragging: true),
                  ),
                  child: preview(),
                )
              else
                preview(),
              Positioned(
                right: 4,
                top: 4,
                child: Material(
                  color: WorkstationStyle.card,
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox.square(
                    dimension: 34,
                    child: PopupMenuButton<_PhotoAction>(
                      tooltip: '照片操作',
                      icon: const Icon(Icons.more_vert, size: 20),
                      padding: EdgeInsets.zero,
                      position: PopupMenuPosition.under,
                      onSelected: (action) => action.run(),
                      itemBuilder: (_) => [
                        for (final action in [
                          ...actions,
                          (
                            label: '查看图片',
                            icon: Icons.image_outlined,
                            color: null,
                            run: onPreview,
                          ),
                        ])
                          PopupMenuItem(
                            value: action,
                            child: Row(
                              spacing: 10,
                              children: [
                                Icon(
                                  action.icon,
                                  size: 17,
                                  color: action.color,
                                ),
                                Text(
                                  action.label,
                                  style: TextStyle(color: action.color),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Tooltip(
          message: name,
          child: Text(
            p.basename(name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: WorkstationStyle.ink,
              fontSize: 12,
              height: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
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
      onPreview: () => _showPhotoPreview(
        context,
        name: job.relative,
        photo: FutureBuilder<Uint8List>(
          future: job.readPhotoForReview(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text(appErrorMessage(snapshot.error!)));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Center(child: Text('无法读取本机照片')),
            );
          },
        ),
      ),
      actions: [
        (
          label: '识别取片卡尾号',
          icon: Icons.document_scanner_outlined,
          color: null,
          run: widget.onReview,
        ),
      ],
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

Widget _sourcePhoto(
  String path, {
  String? signature,
  int cacheWidth = 240,
  Widget unavailable = _photoPlaceholder,
}) => Image(
  image: ResizeImage(_SourceImage(File(path), signature), width: cacheWidth),
  fit: BoxFit.contain,
  errorBuilder: (context, error, stackTrace) => unavailable,
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
