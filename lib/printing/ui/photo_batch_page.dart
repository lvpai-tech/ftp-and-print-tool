import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../../ui/app_dialogs.dart';
import '../../ui/design.dart';
import '../job_query_time.dart';
import '../print_bridge.dart';

class PhotoBatchPage extends StatefulWidget {
  const PhotoBatchPage({
    super.key,
    required this.call,
    required this.scenicName,
    this.initialStationId,
  });

  final Future<dynamic> Function(String, List<dynamic>) call;
  final String scenicName;
  final String? initialStationId;

  @override
  State<PhotoBatchPage> createState() => _PhotoBatchPageState();
}

const _batchThumbnailHeight = 84.0;

class _PhotoBatchPageState extends State<PhotoBatchPage> {
  final _selected = <String>{};
  final _requests = <String, String>{};
  List<Json>? _stations;
  List<Json> _batches = [];
  String? _station;
  String? _error;
  DateTime _day = _shanghaiToday();
  bool _loading = true;
  bool _working = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _station = widget.initialStationId;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stations =
          _stations ??
          (await widget.call('listBatchStations', []) as List).cast<Json>();
      if (!mounted) return;
      final station = _station ?? stations.firstOrNull?['id'] as String?;
      setState(() {
        _stations = stations;
        _station = station;
      });
      if (station != null && !stations.any((row) => row['id'] == station)) {
        throw StateError('当前打印景区没有此上传机位，请核对机位和景区设置。');
      }
      final result = station == null
          ? null
          : await widget.call('listPhotoBatches', [
              {
                'stationId': station,
                'from': shanghaiDateTime(_day),
                'to': shanghaiDateTime(_day.add(const Duration(days: 1))),
              },
            ]) as Json;
      if (mounted) {
        setState(() {
          _batches = result == null
              ? []
              : (result['batches'] as List).cast<Json>().reversed.toList();
          _selected.clear();
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = appErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _canDrop(_Dragged photo, Json target) =>
      !_loading &&
      !_working &&
      photo.batch['id'] != target['id'] &&
      target['targetPhotoId'] != null;

  Future<void> _move(_Dragged item, Json target) async {
    if (!_canDrop(item, target)) return;
    setState(() => _working = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认移动照片'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 80, height: 70, child: _thumbnail(item.photo)),
              const SizedBox(height: 10),
              Text('从「${_label(item.batch)}」移出 1 张'),
              Text('移入「${_label(target)}」'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认移动'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await _submit(
          [item.photo],
          {
            'targetPhotoId': target['targetPhotoId'],
            'targetCardId': target['targetCardId'],
          },
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _fill(Json batch) async {
    if (_working || _loading) return;
    final available = _photos(batch).where(_movable).toList();
    final chosen = available
        .where((photo) => _selected.contains(photo['id']))
        .toList();
    final photos = chosen.isEmpty ? available : chosen;
    if (photos.length > 100) {
      await showAppMessage(context, message: '请勾选本次归批的照片，每次最多 100 张。');
      return;
    }
    setState(() => _working = true);
    try {
      final code = await showDialog<String>(
        context: context,
        builder: (_) => _CodeDialog(count: photos.length, time: _time(batch)),
      );
      if (code != null && mounted) await _submit(photos, {'cardCode': code});
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _submit(List<Json> photos, Json fields) async {
    final change = {
      'photos': photos
          .map(
            (photo) => {'photoId': photo['id'], 'revision': photo['revision']},
          )
          .toList(),
      ...fields,
    };
    final key = jsonEncode([_station, change]);
    final requestId = _requests.putIfAbsent(key, () {
      final random = Random.secure();
      return List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    });
    setState(() => _submitting = true);
    try {
      final result = await widget.call('correctPhotoBatch', [
        _station!,
        {'requestId': requestId, ...change},
      ]) as Json;
      final tail = result['cardTail'];
      if (result['requestId'] != requestId ||
          result['assignedCount'] != photos.length ||
          tail is! String ||
          tail.isEmpty) {
        throw StateError('服务返回的矫正结果不完整，请刷新核对。');
      }
      _requests.remove(key);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已将 ${photos.length} 张照片归入取片卡 $tail')),
      );
      await _load();
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          title: '请核对矫正结果',
          message: appErrorMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_loading && !_working;
    final stations = _stations ?? const <Json>[];
    final selectedStation = stations
        .where((row) => row['id'] == _station)
        .firstOrNull;
    return PopScope(
      canPop: !_working,
      child: Scaffold(
        backgroundColor: WorkstationStyle.bg,
        appBar: AppBar(
          backgroundColor: WorkstationStyle.card,
          surfaceTintColor: Colors.transparent,
          title: const Text(
            '照片批次矫正',
            style: TextStyle(
              color: WorkstationStyle.ink,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DecoratedBox(
                decoration: const BoxDecoration(
                  color: WorkstationStyle.card,
                  border: Border(
                    bottom: BorderSide(color: WorkstationStyle.line),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (stations.isNotEmpty)
                        _BatchFilterMenu(
                          tooltip: '选择机位',
                          label: selectedStation == null
                              ? '选择机位'
                              : _stationName(selectedStation),
                          icon: Icons.videocam_outlined,
                          width: 236,
                          enabled: enabled,
                          items: [
                            for (final row in stations)
                              MenuItemButton(
                                onPressed: () {
                                  if (row['id'] == _station) return;
                                  setState(
                                    () => _station = row['id'] as String,
                                  );
                                  _load();
                                },
                                trailingIcon: row['id'] == _station
                                    ? const Icon(Icons.check, size: 16)
                                    : null,
                                child: Text(
                                  _stationName(row),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      _BatchDayMenu(
                        day: _day,
                        enabled: enabled,
                        onChanged: (day) {
                          if (day == _day) return;
                          setState(() => _day = day);
                          _load();
                        },
                      ),
                      IconButton(
                        tooltip: '刷新批次',
                        onPressed: enabled ? _load : null,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(44, 44),
                          foregroundColor: WorkstationStyle.accent,
                          backgroundColor: WorkstationStyle.accentSoft,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                      ),
                      Text(
                        '${widget.scenicName} · 最新批次在前 · 北京时间',
                        style: const TextStyle(
                          color: WorkstationStyle.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_loading || _submitting)
                const LinearProgressIndicator(minHeight: 2),
              Expanded(child: _timeline()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timeline() {
    if (_error case final error?) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _BatchMessage(
            icon: Icons.error_outline,
            color: WorkstationStyle.bad,
            background: WorkstationStyle.badSoft,
            child: SelectableText(error, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    if (_batches.isEmpty) {
      final label = _loading
          ? '正在读取照片批次…'
          : _station == null
          ? '当前景区暂无机位'
          : '当天暂无收图';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _BatchMessage(
            icon: _loading ? Icons.schedule : Icons.photo_library_outlined,
            color: WorkstationStyle.muted,
            background: WorkstationStyle.bg,
            child: Text(label, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= 600 &&
            MediaQuery.textScalerOf(context).scale(16) <= 22;
        final gutter = wide ? 24.0 : 12.0;
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(gutter, 18, gutter, 24),
          itemCount: _batches.length,
          itemBuilder: (context, index) => _timelineItem(index, wide: wide),
        );
      },
    );
  }

  Widget _timelineItem(int index, {required bool wide}) {
    final batch = _batches[index];
    final first = index == 0;
    final last = index == _batches.length - 1;
    final gap = last
        ? -1
        : _received(batch)
              .difference(_received(_photos(_batches[index + 1]).last))
              .inSeconds;
    final timestamp = _BatchTimestamp(wall: _wall(batch), wide: wide);
    return Stack(
      children: [
        if (wide && !(first && last))
          Positioned(
            left: 7,
            top: first ? 21 : 0,
            bottom: last ? null : 0,
            height: last ? 21 : null,
            width: 2,
            child: const ColoredBox(color: WorkstationStyle.line),
          ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DragTarget<_Dragged>(
              onWillAcceptWithDetails: (details) =>
                  _canDrop(details.data, batch),
              onAcceptWithDetails: (details) => _move(details.data, batch),
              builder: (context, hovering, _) {
                final card = _batchCard(batch, hovering.isNotEmpty);
                return wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 116, child: timestamp),
                          Expanded(child: card),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [timestamp, card],
                      );
              },
            ),
            if (!last)
              Padding(
                padding: EdgeInsets.fromLTRB(wide ? 24 : 4, 6, 0, 6),
                child: gap < 0
                    ? const SizedBox(height: 8)
                    : Row(
                        children: [
                          const Icon(
                            Icons.schedule,
                            size: 14,
                            color: WorkstationStyle.muted,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '间隔 ${_gap(gap)}',
                              style: const TextStyle(
                                color: WorkstationStyle.muted,
                                fontSize: 12,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _batchCard(Json batch, bool hovering) {
    final photos = _photos(batch);
    final status = batch['status'];
    final pending =
        status == 'MISSING_END' ||
        status == 'INVALID_END' ||
        status == 'AFTER_END';
    final canFill = pending && photos.any(_movable);
    final canReceive = batch['targetPhotoId'] != null;
    final hasDestination = _batches.any(
      (target) =>
          target['id'] != batch['id'] && target['targetPhotoId'] != null,
    );
    final chosen = photos
        .where((photo) => _selected.contains(photo['id']))
        .length;
    final count = photos.where((photo) => photo['ending'] != true).length;
    final label = switch (status) {
      'MISSING_END' => '缺少结束照',
      'AFTER_END' => '结束照后收图',
      'INVALID_END' => '结束照待核对',
      'REVIEW' => '待复核组',
      _ when photos.any((photo) => photo['manuallyAssigned'] == true) =>
        '已人工调整',
      _ => '自动归批',
    };
    final (statusColor, statusBackground) = switch (status) {
      'MISSING_END' ||
      'AFTER_END' ||
      'INVALID_END' ||
      'REVIEW' => (WorkstationStyle.warn, WorkstationStyle.warnSoft),
      _ when label == '已人工调整' => (
        WorkstationStyle.accent,
        WorkstationStyle.accentSoft,
      ),
      _ => (WorkstationStyle.muted, WorkstationStyle.bg),
    };
    final textScaler = MediaQuery.textScalerOf(context);
    final captionLines = textScaler.scale(11) <= 11 ? 1 : 2;
    final hasEstimatedTime = photos.any(
      (photo) => photo['estimatedReceivedAt'] == true,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: hovering ? WorkstationStyle.accentSoft : WorkstationStyle.card,
        border: Border.all(
          color: hovering
              ? WorkstationStyle.accent
              : pending
              ? const Color(0xffedd7ae)
              : WorkstationStyle.line,
        ),
        borderRadius: BorderRadius.circular(WorkstationStyle.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _label(batch),
                    style: const TextStyle(
                      color: WorkstationStyle.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  StatusTag(
                    label: label,
                    color: statusColor,
                    soft: statusBackground,
                  ),
                  Text(
                    '$count 张游客照',
                    style: const TextStyle(
                      color: WorkstationStyle.muted,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              if (canFill || canReceive || status == 'CARD')
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (canFill)
                      FilledButton.tonal(
                        onPressed: _loading || _working
                            ? null
                            : () => _fill(batch),
                        style: FilledButton.styleFrom(
                          foregroundColor: WorkstationStyle.accent,
                          backgroundColor: WorkstationStyle.accentSoft,
                        ),
                        child: Text(
                          chosen == 0 ? '补录取片码' : '补录取片码（已选 $chosen 张）',
                        ),
                      ),
                    if (canReceive)
                      _BatchCardNote(
                        icon: Icons.move_to_inbox_outlined,
                        label: hovering ? '松开后确认移动' : '可接收游客照',
                        color: WorkstationStyle.accent,
                      )
                    else if (status == 'CARD')
                      _BatchCardNote(
                        icon: Icons.lock_outline,
                        label: batch['targetBlockedReason'] as String,
                        color: WorkstationStyle.muted,
                      ),
                  ],
                ),
            ],
          ),
          const Divider(height: 14, color: WorkstationStyle.line),
          SizedBox(
            height:
                _batchThumbnailHeight +
                8 +
                textScaler.scale(11) * 1.3 * captionLines +
                (hasEstimatedTime ? textScaler.scale(10) * 1.3 : 0),
            child: ListView.separated(
              key: PageStorageKey(batch['id']),
              primary: false,
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, index) => _photoTile(
                photos[index],
                batch,
                canFill,
                hasDestination,
                captionLines,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _photoTile(
    Json photo,
    Json batch,
    bool canFill,
    bool hasDestination,
    int captionLines,
  ) {
    final ending = photo['ending'] == true;
    final time = _time(photo);
    final id = photo['id'] as String;
    final canMove = _movable(photo) && hasDestination && !_working && !_loading;
    final item = (photo: photo, batch: batch);
    final blocked = photo['blockedReason'] as String?;
    final unavailable =
        blocked ?? (!ending && !hasDestination ? '所选日期没有其他可接收批次' : null);
    final tile = SizedBox(
      width: 100,
      child: Column(
        children: [
          SizedBox(
            height: _batchThumbnailHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Material(
                  color: WorkstationStyle.bg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: ending
                          ? WorkstationStyle.accent
                          : WorkstationStyle.line,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    mouseCursor: canMove ? SystemMouseCursors.grab : null,
                    onTap: () => _preview(photo, batch),
                    child: _thumbnail(photo),
                  ),
                ),
                if (!ending && (canMove || unavailable != null))
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: Material(
                      color: WorkstationStyle.card,
                      borderRadius: BorderRadius.circular(6),
                      child: canMove
                          ? IconButton(
                              key: ValueKey('move-photo-$id'),
                              tooltip: '按住拖动 · 单击选择批次',
                              mouseCursor: SystemMouseCursors.grab,
                              onPressed: () => _chooseTarget(item),
                              constraints: const BoxConstraints.tightFor(
                                width: 32,
                                height: 32,
                              ),
                              padding: EdgeInsets.zero,
                              icon: const Icon(
                                Icons.drag_indicator,
                                color: WorkstationStyle.accent,
                                size: 20,
                              ),
                            )
                          : Tooltip(
                              message: unavailable!,
                              child: Padding(
                                padding: const EdgeInsets.all(5),
                                child: Icon(
                                  blocked != null
                                      ? Icons.lock_outline
                                      : Icons.drag_indicator,
                                  color: WorkstationStyle.muted,
                                  size: 16,
                                ),
                              ),
                            ),
                    ),
                  ),
                if (canFill && _movable(photo))
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Material(
                      color: WorkstationStyle.card,
                      borderRadius: BorderRadius.circular(6),
                      child: Tooltip(
                        message: '选择这张照片补码',
                        child: Checkbox(
                          visualDensity: VisualDensity.compact,
                          value: _selected.contains(id),
                          onChanged: _working || _loading
                              ? null
                              : (checked) => setState(() {
                                  if (checked == true) {
                                    _selected.add(id);
                                  } else {
                                    _selected.remove(id);
                                  }
                                }),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            ending ? '结束照 $time' : time,
            textAlign: TextAlign.center,
            maxLines: captionLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1.3,
              fontWeight: ending ? FontWeight.w600 : FontWeight.w400,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: ending ? WorkstationStyle.accent : WorkstationStyle.muted,
            ),
          ),
          if (photo['estimatedReceivedAt'] == true)
            const Text(
              '历史入库时间',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: WorkstationStyle.muted,
                fontSize: 10,
                height: 1.3,
              ),
            ),
        ],
      ),
    );
    if (!canMove) {
      return Tooltip(message: unavailable ?? '照片预览', child: tile);
    }
    return Tooltip(
      message: '按住拖到目标批次 · 单击预览',
      child: Draggable<_Dragged>(
        data: item,
        maxSimultaneousDrags: 1,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          elevation: 3,
          child: SizedBox(width: 68, height: 68, child: _thumbnail(photo)),
        ),
        childWhenDragging: Opacity(opacity: .45, child: tile),
        child: tile,
      ),
    );
  }

  Future<void> _chooseTarget(_Dragged item) async {
    final targets = _batches.where((target) => _canDrop(item, target)).toList();
    if (targets.isEmpty) return;
    final target = await showDialog<Json>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择目标批次'),
        children: [
          for (final target in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, target),
              child: Text('${_label(target)} · ${_wall(target)}'),
            ),
        ],
      ),
    );
    if (target != null && mounted) await _move(item, target);
  }

  Future<void> _preview(Json photo, Json batch) async {
    final item = (photo: photo, batch: batch);
    final targets = _movable(photo)
        ? _batches.where((target) => _canDrop(item, target)).toList()
        : <Json>[];
    final target = await showDialog<Json>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(photo['ending'] == true ? '结束照' : '游客照'),
        content: SizedBox(
          width: 680,
          height: MediaQuery.sizeOf(context).height * .52,
          child: InteractiveViewer(child: _previewImage(photo)),
        ),
        actions: [
          if (targets.isNotEmpty)
            PopupMenuButton<Json>(
              onSelected: (target) => Navigator.pop(context, target),
              itemBuilder: (_) => targets
                  .map(
                    (target) => PopupMenuItem(
                      value: target,
                      child: Text(_label(target)),
                    ),
                  )
                  .toList(),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('移动到…'),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (target != null && mounted) await _move(item, target);
  }
}

class _BatchTimestamp extends StatelessWidget {
  const _BatchTimestamp({required this.wall, required this.wide});

  final String wall;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final time = Text(
      wall.substring(11),
      style: const TextStyle(
        color: WorkstationStyle.ink,
        fontSize: 16,
        height: 1.25,
        fontWeight: FontWeight.w700,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
    final date = Text(
      wall.substring(0, 10),
      style: const TextStyle(
        color: WorkstationStyle.muted,
        fontSize: 11,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
    return Padding(
      padding: wide
          ? const EdgeInsets.only(top: 11, right: 8)
          : const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 16,
            height: 20,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: WorkstationStyle.accent,
                  shape: BoxShape.circle,
                  border: Border.fromBorderSide(
                    BorderSide(color: WorkstationStyle.accentSoft, width: 2),
                  ),
                ),
                child: SizedBox.square(dimension: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: wide
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [time, const SizedBox(height: 2), date],
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [time, date],
                  ),
          ),
        ],
      ),
    );
  }
}

class _BatchCardNote extends StatelessWidget {
  const _BatchCardNote({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: color),
      const SizedBox(width: 6),
      Flexible(
        child: Text(label, style: TextStyle(color: color, fontSize: 12)),
      ),
    ],
  );
}

class _BatchMessage extends StatelessWidget {
  const _BatchMessage({
    required this.icon,
    required this.color,
    required this.background,
    required this.child,
  });

  final IconData icon;
  final Color color;
  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 420),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      decoration: WorkstationStyle.surface(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _BatchDayMenu extends StatefulWidget {
  const _BatchDayMenu({
    required this.day,
    required this.enabled,
    required this.onChanged,
  });

  final DateTime day;
  final bool enabled;
  final ValueChanged<DateTime> onChanged;

  @override
  State<_BatchDayMenu> createState() => _BatchDayMenuState();
}

class _BatchDayMenuState extends State<_BatchDayMenu> {
  static final _firstMonth = DateTime.utc(2024);
  late DateTime _month = DateTime.utc(widget.day.year, widget.day.month);

  @override
  Widget build(BuildContext context) {
    final today = _shanghaiToday();
    final currentMonth = DateTime.utc(today.year, today.month);
    final days = _month == currentMonth
        ? today.day
        : DateTime.utc(_month.year, _month.month + 1, 0).day;
    return _BatchFilterMenu(
      tooltip: '选择收图日期',
      label: _dateLabel(widget.day),
      icon: Icons.calendar_today_outlined,
      width: 176,
      enabled: widget.enabled,
      items: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                tooltip: '上个月',
                onPressed: _month.isAfter(_firstMonth)
                    ? () => _changeMonth(-1)
                    : null,
                icon: const Icon(Icons.chevron_left, size: 20),
              ),
              Text('${_month.year} 年 ${_month.month} 月'),
              IconButton(
                tooltip: '下个月',
                onPressed: _month.isBefore(currentMonth)
                    ? () => _changeMonth(1)
                    : null,
                icon: const Icon(Icons.chevron_right, size: 20),
              ),
            ],
          ),
        ),
        for (var number = days; number >= 1; number--)
          _dayOption(DateTime.utc(_month.year, _month.month, number), today),
      ],
    );
  }

  void _changeMonth(int offset) =>
      setState(() => _month = DateTime.utc(_month.year, _month.month + offset));

  Widget _dayOption(DateTime date, DateTime today) => MenuItemButton(
    key: ValueKey(date),
    onPressed: () => widget.onChanged(date),
    trailingIcon: date == widget.day ? const Icon(Icons.check, size: 16) : null,
    child: Text('${_dateLabel(date)}${date == today ? ' · 今天' : ''}'),
  );
}

class _BatchFilterMenu extends StatefulWidget {
  const _BatchFilterMenu({
    required this.tooltip,
    required this.label,
    required this.icon,
    required this.width,
    required this.enabled,
    required this.items,
  });

  final String tooltip;
  final String label;
  final IconData icon;
  final double width;
  final bool enabled;
  final List<Widget> items;

  @override
  State<_BatchFilterMenu> createState() => _BatchFilterMenuState();
}

class _BatchFilterMenuState extends State<_BatchFilterMenu> {
  final _buttonFocus = FocusNode();

  @override
  void dispose() {
    _buttonFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    childFocusNode: _buttonFocus,
    alignmentOffset: const Offset(0, 4),
    style: MenuStyle(
      alignment: AlignmentDirectional.bottomStart,
      minimumSize: WidgetStatePropertyAll(Size(widget.width, 0)),
      maximumSize: WidgetStatePropertyAll(Size(widget.width, 320)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
    ),
    menuChildren: widget.items,
    builder: (context, controller, child) => SizedBox(
      width: widget.width,
      height: 44,
      child: Tooltip(
        message: widget.tooltip,
        child: OutlinedButton(
          focusNode: _buttonFocus,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            foregroundColor: WorkstationStyle.ink,
            backgroundColor: WorkstationStyle.bg,
            side: const BorderSide(color: WorkstationStyle.line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: !widget.enabled
              ? null
              : () =>
                    controller.isOpen ? controller.close() : controller.open(),
          child: Row(
            children: [
              Icon(widget.icon, size: 17, color: WorkstationStyle.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.label, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down, size: 18),
            ],
          ),
        ),
      ),
    ),
  );
}

class _CodeDialog extends StatefulWidget {
  const _CodeDialog({required this.count, required this.time});
  final int count;
  final String time;

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  String _code = '';

  @override
  Widget build(BuildContext context) {
    final valid = RegExp(r'^(?:[0-9]{4}|[A-Z0-9]{12})$').hasMatch(_code);
    final count = widget.count;
    final time = widget.time;
    return AlertDialog(
      title: const Text('确认补录取片码'),
      content: SizedBox(
        width: 390,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('将 $time 批次的 $count 张游客照归入下方取片卡。'),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '取片码',
                helperText: '4 位卡尾号或 12 位完整取片码',
                border: OutlineInputBorder(),
              ),
              onChanged: (text) =>
                  setState(() => _code = text.trim().toUpperCase()),
              onSubmitted: (_) {
                if (valid) Navigator.pop(context, _code);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, _code) : null,
          child: const Text('确认归批'),
        ),
      ],
    );
  }
}

typedef _Dragged = ({Json photo, Json batch});

DateTime _shanghaiToday() {
  final wall = DateTime.now().toUtc().add(const Duration(hours: 8));
  return DateTime.utc(wall.year, wall.month, wall.day);
}

String _dateLabel(DateTime date) => formatWallClock(date).substring(0, 10);
String _stationName(Json row) => "${row['code']} · ${row['name']}";
List<Json> _photos(Json batch) => (batch['photos'] as List).cast<Json>();
bool _movable(Json photo) =>
    photo['ending'] == false && photo['blockedReason'] == null;
String _label(Json batch) => switch (batch['cardTail']) {
  final String tail => '取片卡 $tail',
  _ => batch['status'] == 'REVIEW' ? '待复核' : '未归批',
};
DateTime _received(Json row) =>
    DateTime.parse(row['receivedAt'] as String).toUtc();
String _wall(Json row) =>
    formatWallClock(_received(row).add(const Duration(hours: 8)));
String _time(Json row) => _wall(row).substring(11);
String _gap(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = seconds ~/ 60 % 60;
  final remainder = seconds % 60;
  return [
    if (hours > 0) '$hours 小时',
    if (minutes > 0) '$minutes 分',
    '$remainder 秒',
  ].join(' ');
}

Widget _thumbnail(Json photo) => Image.network(
  photo['thumbnailUrl'] as String,
  fit: BoxFit.contain,
  cacheWidth: 240,
  errorBuilder: (_, _, _) =>
      const Center(child: Icon(Icons.broken_image_outlined)),
);

Widget _previewImage(Json photo) => Image.network(
  photo['previewUrl'] as String,
  fit: BoxFit.contain,
  frameBuilder: (_, child, frame, synchronouslyLoaded) =>
      frame != null || synchronouslyLoaded
      ? child
      : _previewStatus(photo, '正在加载大图…'),
  errorBuilder: (_, _, _) => _previewStatus(photo, '大图加载失败，请刷新批次后重试'),
);

Widget _previewStatus(Json photo, String message) => Stack(
  fit: StackFit.expand,
  children: [
    _thumbnail(photo),
    Align(
      alignment: Alignment.bottomCenter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: WorkstationStyle.card,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: WorkstationStyle.line),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(message, textAlign: TextAlign.center),
        ),
      ),
    ),
  ],
);
