import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../ui/anchored_dropdown.dart';
import '../../ui/app_dialogs.dart';
import '../../ui/card_tail_dialog.dart';
import '../../ui/design.dart';
import '../../ui/dropdown_field.dart';
import '../../ui/workstation_form_dialog.dart';
import '../job_query_time.dart';
import '../print_bridge.dart';
import 'photo_batch_split_dialog.dart';

enum _PhotoAction {
  recognize('识别取片码', Icons.document_scanner_outlined),
  setCode('设置取片码', Icons.edit_outlined),
  remove('删除照片', Icons.delete_outline),
  capture('查询拍摄信息', Icons.info_outline),
  move('移动到其他批次', Icons.drive_file_move_outline),
  preview('查看图片', Icons.image_outlined);

  const _PhotoAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

class PhotoBatchTimeline extends StatefulWidget {
  const PhotoBatchTimeline({
    super.key,
    required this.call,
    required this.scenicName,
    this.initialStationId,
  }) : inline = false,
       uploadProgress = null;

  const PhotoBatchTimeline.inline({
    super.key,
    required this.call,
    required this.scenicName,
    required String stationId,
    this.uploadProgress,
  }) : inline = true,
       initialStationId = stationId;

  final Future<dynamic> Function(String, List<dynamic>) call;
  final String scenicName;
  final String? initialStationId;
  final bool inline;
  final ({int ingested, int grouped})? uploadProgress;

  @override
  State<PhotoBatchTimeline> createState() => _PhotoBatchTimelineState();
}

const _batchThumbnailHeight = 100.0;
const _maxSelection = 100;
const _batchStatuses = {
  'all': '全部状态',
  'incoming': '未归集',
  'aggregated': '已归集',
  'suspicious': '可疑组',
  'pending_claim': '待认领',
};

class _PhotoBatchTimelineState extends State<PhotoBatchTimeline> {
  final _selected = <String>{};
  final _requests = <String, String>{};
  final _selectionOverlay = OverlayPortalController();
  List<Json>? _stations;
  List<Json> _batches = [];
  String _directory = 'all';
  int? _intervalThreshold;
  String? _draggingPhotoId;
  String? _station;
  String? _error;
  DateTime _day = _shanghaiToday();
  bool _loading = true;
  bool _working = false;
  bool _submitting = false;
  bool _selecting = false;
  bool _refreshFromUploads = false;
  String? _candidate;
  String? _candidateBarcode;
  String? _recognitionPhotoId;
  String? _selectionNotice;

  List<Json> get _visibleBatches => _directory == 'all'
      ? _batches
      : _batches.where((batch) => batch['directory'] == _directory).toList();

  Json get _range => {
    'stationId': _station!,
    'from': shanghaiDateTime(_day),
    'to': shanghaiDateTime(_day.add(const Duration(days: 1))),
  };

  @override
  void initState() {
    super.initState();
    _station = widget.initialStationId;
    _load();
  }

  @override
  void didUpdateWidget(covariant PhotoBatchTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.uploadProgress != oldWidget.uploadProgress &&
        DateUtils.isSameDay(_day, _shanghaiToday())) {
      _refreshFromUploads = true;
    }
  }

  bool get _canRefreshFromUploads =>
      _refreshFromUploads &&
      !_loading &&
      !_working &&
      !_selecting &&
      _draggingPhotoId == null;

  Future<void> _load({bool refreshStations = false}) async {
    if (_selectionOverlay.isShowing) _selectionOverlay.hide();
    setState(() {
      _refreshFromUploads = false;
      _loading = true;
      _error = null;
      _selecting = false;
      _selected.clear();
      _candidate = null;
      _candidateBarcode = null;
      _recognitionPhotoId = null;
      _selectionNotice = null;
    });
    try {
      final stations = refreshStations || _stations == null
          ? (await widget.call('listBatchStations', []) as List).cast<Json>()
          : _stations!;
      if (!mounted) return;
      final previous = _station;
      final hasSelection = stations.any((row) => row['id'] == previous);
      final station = widget.inline || hasSelection
          ? previous
          : stations.firstOrNull?['id'] as String?;
      final unavailable = widget.inline && station != null && !hasSelection;
      setState(() {
        _stations = stations;
        _station = station;
        if (station != previous || unavailable) _batches = [];
      });
      if (unavailable) {
        throw StateError('当前打印景区没有此上传机位，请核对机位和景区设置。');
      }
      final result = station == null
          ? null
          : await widget.call('listPhotoBatches', [_range]) as Json;
      if (mounted) {
        setState(() {
          _intervalThreshold = result?['suspiciousIntervalSec'] as int?;
          _batches = result == null
              ? []
              : (result['batches'] as List).cast<Json>().reversed.toList();
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
      !_selecting &&
      photo.batch['id'] != target['id'];

  Future<void> _move(_Dragged item, [Json? initialTarget]) async {
    final targets = _visibleBatches
        .where((target) => _canDrop(item, target))
        .toList();
    if (targets.isEmpty) return;
    final assignedCardId = item.photo.containsKey('assignedCardId')
        ? item.photo['assignedCardId']
        : switch (item.batch['id']) {
            final String id when id.startsWith('card-') => id.substring(5),
            _ => null,
          };

    bool canAssignTo(Json? batch) {
      if (batch == null || !_movable(item.photo)) return false;
      return batch['targetPhotoId'] != null &&
          batch['targetCardId'] != null &&
          assignedCardId != batch['targetCardId'];
    }

    bool defaultAssignTo(Json? batch) {
      if (batch == null || !canAssignTo(batch)) return false;
      final cardId = batch['targetCardId'];
      return _photos(batch).every((photo) {
        final assigned = photo['assignedCardId'];
        return assigned == null || assigned == cardId;
      });
    }

    setState(() => _working = true);
    try {
      var target = initialTarget ?? targets.singleOrNull;
      var assignCard = defaultAssignTo(target);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) {
            final chosen = target;
            final canAssign = canAssignTo(chosen);
            final targetField = DropdownField<Json>(
              label: '目标批次',
              placeholder: '选择目标批次',
              options: targets,
              value: chosen,
              labelFor: (batch) => '${_label(batch)} · ${_wall(batch)}',
              onChanged: (batch) => update(() {
                target = batch;
                assignCard = defaultAssignTo(batch);
              }),
            );
            return WorkstationFormDialog(
              title: '确认移动照片',
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _MovePhotoSummary(item: item),
                  const SizedBox(height: 16),
                  targetField,
                  if (chosen != null) ...[
                    const SizedBox(height: 16),
                    _MovePhotoOptions(
                      cardTail: chosen['cardTail'] as String?,
                      assignCard: assignCard,
                      unavailableReason: canAssign
                          ? null
                          : _moveGroupingNote(
                              item.photo,
                              chosen,
                              assignedCardId,
                            ),
                      onChanged: (value) => update(() => assignCard = value),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: target == null
                      ? null
                      : () => Navigator.pop(context, true),
                  child: Text(assignCard ? '移动并归卡' : '确认移动'),
                ),
              ],
            );
          },
        ),
      );
      final chosen = target;
      if (confirmed == true && mounted && chosen != null) {
        if (assignCard) {
          await _submit(
            [item.photo],
            {
              'targetPhotoId': chosen['targetPhotoId'],
              'targetCardId': chosen['targetCardId'],
            },
          );
        } else {
          final anchor = _photos(chosen).first;
          final result = await widget.call('movePhotoBatchPhoto', [
            _range,
            {
              'photoId': item.photo['id'],
              'revision': item.photo['revision'],
              'targetPhotoId': anchor['id'],
              'targetRevision': anchor['revision'],
            },
          ]) as Json;
          if (result['photoId'] != item.photo['id'] ||
              result['targetPhotoId'] != anchor['id']) {
            throw StateError('移动结果未确认，请刷新核对。');
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已移动 1 张照片')));
          await _load();
        }
      }
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          title: '无法确认移动结果',
          message: appErrorMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  bool _canSelect(Json photo) =>
      _movable(photo) && photo['id'] != _recognitionPhotoId;

  bool _isTarget(Json source, Json target) =>
      source['id'] != target['id'] &&
      target['targetPhotoId'] != null &&
      target['targetCardId'] != null &&
      source['targetCardId'] != target['targetCardId'];

  String _moveGroupingNote(Json photo, Json target, Object? assignedCardId) {
    if (photo['blockedReason'] case final String reason
        when reason.isNotEmpty) {
      return reason;
    }
    if (!_movable(photo)) return '结束照和卡片照只用于核对取片卡。';
    if (target['targetCardId'] != null &&
        assignedCardId == target['targetCardId']) {
      return '这张照片已归入${_label(target)}。';
    }
    return '目标批次暂不能接收这张照片的取片归属。';
  }

  void _setSelectionMode(bool active) {
    if (active) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..removeCurrentSnackBar();
    }
    if (widget.inline) {
      if (active) {
        _selectionOverlay.show();
      } else if (_selectionOverlay.isShowing) {
        _selectionOverlay.hide();
      }
    }
    setState(() {
      _selecting = active;
      _selectionNotice = null;
      if (!active) {
        _selected.clear();
        _candidate = null;
        _candidateBarcode = null;
        _recognitionPhotoId = null;
      }
    });
  }

  void _selectGroup(Iterable<Json> photos) {
    final ids = photos.where(_canSelect).map((photo) => photo['id'] as String);
    if ({..._selected, ...ids}.length > _maxSelection) {
      setState(() => _selectionNotice = '每次最多选 100 张，请减少勾选范围。');
      return;
    }
    setState(() {
      _selected.addAll(ids);
      _selectionNotice = null;
    });
  }

  void _selectPhoto(Json photo, bool checked) {
    if (checked) {
      _selectGroup([photo]);
    } else {
      setState(() {
        _selected.remove(photo['id']);
        _selectionNotice = null;
      });
    }
  }

  List<_SelectedGroup> _selectedGroups() => [
    for (final batch in _batches)
      if (_photos(batch)
              .where(
                (photo) => _canSelect(photo) && _selected.contains(photo['id']),
              )
              .toList()
          case final photos when photos.isNotEmpty)
        (batch: batch, photos: photos),
  ];

  Future<void> _assign({_Dragged? single}) async {
    if (_working || _loading) return;
    final groups = single == null
        ? _selectedGroups()
        : [
            (batch: single.batch, photos: [single.photo]),
          ];
    if (groups.isEmpty) return;
    final photos = groups.expand((group) => group.photos).toList();
    final byCode = groups.every((group) => _unassigned(group.batch));
    final targets = _batches
        .where(
          (target) => groups.every((group) => _isTarget(group.batch, target)),
        )
        .toList();
    final station = _stations
        ?.where((row) => row['id'] == _station)
        .firstOrNull;
    setState(() => _working = true);
    try {
      final result = await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _AssignmentDialog(
          groups: groups,
          targets: targets,
          byCode: byCode,
          singleCode: single != null,
          station: station == null ? '' : _stationName(station),
          candidate: single == null ? _candidate : null,
          barcode: single == null ? _candidateBarcode : null,
          thumbnail: _thumbnail,
          save: (fields, cardPhotoIds) =>
              _saveCorrection(photos, fields, cardPhotoIds: cardPhotoIds),
        ),
      );
      if (result != null && mounted) {
        await _correctionSaved(result, photos.length);
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<Json> _saveCorrection(
    List<Json> photos,
    Json fields, {
    Set<String> cardPhotoIds = const {},
  }) async {
    final change = {
      'photos': photos
          .map(
            (photo) => {
              'photoId': photo['id'],
              'revision': photo['revision'],
              if (cardPhotoIds.contains(photo['id'])) 'touristPhoto': false,
            },
          )
          .toList(),
      ...fields,
    };
    final key = jsonEncode([_station, change]);
    final requestId = _requestId(key);
    try {
      final result = await widget.call('correctPhotoBatch', [
        _station!,
        {'requestId': requestId, ...change},
      ]) as Json;
      final tail = result['cardTail'];
      if (result['requestId'] != requestId ||
          result['assignedCount'] != photos.length ||
          (result['cardPhotoCount'] ?? 0) != cardPhotoIds.length ||
          tail is! String ||
          tail.isEmpty) {
        throw StateError('服务返回的矫正结果不完整，请刷新核对。');
      }
      _requests.remove(key);
      return result;
    } on PrintBridgeResultError catch (error) {
      if (_isRejectedCorrection(error)) _requests.remove(key);
      rethrow;
    }
  }

  Future<void> _correctionSaved(Json result, int count) async {
    final cardCount = result['cardPhotoCount'] as int? ?? 0;
    final detail = cardCount == 0
        ? ''
        : ' · ${count - cardCount} 张游客照 · $cardCount 张卡片照';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已将 $count 张照片归入取片卡 ${result['cardTail']}$detail'),
      ),
    );
    await _load();
  }

  Future<void> _submit(List<Json> photos, Json fields) async {
    setState(() => _submitting = true);
    try {
      final result = await _saveCorrection(photos, fields);
      if (mounted) await _correctionSaved(result, photos.length);
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

  Future<void> _removePhotos(List<Json> photos, {String? batchLabel}) async {
    if (_loading || _working) return;
    setState(() => _working = true);
    final wholeBatch = batchLabel != null;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => WorkstationFormDialog(
          title: wholeBatch ? '整批删除？' : '删除这张照片？',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              if (wholeBatch)
                Text('$batchLabel · 共 ${photos.length} 张照片')
              else
                SizedBox(
                  width: 120,
                  height: 96,
                  child: _thumbnail(photos.single),
                ),
              const Text('照片将从照片管理移除。系统会保留原图、分批依据和已有的游客权益。'),
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
      final selections = [
        for (final photo in photos)
          {'photoId': photo['id'] as String, 'revision': photo['revision']},
      ];
      final key = jsonEncode([
        wholeBatch ? 'removeBatch' : 'remove',
        _range,
        selections,
      ]);
      final requestId = _requestId(key);
      setState(() => _submitting = true);
      final result =
          (wholeBatch
                  ? await widget.call('removePhotoBatch', [
                      _range,
                      {'requestId': requestId, 'photos': selections},
                    ])
                  : await widget.call('removeBatchPhoto', [
                      _station!,
                      selections.single['photoId'],
                      {
                        'requestId': requestId,
                        'revision': selections.single['revision'],
                      },
                    ]))
              as Json;
      final acknowledged = wholeBatch
          ? result['removedCount'] == photos.length
          : result['photoId'] == selections.single['photoId'];
      if (result['requestId'] != requestId || !acknowledged) {
        throw StateError('删除结果未确认，请刷新核对。');
      }
      _requests.remove(key);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已删除 ${photos.length} 张照片')));
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

  Future<void> _recognizeTail(_Dragged item) async {
    if (_working || _loading) return;
    final photo = item.photo;
    final cardPhotoId = photo['id'] as String;
    final canFill = _batches.any(
      (batch) =>
          _unassigned(batch) &&
          _photos(batch)
              .any((photo) => _movable(photo) && photo['id'] != cardPhotoId),
    );
    setState(() => _working = true);
    CardCodeChoice? recognized;
    try {
      recognized = await showCardTailDialog(
        context,
        readPhoto: () => _readBatchPhoto(photo),
        sourcePath: Uri.tryParse(photo['previewUrl'] as String? ?? '')?.path,
        guidance: '识别结果可用于批量归集。没有卡面时，可在设置取片批次中手动输入。',
        allowUse: canFill,
        useLabel: '核对后用于归集',
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (!mounted || recognized == null) return;
    if (recognized.code case final candidate?) {
      _candidate = candidate;
      _candidateBarcode = recognized.barcode;
      _recognitionPhotoId = cardPhotoId;
      _selected.remove(cardPhotoId);
      _setSelectionMode(true);
      final groups = _selectedGroups();
      if (groups.isNotEmpty &&
          groups.every((group) => _unassigned(group.batch))) {
        await _assign();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_canRefreshFromUploads) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _canRefreshFromUploads) _load();
      });
    }
    final enabled = !_loading && !_working;
    final stations = _stations ?? const <Json>[];
    final selectedStation = stations
        .where((row) => row['id'] == _station)
        .firstOrNull;
    final dateFilter = _BatchDayMenu(
      day: _day,
      width: 176,
      enabled: enabled,
      onChanged: (day) {
        if (day == _day) return;
        setState(() => _day = day);
        _load();
      },
    );
    final statusFilter = SizedBox(
      width: 138,
      child: DropdownField<String>(
        label: '状态',
        showLabel: false,
        placeholder: '全部状态',
        options: _batchStatuses.keys.toList(),
        value: _directory,
        labelFor: (value) => _batchStatuses[value]!,
        onChanged: enabled && !_selecting
            ? (value) => setState(() => _directory = value)
            : null,
      ),
    );
    final refresh = IconButton(
      tooltip: '刷新批次',
      onPressed: enabled ? () => _load(refreshStations: true) : null,
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        foregroundColor: WorkstationStyle.accent,
        backgroundColor: WorkstationStyle.accentSoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: const Icon(Icons.refresh_rounded, size: 20),
    );
    final selection = OutlinedButton.icon(
      onPressed:
          enabled &&
              _visibleBatches.any((batch) => _photos(batch).any(_movable))
          ? () => _setSelectionMode(!_selecting)
          : null,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        foregroundColor: WorkstationStyle.ink,
        side: const BorderSide(color: WorkstationStyle.line),
        backgroundColor: _selecting ? WorkstationStyle.accentSoft : null,
      ),
      icon: Icon(_selecting ? Icons.close : Icons.checklist, size: 18),
      label: Text(_selecting ? '退出批量归集' : '批量归集'),
    );
    final controls = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final heading = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              const Text(
                '照片归属',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: WorkstationStyle.ink,
                ),
              ),
              Text(
                '${widget.scenicName} · 最新批次在前 · 北京时间',
                style: const TextStyle(
                  color: WorkstationStyle.muted,
                  fontSize: 12,
                ),
              ),
            ],
          );
          final filters = Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: widget.inline ? WrapAlignment.end : WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!widget.inline && stations.isNotEmpty)
                SizedBox(
                  width: 236,
                  child: Tooltip(
                    message: '选择机位',
                    child: DropdownField<Json>(
                      label: '选择机位',
                      showLabel: false,
                      placeholder: '选择机位',
                      icon: Icons.videocam_outlined,
                      options: stations,
                      value: selectedStation,
                      labelFor: _stationName,
                      onChanged: enabled
                          ? (row) {
                              if (row['id'] == _station) return;
                              setState(() => _station = row['id'] as String);
                              _load();
                            }
                          : null,
                    ),
                  ),
                ),
              dateFilter,
              statusFilter,
              refresh,
              selection,
            ],
          );
          if (widget.inline) {
            return Align(alignment: Alignment.centerRight, child: filters);
          }
          return constraints.maxWidth >= 600
              ? Row(
                  spacing: 12,
                  children: [
                    Expanded(child: heading),
                    Flexible(
                      flex: 2,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: filters,
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [heading, filters],
                );
        },
      ),
    );
    final header = DecoratedBox(
      decoration: WorkstationStyle.surface(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WorkstationStyle.radius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            controls,
            if (_loading || _submitting)
              const LinearProgressIndicator(minHeight: 2),
          ],
        ),
      ),
    );
    final timeline = _timeline();
    final visible = TickerMode.valuesOf(context).enabled;
    final content = widget.inline
        ? SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: OverlayPortal(
                  controller: _selectionOverlay,
                  overlayChildBuilder: (_) => !visible
                      ? const SizedBox.shrink()
                      : SafeArea(
                          minimum: const EdgeInsets.all(16),
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: _selectionBar(),
                          ),
                        ),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: header,
                  ),
                ),
              ),
              timeline,
              if (_selecting)
                const SliverToBoxAdapter(child: SizedBox(height: 88)),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: header,
              ),
              Expanded(child: CustomScrollView(slivers: [timeline])),
              if (_selecting) _selectionBar(),
            ],
          );
    return PopScope(canPop: !_working, child: content);
  }

  Widget _selectionBar() {
    final enabled = !_working && !_loading && _selected.isNotEmpty;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 780),
      child: Material(
        color: WorkstationStyle.card,
        elevation: 2,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: WorkstationStyle.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '已选 ${_selected.length} 张',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (_selectionNotice != null || _candidate != null)
                Text(
                  _selectionNotice ?? '已识别候选尾号 $_candidate',
                  style: const TextStyle(color: WorkstationStyle.muted),
                ),
              TextButton(
                onPressed: enabled
                    ? () => setState(() {
                        _selected.clear();
                        _selectionNotice = null;
                      })
                    : null,
                child: const Text('清空'),
              ),
              FilledButton(
                onPressed: enabled ? _assign : null,
                child: const Text('设置取片批次'),
              ),
            ],
          ),
        ),
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
    final batches = _visibleBatches;
    if (batches.isEmpty) {
      final label = _loading
          ? '正在读取照片批次…'
          : _station == null
          ? '当前景区暂无机位'
          : _directory == 'all'
          ? '当天暂无收图'
          : '当天没有符合所选状态的批次';
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
            itemCount: batches.length,
            itemBuilder: (context, index) =>
                _timelineItem(batches, index, wide: wide),
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

  Widget _timelineItem(List<Json> batches, int index, {required bool wide}) {
    final batch = batches[index];
    final first = index == 0;
    final last = index == batches.length - 1;
    final gap = last
        ? -1
        : _received(batch)
              .difference(_received(_photos(batches[index + 1]).last))
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
    final photos = [..._photos(batch)];
    if (photos.every((photo) => _shotAt(photo) != null)) {
      photos.sort((first, second) {
        final time = _shotAt(first)!.compareTo(_shotAt(second)!);
        return time != 0
            ? time
            : BigInt.parse(first['id'] as String)
                  .compareTo(BigInt.parse(second['id'] as String));
      });
    }
    final status = batch['status'];
    final pending = _unassigned(batch);
    final canSelectGroup = _selecting && photos.any(_canSelect);
    final hasDestination = _visibleBatches.length > 1;
    final count = photos.where(_isVisitorPhoto).length;
    final cardCount = photos.where(_isCardPhoto).length;
    final label = switch (status) {
      'MISSING_END' => '缺少结束照',
      'AFTER_END' => '结束照后收图',
      'INVALID_END' => '结束照未匹配',
      'REVIEW' when batch['directory'] == 'suspicious' => '可疑组',
      'REVIEW' when batch['directory'] == 'pending_claim' => '待认领',
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
          Row(
            spacing: 8,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
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
                          '$count 张游客照${cardCount == 0 ? '' : ' · $cardCount 张卡片照'}',
                          style: const TextStyle(
                            color: WorkstationStyle.muted,
                            fontSize: 12,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    if (canSelectGroup)
                      FilledButton.tonal(
                        onPressed: _loading || _working
                            ? null
                            : () => _selectGroup(photos),
                        style: FilledButton.styleFrom(
                          foregroundColor: WorkstationStyle.accent,
                          backgroundColor: WorkstationStyle.accentSoft,
                        ),
                        child: const Text('选中本组可处理照片'),
                      ),
                    if (hovering)
                      const Text(
                        '松开后确认移动',
                        style: TextStyle(
                          color: WorkstationStyle.accent,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _loading || _working || photos.isEmpty
                    ? null
                    : () => _removePhotos(
                        _photos(batch),
                        batchLabel: _label(batch),
                      ),
                style: TextButton.styleFrom(
                  foregroundColor: WorkstationStyle.bad,
                ),
                icon: const Icon(Icons.delete_outline, size: 17),
                label: const Text('整批删除'),
              ),
            ],
          ),
          const Divider(height: 14, color: WorkstationStyle.line),
          SizedBox(
            height:
                _batchThumbnailHeight +
                max(
                  26.0,
                  8 +
                      textScaler.scale(11) * 1.3 * captionLines +
                      (hasEstimatedTime ? textScaler.scale(10) * 1.3 : 0),
                ),
            child: ListView.separated(
              key: PageStorageKey(batch['id']),
              primary: false,
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              separatorBuilder: (_, index) =>
                  _interval(photos[index], photos[index + 1]),
              itemBuilder: (_, index) => _photoTile(
                photos[index],
                batch,
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
    bool hasDestination,
    int captionLines,
  ) {
    final ending = photo['ending'] == true;
    final time = _time(photo);
    final id = photo['id'] as String;
    final canMove = !_selecting && hasDestination && !_working && !_loading;
    final checked = _selected.contains(id);
    final selectable = _canSelect(photo) && !_working && !_loading;
    final item = (photo: photo, batch: batch);
    final blocked = photo['blockedReason'] as String?;
    final selectionReason = id == _recognitionPhotoId
        ? '识别来源照片仅供核对'
        : ending
        ? '结束照仅供核对'
        : blocked;
    final preview = Stack(
      fit: StackFit.expand,
      children: [
        Material(
          color: WorkstationStyle.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              width: checked ? 2 : 1,
              color: ending || checked
                  ? WorkstationStyle.accent
                  : WorkstationStyle.line,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            mouseCursor: canMove
                ? _draggingPhotoId == id
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab
                : null,
            onTap: _selecting
                ? selectable
                      ? () => _selectPhoto(photo, !checked)
                      : null
                : () => _preview(photo),
            child: _thumbnail(photo),
          ),
        ),
      ],
    );
    return SizedBox(
      width: 136,
      child: Column(
        children: [
          SizedBox(
            height: _batchThumbnailHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (canMove)
                  Draggable<_Dragged>(
                    key: ValueKey('drag-photo-$id'),
                    data: item,
                    maxSimultaneousDrags: 1,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    onDragStarted: () => setState(() => _draggingPhotoId = id),
                    onDragEnd: (_) => setState(() => _draggingPhotoId = null),
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
                        onSelected: (action) => _runPhotoAction(action, item),
                        itemBuilder: (_) => [
                          for (final action in _PhotoAction.values)
                            if ((action != _PhotoAction.move || canMove) &&
                                (action != _PhotoAction.setCode ||
                                    (_movable(photo) && _unassigned(batch))))
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
                if (_selecting)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: Material(
                      color: WorkstationStyle.card,
                      borderRadius: BorderRadius.circular(6),
                      child: Tooltip(
                        message: selectionReason ?? '选中游客照 $time',
                        child: SizedBox.square(
                          dimension: 40,
                          child: Checkbox(
                            key: ValueKey('select-photo-$id'),
                            value: checked,
                            onChanged: selectable
                                ? (value) => _selectPhoto(photo, value == true)
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${_photoType(photo)} $time',
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

  Widget _interval(Json before, Json after) {
    final first = _shotAt(before);
    final second = _shotAt(after);
    final seconds = first == null || second == null
        ? null
        : second.difference(first).inSeconds.abs();
    final threshold = _intervalThreshold;
    final over = seconds != null && threshold != null && seconds > threshold;
    final label = seconds == null ? '拍摄间隔未知' : '间隔 ${_gap(seconds)}';
    return SizedBox(
      width: 46,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: _batchThumbnailHeight),
          child: IconButton.outlined(
            key: ValueKey('photo-interval-${before['id']}-${after['id']}'),
            tooltip: over ? '$label，超过 $threshold 秒阈值' : label,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            style: IconButton.styleFrom(
              padding: EdgeInsets.zero,
              foregroundColor: over
                  ? const Color(0xffaa7900)
                  : WorkstationStyle.muted,
              side: const BorderSide(color: WorkstationStyle.line),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _loading || _working
                ? null
                : () => _split(before, after, label),
            icon: const Icon(Icons.schedule, size: 14),
          ),
        ),
      ),
    );
  }

  Future<void> _split(Json before, Json after, String label) async {
    setState(() => _working = true);
    final point = {'beforePhotoId': before['id'], 'afterPhotoId': after['id']};
    try {
      final preview = await widget.call('previewPhotoBatchSplit', [
        {..._range, ...point},
      ]) as Json;
      final parts = (preview['parts'] as List).cast<Json>();
      final snapshot = preview['snapshot'];
      final threshold = preview['thresholdSec'];
      if (parts.length != 2 ||
          snapshot is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(snapshot) ||
          threshold is! int ||
          threshold < 30) {
        throw StateError('切分预览响应不完整。');
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => PhotoBatchSplitDialog(
          before: _shotAt(before),
          after: _shotAt(after),
          interval: label,
          parts: parts,
          cardTail: preview['cardTail'] as String?,
          managementOnly: preview['managementOnly'] == true,
          thumbnail: _thumbnail,
        ),
      );
      if (confirmed != true || !mounted) return;
      final result = await widget.call('savePhotoBatchSplit', [
        _range,
        {...point, 'snapshot': snapshot, 'thresholdSec': threshold},
      ]) as Json;
      final messages = (result['messages'] as List)
          .whereType<String>()
          .toList();
      if (messages.isEmpty) throw StateError('切分结果未确认，请刷新核对。');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(messages.join(' · '))));
      await _load();
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          title: '请核对切分结果',
          message: appErrorMessage(error),
        );
        if (mounted) await _load();
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  DateTime? _shotAt(Json photo) {
    final value = photo['shotAt'];
    return value is String ? DateTime.tryParse(value) : null;
  }

  Future<void> _runPhotoAction(_PhotoAction action, _Dragged item) async {
    final photo = item.photo;
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
        await _recognizeTail(item);
      case _PhotoAction.setCode:
        await _assign(single: item);
      case _PhotoAction.remove:
        await _removePhotos([photo]);
      case _PhotoAction.capture:
        await _showCapture(photo);
      case _PhotoAction.move:
        await _move(item);
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
      title: Text('${_photoType(photo)}预览'),
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

class _MovePhotoSummary extends StatelessWidget {
  const _MovePhotoSummary({required this.item});

  final _Dragged item;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: WorkstationStyle.bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          spacing: 12,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ColoredBox(
                color: WorkstationStyle.card,
                child: SizedBox(
                  width: 56,
                  height: 64,
                  child: _thumbnail(item.photo),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    '${_photoType(item.photo)} · ${_time(item.photo)}',
                    style: text.titleSmall,
                  ),
                  Text(
                    '来源批次 · ${_label(item.batch)}',
                    style: text.bodySmall?.copyWith(
                      color: WorkstationStyle.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MovePhotoOptions extends StatelessWidget {
  const _MovePhotoOptions({
    required this.cardTail,
    required this.assignCard,
    required this.unavailableReason,
    required this.onChanged,
  });

  final String? cardTail;
  final bool assignCard;
  final String? unavailableReason;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final descriptionStyle = text.bodySmall?.copyWith(
      color: WorkstationStyle.muted,
    );
    Widget option(bool value, String title, String description) {
      final selected = assignCard == value;
      final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? WorkstationStyle.accent : WorkstationStyle.line,
        ),
      );
      return RadioListTile<bool>(
        value: value,
        enabled: !value || unavailableReason == null,
        selected: selected,
        activeColor: WorkstationStyle.accent,
        selectedTileColor: WorkstationStyle.accentSoft,
        shape: shape,
        contentPadding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
        title: Text(
          title,
          style: text.titleSmall?.copyWith(color: WorkstationStyle.ink),
        ),
        subtitle: Text(description, style: descriptionStyle),
      );
    }

    return RadioGroup<bool>(
      groupValue: assignCard,
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text('移动方式', style: text.titleSmall),
          option(false, '仅整理工作台分组', '只调整工作台里的分组，游客扫码看到的照片保持原样。'),
          option(
            true,
            cardTail == null ? '归入取片卡' : '归入取片卡 $cardTail',
            unavailableReason ?? '归集完成后，游客在柜机扫这张卡就能看到这张照片。',
          ),
        ],
      ),
    );
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
    required this.width,
    required this.enabled,
    required this.onChanged,
  });

  final DateTime day;
  final double width;
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
      width: widget.width,
      enabled: widget.enabled,
      items: (close) => [
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
              Expanded(
                child: Text(
                  '${_month.year}年${_month.month}月',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
          _dayOption(
            DateTime.utc(_month.year, _month.month, number),
            today,
            close,
          ),
      ],
    );
  }

  void _changeMonth(int offset) =>
      setState(() => _month = DateTime.utc(_month.year, _month.month + offset));

  Widget _dayOption(DateTime date, DateTime today, VoidCallback close) =>
      ListTile(
        key: ValueKey(date),
        dense: true,
        selected: date == widget.day,
        trailing: date == widget.day
            ? const Icon(Icons.check_rounded, size: 17)
            : null,
        title: Text('${_dateLabel(date)}${date == today ? ' · 今天' : ''}'),
        onTap: () {
          close();
          widget.onChanged(date);
        },
      );
}

class _BatchFilterMenu extends StatelessWidget {
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
  final List<Widget> Function(VoidCallback) items;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 44,
    child: AnchoredDropdown(
      enabled: enabled,
      preferredHeight: 320,
      menuBuilder: (context, close) => ListView(
        primary: false,
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: items(close),
      ),
      triggerBuilder: (context, focus, open, toggle) => Tooltip(
        message: tooltip,
        child: Semantics(
          expanded: open,
          child: OutlinedButton(
            focusNode: focus,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              foregroundColor: WorkstationStyle.ink,
              backgroundColor: WorkstationStyle.bg,
              side: BorderSide(
                color: open
                    ? Theme.of(context).colorScheme.primary
                    : WorkstationStyle.line,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: enabled ? toggle : null,
            child: Row(
              children: [
                Icon(icon, size: 17, color: WorkstationStyle.muted),
                const SizedBox(width: 8),
                Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 4),
                Icon(
                  open
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

bool _isRejectedCorrection(Object error) =>
    error is PrintBridgeResultError &&
    const {40001, 40101, 40102, 40301, 40401, 40901}.contains(error.resultCode);

class _AssignmentDialog extends StatefulWidget {
  const _AssignmentDialog({
    required this.groups,
    required this.targets,
    required this.byCode,
    required this.singleCode,
    required this.station,
    required this.candidate,
    required this.barcode,
    required this.thumbnail,
    required this.save,
  });

  final List<_SelectedGroup> groups;
  final List<Json> targets;
  final bool byCode;
  final bool singleCode;
  final String station;
  final String? candidate;
  final String? barcode;
  final Widget Function(Json) thumbnail;
  final Future<Json> Function(Json, Set<String>) save;

  @override
  State<_AssignmentDialog> createState() => _AssignmentDialogState();
}

class _AssignmentDialogState extends State<_AssignmentDialog> {
  late bool _byCode = widget.byCode;
  late String _code = widget.candidate ?? '';
  late final _codeController = TextEditingController(text: _code);
  final Set<String> _cardPhotoIds = {};
  Json? _target;
  Json? _pending;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Json? get _fields {
    if (_byCode) {
      return RegExp(r'^(?:[0-9]{6}|[A-Z0-9]{12})$').hasMatch(_code)
          ? {'cardCode': _code}
          : null;
    }
    final target = _target;
    return target == null
        ? null
        : {
            'targetPhotoId': target['targetPhotoId'],
            'targetCardId': target['targetCardId'],
          };
  }

  Future<void> _confirm() async {
    final fields = _pending ?? _fields;
    if (_saving || fields == null) return;
    setState(() {
      _pending = fields;
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.save(fields, _cardPhotoIds);
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        final message = appErrorMessage(error);
        if (_isRejectedCorrection(error)) {
          _pending = null;
          _error = message.replaceFirst(
            RegExp(r'^POST [^ ]+ 失败：[0-9]+\s*'),
            '',
          );
        } else {
          _error = '提交未确认：$message';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.byCode || widget.targets.isNotEmpty;
    final editable = _pending == null;
    final count = widget.groups.fold(
      0,
      (sum, group) => sum + group.photos.length,
    );
    return PopScope(
      canPop: !_saving,
      child: WorkstationFormDialog(
        title: widget.singleCode ? '设置取片码' : '设置取片批次',
        width: 480,
        canClose: !_saving,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(
              '${widget.station} · 已选 $count 张照片',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (available) ...[
              const Text(
                '逐张确认是否游客照',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const Text('取消勾选的照片以「卡片照」随批保存，仅供工作人员核对。'),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 245),
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 10,
                  children: [
                    for (final group in widget.groups)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 6,
                        children: [
                          Text(
                            '${_label(group.batch)} · ${_wall(group.batch)} · ${group.photos.length} 张',
                          ),
                          for (final photo in group.photos)
                            CheckboxListTile(
                              key: ValueKey(
                                'assignment-visitor-${photo['id']}',
                              ),
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.trailing,
                              secondary: SizedBox(
                                width: 72,
                                height: 48,
                                child: widget.thumbnail(photo),
                              ),
                              title: Text(
                                _cardPhotoIds.contains(photo['id'])
                                    ? '卡片照 · ${_time(photo)}'
                                    : '游客照 · ${_time(photo)}',
                              ),
                              subtitle: const Text('是否游客照'),
                              value: !_cardPhotoIds.contains(photo['id']),
                              onChanged:
                                  editable && photo['assetRole'] == 'PHOTO'
                                  ? (value) => setState(() {
                                      final id = photo['id'] as String;
                                      if (value == true) {
                                        _cardPhotoIds.remove(id);
                                      } else {
                                        _cardPhotoIds.add(id);
                                      }
                                      _error = null;
                                    })
                                  : null,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            if (!available)
              const Text('当前选择没有可接收的目标批次，请返回调整选中的照片。')
            else ...[
              if (!widget.singleCode)
                DropdownField<bool>(
                  label: '归集方式',
                  placeholder: '选择归集方式',
                  value: _byCode,
                  options: [
                    if (widget.byCode) true,
                    if (widget.targets.isNotEmpty) false,
                  ],
                  labelFor: (byCode) => byCode ? '输入取片码' : '选择已有批次',
                  onChanged: editable
                      ? (value) => setState(() {
                          _byCode = value;
                          _error = null;
                        })
                      : null,
                ),
              if (_byCode)
                TextFormField(
                  controller: _codeController,
                  enabled: editable,
                  autofocus: widget.singleCode || widget.candidate != null,
                  autocorrect: false,
                  maxLength: 12,
                  decoration: const InputDecoration(
                    labelText: '取片码',
                    helperText: '6 位卡尾号或 12 位完整取片码',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() {
                    _code = value.trim().toUpperCase();
                    _error = null;
                  }),
                )
              else
                DropdownField<Json>(
                  label: '目标批次',
                  placeholder: '选择目标批次',
                  value: _target,
                  options: widget.targets,
                  labelFor: (target) => '${_label(target)} · ${_wall(target)}',
                  onChanged: editable
                      ? (target) => setState(() {
                          _target = target;
                          _error = null;
                        })
                      : null,
                ),
              if (_byCode && widget.barcode != null && widget.barcode != _code)
                TextButton(
                  onPressed: editable
                      ? () => setState(() {
                          _codeController.text = _code = widget.barcode!;
                          _error = null;
                        })
                      : null,
                  child: const Text('使用条形码完整码'),
                ),
            ],
            if (available)
              Semantics(
                liveRegion: true,
                child: Text(
                  '${count - _cardPhotoIds.length} 张游客照 · ${_cardPhotoIds.length} 张卡片照',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            if (_saving) const LinearProgressIndicator(minHeight: 2),
            if (_error case final String error)
              Text(error, style: const TextStyle(color: WorkstationStyle.bad)),
          ],
        ),
        actions: [
          OutlinedButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(available ? '取消' : '关闭'),
          ),
          if (available)
            FilledButton(
              onPressed: _saving || _fields == null ? null : _confirm,
              child: Text(_pending == null || _saving ? '确认归集' : '重试同一请求'),
            ),
        ],
      ),
    );
  }
}

typedef _SelectedGroup = ({Json batch, List<Json> photos});
typedef _Dragged = ({Json photo, Json batch});

DateTime _shanghaiToday() {
  final wall = DateTime.now().toUtc().add(const Duration(hours: 8));
  return DateTime.utc(wall.year, wall.month, wall.day);
}

String _dateLabel(DateTime date) => formatWallClock(date).substring(0, 10);
String _stationName(Json row) => "${row['code']} · ${row['name']}";
List<Json> _photos(Json batch) => (batch['photos'] as List).cast<Json>();
bool _isCardPhoto(Json photo) =>
    photo['ending'] != true && photo['assetRole'] == 'CARD';
bool _isVisitorPhoto(Json photo) =>
    photo['ending'] != true && !_isCardPhoto(photo);
String _photoType(Json photo) => photo['ending'] == true
    ? '结束照'
    : _isCardPhoto(photo)
    ? '卡片照'
    : '游客照';
bool _movable(Json photo) =>
    _isVisitorPhoto(photo) &&
    photo['ending'] == false &&
    photo['blockedReason'] == null;
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

Widget _thumbnail(Json photo) {
  const unavailable = Center(child: Icon(Icons.broken_image_outlined));
  final url = photo['thumbnailUrl'];
  if (url is! String || url.isEmpty) return unavailable;
  return Image.network(
    url,
    fit: BoxFit.contain,
    cacheWidth: 240,
    errorBuilder: (_, _, _) => unavailable,
  );
}

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
