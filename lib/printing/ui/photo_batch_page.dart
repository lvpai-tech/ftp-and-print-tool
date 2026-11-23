import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../ui/app_dialogs.dart';
import '../../ui/card_tail_dialog.dart';
import '../../ui/design.dart';
import '../job_query_time.dart';
import '../print_bridge.dart';

enum _PhotoAction {
  recognize('识别取片码', Icons.document_scanner_outlined),
  remove('删除照片', Icons.delete_outline),
  capture('查询拍摄信息', Icons.info_outline),
  preview('查看图片', Icons.image_outlined);

  const _PhotoAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

class PhotoBatchPage extends StatelessWidget {
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
  Widget build(BuildContext context) => Scaffold(
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
      child: PhotoBatchTimeline._(
        call: call,
        scenicName: scenicName,
        initialStationId: initialStationId,
      ),
    ),
  );
}

class PhotoBatchTimeline extends StatefulWidget {
  const PhotoBatchTimeline._({
    required this.call,
    required this.scenicName,
    this.initialStationId,
  }) : inline = false;

  const PhotoBatchTimeline.inline({
    super.key,
    required this.call,
    required this.scenicName,
    required String stationId,
  }) : inline = true,
       initialStationId = stationId;

  final Future<dynamic> Function(String, List<dynamic>) call;
  final String scenicName;
  final String? initialStationId;
  final bool inline;

  @override
  State<PhotoBatchTimeline> createState() => _PhotoBatchTimelineState();
}

const _batchThumbnailHeight = 84.0;

class _PhotoBatchTimelineState extends State<PhotoBatchTimeline> {
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

  List<Json> _photosToFill(Json batch, {String? cardPhotoId}) {
    final available = _photos(batch).where(_movable).toList();
    final chosen = available
        .where((photo) => _selected.contains(photo['id']))
        .toList();
    return (chosen.isEmpty ? available : chosen)
        .where((photo) => photo['id'] != cardPhotoId)
        .toList();
  }

  Future<void> _fill(
    Json batch, {
    String? candidate,
    String? cardPhotoId,
  }) async {
    if (_working || _loading) return;
    final photos = _photosToFill(batch, cardPhotoId: cardPhotoId);
    if (photos.isEmpty) {
      await showAppMessage(context, message: '请至少选择一张游客照，卡面照片不会随本次补录归批。');
      return;
    }
    if (photos.length > 100) {
      await showAppMessage(context, message: '请勾选本次归批的照片，每次最多 100 张。');
      return;
    }
    setState(() => _working = true);
    try {
      final code = await showDialog<String>(
        context: context,
        builder: (_) => _CodeDialog(
          count: photos.length,
          time: _time(batch),
          candidate: candidate,
        ),
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
    final requestId = _requestId(key);
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

  String _requestId(String key) => _requests.putIfAbsent(key, () {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  });

  Future<void> _removePhoto(Json photo) async {
    if (_loading || _working) return;
    final blocked = photo['removalBlockedReason'];
    if (photo['ending'] == true || blocked != '') {
      await showAppMessage(
        context,
        title: '无法删除照片',
        message: blocked is String && blocked.isNotEmpty
            ? blocked
            : photo['ending'] == true
            ? '结束照和卡片素材仅供核对。'
            : '当前照片不支持删除，请刷新后核对。',
      );
      return;
    }
    setState(() => _working = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除这张照片？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              SizedBox(width: 120, height: 96, child: _thumbnail(photo)),
              const Text('照片将从批次和游客取片列表移除，系统会保留原图与操作记录。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: WorkstationStyle.bad,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final photoId = photo['id'] as String;
      final revision = photo['revision'];
      final key = jsonEncode(['remove', _station, photoId, revision]);
      final requestId = _requestId(key);
      setState(() => _submitting = true);
      final result = await widget.call('removeBatchPhoto', [
        _station!,
        photoId,
        {'requestId': requestId, 'revision': revision},
      ]) as Json;
      if (result['requestId'] != requestId || result['photoId'] != photoId) {
        throw StateError('删除结果未确认，请刷新核对。');
      }
      _requests.remove(key);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已删除 1 张照片')));
      await _load();
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          title: '无法确认删除结果',
          message: appErrorMessage(error),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _submitting = false;
        });
      }
    }
  }

  Future<void> _recognizeTail(Json photo, Json batch) async {
    final cardPhotoId = photo['id'] as String;
    final canFill =
        _unassigned(batch) &&
        _photosToFill(batch, cardPhotoId: cardPhotoId).isNotEmpty;
    final candidate = await showCardTailDialog(
      context,
      readPhoto: () => _readBatchPhoto(photo),
      guidance: '条形码拍不全时，请框住卡面印刷的四位数字。',
      allowUse: canFill,
    );
    if (candidate != null && mounted) {
      await _fill(batch, candidate: candidate, cardPhotoId: cardPhotoId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_loading && !_working;
    final stations = _stations ?? const <Json>[];
    final selectedStation = stations
        .where((row) => row['id'] == _station)
        .firstOrNull;
    final controls = DecoratedBox(
      decoration: const BoxDecoration(
        color: WorkstationStyle.card,
        border: Border(bottom: BorderSide(color: WorkstationStyle.line)),
      ),
      child: Padding(
        padding: widget.inline
            ? const EdgeInsets.only(bottom: 10)
            : const EdgeInsets.fromLTRB(20, 4, 20, 14),
        child: Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (widget.inline)
              const Text(
                '照片批次矫正',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: WorkstationStyle.ink,
                ),
              ),
            if (!widget.inline && stations.isNotEmpty)
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
                        setState(() => _station = row['id'] as String);
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
              [
                widget.scenicName,
                if (widget.inline && selectedStation != null)
                  _stationName(selectedStation),
                '最新批次在前',
                '北京时间',
              ].join(' · '),
              style: const TextStyle(
                color: WorkstationStyle.muted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        controls,
        if (_loading || _submitting)
          const LinearProgressIndicator(minHeight: 2),
      ],
    );
    final timeline = _timeline();
    return PopScope(
      canPop: !_working,
      child: widget.inline
          ? SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(child: header),
                timeline,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Expanded(child: CustomScrollView(slivers: [timeline])),
              ],
            ),
    );
  }

  Widget _timeline() {
    if (_error case final error?) {
      return _timelineMessage(
        Padding(
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
      return _timelineMessage(
        Padding(
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
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.crossAxisExtent >= 600 &&
            MediaQuery.textScalerOf(context).scale(16) <= 22;
        final gutter = wide ? 24.0 : 12.0;
        return SliverPadding(
          padding: widget.inline
              ? const EdgeInsets.fromLTRB(0, 12, 0, 16)
              : EdgeInsets.fromLTRB(gutter, 18, gutter, 24),
          sliver: SliverList.builder(
            itemCount: _batches.length,
            itemBuilder: (context, index) => _timelineItem(index, wide: wide),
          ),
        );
      },
    );
  }

  Widget _timelineMessage(Widget message) => widget.inline
      ? SliverToBoxAdapter(child: Center(child: message))
      : SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: message),
        );

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
    final pending = _unassigned(batch);
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
    final preview = Stack(
      fit: StackFit.expand,
      children: [
        Material(
          color: WorkstationStyle.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: ending ? WorkstationStyle.accent : WorkstationStyle.line,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            mouseCursor: canMove ? SystemMouseCursors.grab : null,
            onTap: () => _preview(photo),
            child: _thumbnail(photo),
          ),
        ),
        if (!ending && (canMove || unavailable != null))
          Positioned(
            left: 4,
            top: 4,
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
      ],
    );
    return SizedBox(
      width: 100,
      child: Column(
        children: [
          SizedBox(
            height: _batchThumbnailHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (canMove)
                  Draggable<_Dragged>(
                    data: item,
                    maxSimultaneousDrags: 1,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    feedback: Material(
                      elevation: 3,
                      child: SizedBox(
                        width: 68,
                        height: 68,
                        child: _thumbnail(photo),
                      ),
                    ),
                    childWhenDragging: Opacity(opacity: .45, child: preview),
                    child: preview,
                  )
                else
                  preview,
                Positioned(
                  right: 4,
                  top: 4,
                  child: Material(
                    color: WorkstationStyle.card,
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox.square(
                      dimension: 34,
                      child: PopupMenuButton<_PhotoAction>(
                        key: ValueKey('photo-actions-$id'),
                        tooltip: '照片操作',
                        icon: const Icon(Icons.more_vert, size: 20),
                        padding: EdgeInsets.zero,
                        position: PopupMenuPosition.under,
                        enabled: !_working && !_loading,
                        onSelected: (action) =>
                            _runPhotoAction(action, photo, batch),
                        itemBuilder: (_) => [
                          for (final action in _PhotoAction.values)
                            PopupMenuItem(
                              value: action,
                              child: Row(
                                spacing: 10,
                                children: [
                                  Icon(
                                    action.icon,
                                    size: 17,
                                    color: action == _PhotoAction.remove
                                        ? WorkstationStyle.bad
                                        : null,
                                  ),
                                  Text(
                                    action.label,
                                    style: TextStyle(
                                      color: action == _PhotoAction.remove
                                          ? WorkstationStyle.bad
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (canFill && _movable(photo))
                  Positioned(
                    right: 4,
                    bottom: 4,
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

  Future<void> _runPhotoAction(
    _PhotoAction action,
    Json photo,
    Json batch,
  ) async {
    switch (action) {
      case _PhotoAction.recognize:
        if (photo['previewUrl'] is! String || photo['previewUrl'] == '') {
          await showAppMessage(
            context,
            title: action.label,
            message: '当前照片没有可用于识别的大图。',
          );
          return;
        }
        await _recognizeTail(photo, batch);
      case _PhotoAction.remove:
        await _removePhoto(photo);
      case _PhotoAction.capture:
        await _showCapture(photo);
      case _PhotoAction.preview:
        await _preview(photo);
    }
  }

  Future<void> _showCapture(Json photo) async {
    final station = _station;
    if (station == null) return;
    final capture = widget.call('getBatchPhotoCapture', [station, photo['id']]);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_PhotoAction.capture.label),
        content: SizedBox(
          width: 360,
          child: FutureBuilder<dynamic>(
            future: capture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Text('正在读取拍摄信息…');
              }
              if (snapshot.hasError) {
                return Text('拍摄信息暂不可用：${appErrorMessage(snapshot.error!)}');
              }
              final data = snapshot.data;
              if (data is! Json || data['collected'] is! bool) {
                return const Text('拍摄信息响应不完整，请关闭后重试。');
              }
              if (data['collected'] == false) {
                return const Text('这张照片尚未采集 EXIF 作者与相机信息。');
              }
              final artist = [
                data['artist'],
                data['conflictingArtist'],
              ].whereType<String>().join(' / ');
              final camera = [
                data['cameraMake'],
                data['cameraModel'],
              ].whereType<String>().join(' ');
              final photographer = data['photographer'];
              final source = data['assignmentSource'] == 'MANUAL'
                  ? '人工'
                  : 'EXIF';
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 10,
                children: [
                  Text(
                    '作者  ${artist.isNotEmpty
                        ? artist
                        : data['reviewReason'] == 'ARTIST_UNAVAILABLE'
                        ? '无法读取'
                        : '未读到'}',
                  ),
                  Text('相机  ${camera.isNotEmpty ? camera : '未知'}'),
                  Text(
                    '摄影师  ${photographer == null ? '待确认' : '$photographer（$source）'}',
                  ),
                ],
              );
            },
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
  }

  Future<void> _preview(Json photo) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(photo['ending'] == true ? '结束照预览' : '游客照预览'),
      content: SizedBox(
        width: 680,
        height: MediaQuery.sizeOf(context).height * .52,
        child: InteractiveViewer(child: _previewImage(photo)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
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
  const _CodeDialog({required this.count, required this.time, this.candidate});
  final int count;
  final String time;
  final String? candidate;

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  late String _code = widget.candidate ?? '';

  @override
  Widget build(BuildContext context) {
    final valid = RegExp(r'^(?:[0-9]{4}|[A-Z0-9]{12})$').hasMatch(_code);
    final count = widget.count;
    final time = widget.time;
    return AlertDialog(
      title: const Text('确认补录取片码'),
      scrollable: true,
      content: SizedBox(
        width: 390,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('将 $time 批次的 $count 张游客照归入下方取片卡。'),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: _code,
              autofocus: true,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '取片码',
                helperText: '4 位卡尾号或 12 位完整取片码',
                border: OutlineInputBorder(),
              ),
              onChanged: (text) =>
                  setState(() => _code = text.trim().toUpperCase()),
              onFieldSubmitted: (_) {
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
bool _unassigned(Json batch) =>
    const {'MISSING_END', 'INVALID_END', 'AFTER_END'}.contains(batch['status']);
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

Future<Uint8List> _readBatchPhoto(Json photo) async {
  const maxBytes = 35 * 1024 * 1024;
  final uri = Uri.parse(photo['previewUrl'] as String);
  final client = http.Client();
  try {
    final response = await client
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('原图读取失败，请刷新批次后重试');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      if (bytes.length + chunk.length > maxBytes) {
        throw StateError('照片超过 35 MB，请直接核对并输入取片码');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } finally {
    client.close();
  }
}

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
