import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../../ui/app_dialogs.dart';
import '../../ui/design.dart';
import '../job_query_time.dart';
import '../print_bridge.dart';
import 'date_time_range_field.dart';

class PhotoBatchPage extends StatefulWidget {
  const PhotoBatchPage({
    super.key,
    required this.call,
    required this.scenicName,
  });

  final Future<dynamic> Function(String, List<dynamic>) call;
  final String scenicName;

  @override
  State<PhotoBatchPage> createState() => _PhotoBatchPageState();
}

class _PhotoBatchPageState extends State<PhotoBatchPage> {
  final _selected = <String>{};
  final _requests = <String, String>{};
  List<Json>? _stations;
  List<Json> _batches = [];
  String? _station;
  String? _error;
  DateTimeRange _range = _today();
  bool _loading = true;
  bool _working = false;
  bool _submitting = false;

  static DateTimeRange _today() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTimeRange(
      start: DateTime.utc(now.year, now.month, now.day),
      end: DateTime.utc(now.year, now.month, now.day, 23, 59, 59),
    );
  }

  @override
  void initState() {
    super.initState();
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
      final end = _range.end;
      final result = station == null
          ? null
          : await widget.call('listPhotoBatches', [
                  {
                    'stationId': station,
                    'from': shanghaiDateTime(_range.start),
                    'to': shanghaiDateTime(
                      DateTime.utc(
                        end.year,
                        end.month,
                        end.day,
                        end.hour,
                        end.minute,
                        end.second + 1,
                      ),
                    ),
                  },
                ])
                as Json;
      if (mounted) {
        setState(() {
          _batches = result == null
              ? []
              : (result['batches'] as List).cast<Json>();
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
              SizedBox(
                width: 80,
                height: 70,
                child: _image(item.photo, thumb: true),
              ),
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
      final result =
          await widget.call('correctPhotoBatch', [
                _station!,
                {'requestId': requestId, ...change},
              ])
              as Json;
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
    return PopScope(
      canPop: !_working,
      child: Scaffold(
        backgroundColor: WorkstationStyle.bg,
        appBar: AppBar(
          backgroundColor: WorkstationStyle.card,
          title: const Text('照片批次矫正'),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                color: WorkstationStyle.card,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 16,
                  ),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_stations case final stations?
                          when stations.isNotEmpty)
                        DropdownButton<String>(
                          value: _station,
                          onChanged: !enabled
                              ? null
                              : (value) {
                                  setState(() => _station = value);
                                  _load();
                                },
                          items: stations
                              .map(
                                (row) => DropdownMenuItem(
                                  value: row['id'] as String,
                                  child: Text(
                                    "${row['code']} · ${row['name']}",
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      JobCreatedRangeField(
                        value: _range,
                        enabled: enabled,
                        onChanged: (range) {
                          setState(() => _range = range ?? _today());
                          _load();
                        },
                      ),
                      IconButton(
                        tooltip: '刷新批次',
                        onPressed: enabled ? _load : null,
                        icon: const Icon(Icons.refresh),
                      ),
                      Text(
                        '${widget.scenicName} · 收图顺序 · 北京时间',
                        style: const TextStyle(color: WorkstationStyle.muted),
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
          child: SelectableText(error, textAlign: TextAlign.center),
        ),
      );
    }
    if (_batches.isEmpty) {
      final label = _loading
          ? '正在读取照片批次…'
          : _station == null
          ? '当前景区暂无机位'
          : '该时间范围内暂无收图';
      return Center(child: Text(label));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      itemCount: _batches.length,
      itemBuilder: (context, index) {
        final batch = _batches[index];
        final gap = index == 0
            ? -1
            : _received(batch)
                  .difference(_received(_photos(_batches[index - 1]).last))
                  .inSeconds;
        final wall = _wall(batch);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (index > 0)
              Row(
                children: [
                  Container(
                    width: 1,
                    height: 28,
                    margin: const EdgeInsets.only(left: 6, right: 9),
                    color: WorkstationStyle.muted,
                  ),
                  if (gap >= 0)
                    Text(
                      '间隔 ${_gap(gap)}',
                      style: const TextStyle(
                        color: WorkstationStyle.muted,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 15, right: 7),
                  child: Icon(
                    Icons.radio_button_unchecked,
                    size: 13,
                    color: WorkstationStyle.accent,
                  ),
                ),
                SizedBox(
                  width: 81,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10, right: 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          wall.substring(11),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          wall.substring(0, 10),
                          style: const TextStyle(
                            color: WorkstationStyle.muted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(child: _batchCard(batch)),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _batchCard(Json batch) {
    final photos = _photos(batch);
    final status = batch['status'];
    final pending =
        status == 'MISSING_END' ||
        status == 'INVALID_END' ||
        status == 'AFTER_END';
    final canFill = pending && photos.any(_movable);
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
    return DragTarget<_Dragged>(
      onWillAcceptWithDetails: (details) => _canDrop(details.data, batch),
      onAcceptWithDetails: (details) => _move(details.data, batch),
      builder: (context, hovering, _) => Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        decoration: BoxDecoration(
          color: hovering.isNotEmpty
              ? WorkstationStyle.accentSoft
              : WorkstationStyle.card,
          border: Border.all(
            color: hovering.isNotEmpty
                ? WorkstationStyle.accent
                : pending
                ? const Color(0xffedd7ae)
                : WorkstationStyle.line,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  _label(batch),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                StatusTag(
                  label: label,
                  color: pending
                      ? WorkstationStyle.warn
                      : WorkstationStyle.accent,
                  soft: pending
                      ? WorkstationStyle.warnSoft
                      : WorkstationStyle.accentSoft,
                ),
                Text('$count 张游客照'),
                if (canFill)
                  OutlinedButton(
                    onPressed: _loading || _working ? null : () => _fill(batch),
                    child: Text(chosen == 0 ? '补录取片码' : '补录取片码（已选 $chosen 张）'),
                  ),
                if (hovering.isNotEmpty)
                  const Text(
                    '松开后确认移动',
                    style: TextStyle(color: WorkstationStyle.accent),
                  ),
                if (status == 'CARD' && batch['targetPhotoId'] == null)
                  Text(
                    batch['targetBlockedReason'] as String,
                    style: const TextStyle(color: WorkstationStyle.muted),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 86 + MediaQuery.textScalerOf(context).scale(54),
              child: ListView.separated(
                key: PageStorageKey(batch['id']),
                primary: false,
                scrollDirection: Axis.horizontal,
                itemCount: photos.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, index) =>
                    _photoTile(photos[index], batch, canFill),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _photoTile(Json photo, Json batch, bool canFill) {
    final ending = photo['ending'] == true;
    final time = _time(photo);
    final id = photo['id'] as String;
    final tile = SizedBox(
      width: 88,
      child: Column(
        children: [
          SizedBox(
            height: 83,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Material(
                  color: WorkstationStyle.bg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                    side: BorderSide(
                      color: ending
                          ? WorkstationStyle.accent
                          : WorkstationStyle.line,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _preview(photo, batch),
                    child: _image(photo, thumb: true),
                  ),
                ),
                if (canFill && _movable(photo))
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Material(
                      color: WorkstationStyle.card,
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
          Text(
            ending ? '结束照 $time' : time,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: ending ? WorkstationStyle.accent : WorkstationStyle.muted,
            ),
          ),
          if (photo['estimatedReceivedAt'] == true)
            const Text(
              '历史入库时间',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10),
            ),
        ],
      ),
    );
    if (!_movable(photo) || _working || _loading) {
      return Tooltip(
        message: photo['blockedReason'] as String? ?? '照片预览',
        child: tile,
      );
    }
    return Tooltip(
      message: '拖到目标批次',
      child: Draggable<_Dragged>(
        data: (photo: photo, batch: batch),
        maxSimultaneousDrags: 1,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          elevation: 3,
          child: SizedBox(
            width: 68,
            height: 68,
            child: _image(photo, thumb: true),
          ),
        ),
        childWhenDragging: Opacity(opacity: .45, child: tile),
        child: tile,
      ),
    );
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
          child: InteractiveViewer(child: _image(photo, thumb: false)),
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

Widget _image(Json photo, {required bool thumb}) => Image.network(
  photo[thumb ? 'thumbnailUrl' : 'previewUrl'] as String,
  fit: BoxFit.contain,
  cacheWidth: thumb ? 240 : null,
  errorBuilder: (_, _, _) =>
      const Center(child: Icon(Icons.broken_image_outlined)),
);
