import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../auto_upload/cos_upload.dart';
import '../auto_upload/station_upload.dart';
import '../auto_upload/upload_folders.dart';
import '../auto_upload/upload_slots.dart';
import '../branding.dart';
import '../printing/print_bridge.dart';
import '../printing/ui/photo_batch_page.dart';
import '../profile_store.dart';
import '../workstation_session.dart';
import 'app_dialogs.dart';
import 'auto_upload_panel.dart';
import 'cos_upload_dialog.dart';
import 'design.dart';
import 'update_button.dart';
import 'workstation_enrollment_panel.dart';

class TransferPage extends StatefulWidget {
  const TransferPage({
    super.key,
    this.embedded = false,
    this.visible = true,
    this.onActiveChanged,
    this.onUploadingChanged,
    this.onConfiguredChanged,
    this.printBridge,
    this.supportDirectory,
    this.session,
  });

  final bool embedded;
  final bool visible;
  final ValueChanged<bool>? onActiveChanged;
  final ValueChanged<bool>? onUploadingChanged;
  final ValueChanged<bool>? onConfiguredChanged;
  final PrintBridge? printBridge;
  final Future<Directory> Function()? supportDirectory;
  final WorkstationSession? session;

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage>
    with WidgetsBindingObserver {
  final _store = const ProfileStore();
  final _api = CosUploadProfile.tryParseApiBase(workstationUploadApiBase);
  final _stations = <String, StationUpload>{};
  final _removing = <StationUpload>{};
  final _transferSlots = UploadSlots(3);
  final _preparationSlots = UploadSlots(2);
  Directory? _support, _inbox;
  UploadFolders? _folders;
  StationUpload? _selected;
  bool _loading = true;
  bool _refreshing = false;
  bool _configuring = false;
  bool _foreground = true;
  bool _pausedForUpdate = false;
  bool? _configuredReported;
  bool _activeReported = false, _uploadingReported = false;
  String? _error;
  Future<void> _stationChanges = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session?.updateUploads = _pauseForUpdate;
    unawaited(_load());
  }

  @override
  void didUpdateWidget(TransferPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.visible) _selected = null;
  }

  Future<void> _load() async {
    try {
      final api = _api;
      if (api == null) throw StateError('上传服务地址无效，请联系管理员');
      await _store.migrateUploads(api);
      await _reloadStations();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is StateError ? error.message : '无法读取机位配置，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _changeStations(Future<void> Function() change) {
    final next = _stationChanges.then((_) => change());
    _stationChanges = next.catchError((Object _) {});
    return next;
  }

  Future<void> _pauseForUpdate(bool paused) => _changeStations(() async {
    _pausedForUpdate = paused;
    await Future.wait(
      _stations.values.map(
        (station) => paused ? station.suspendForUpdate() : station.resume(),
      ),
    );
  });

  Future<void> _reloadStations() => _changeStations(() async {
    if (!mounted) return;
    final profiles = await _store.loadStations(_api!);
    if (profiles.isNotEmpty) {
      final support = _support ??=
          await (widget.supportDirectory ?? getApplicationSupportDirectory)();
      _inbox ??= Directory(
        p.join(
          Platform.isIOS
              ? (await getApplicationDocumentsDirectory()).path
              : support.path,
          Platform.isIOS ? 'CameraInbox' : 'inbox',
        ),
      );
      _folders ??= UploadFolders(
        _store,
        _inbox!,
        Directory(p.join(support.path, 'auto-upload')),
      );
    }
    if (!mounted) return;
    final savedIds = profiles.map((profile) => profile.stationId).toSet();
    for (final id in _stations.keys.toList()) {
      if (!savedIds.contains(id)) _forgetStation(id);
    }
    final starts = <Future<void>>[];
    for (final profile in profiles) {
      final previous = _stations[profile.stationId];
      if (previous != null) {
        if (!mapEquals(previous.profile.toJson(), profile.toJson())) {
          starts.add(
            previous.replaceProfile(
              profile,
              start: _foreground && !_pausedForUpdate,
            ),
          );
        }
        continue;
      }
      final settings = await _store.loadWatch(profile);
      if (!mounted) return;
      final station = StationUpload(
        profile: profile,
        store: _store,
        support: _support!,
        inboxRoot: _inbox!,
        settings: settings,
        folders: _folders,
        transferSlots: _transferSlots,
        preparationSlots: _preparationSlots,
      )..addListener(_refresh);
      _stations[profile.stationId] = station;
      if (_foreground && !_pausedForUpdate) starts.add(station.restore());
    }
    _error = null;
    _loading = false;
    _refresh();
    await Future.wait(starts);
  });

  void _refresh() {
    if (!mounted) return;
    final configured = _stations.isNotEmpty;
    final active = _stations.values.any((station) => station.active);
    final uploading = _stations.values.any((station) => station.uploading);
    if (_configuredReported != configured) {
      _configuredReported = configured;
      widget.onConfiguredChanged?.call(configured);
    }
    if (_activeReported != active) {
      _activeReported = active;
      widget.onActiveChanged?.call(active);
    }
    if (_uploadingReported != uploading) {
      _uploadingReported = uploading;
      widget.onUploadingChanged?.call(uploading);
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isIOS) return;
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    for (final station in _stations.values) {
      if (_removing.contains(station)) continue;
      unawaited(foreground ? station.resume() : station.suspend());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session?.updateUploads = null;
    for (final station in _stations.values) {
      station.removeListener(_refresh);
      station.dispose();
    }
    super.dispose();
  }

  Future<void> _configure([StationUpload? station]) async {
    final api = _api;
    if (_configuring || api == null) return;
    _configuring = true;
    try {
      final profile = await showDialog<CosUploadProfile>(
        context: context,
        builder: (_) => CosUploadDialog(api: api, initial: station?.profile),
      );
      if (profile == null || !mounted) return;
      if (station == null && _stations.containsKey(profile.stationId)) {
        await showAppMessage(context, message: '该机位已绑定。请在对应机位详情更新密钥。');
        return;
      }
      await _store.saveCos(profile);
      await _reloadStations();
    } catch (_) {
      if (mounted) {
        await showAppMessage(context, message: '无法保存或读取机位配置，请检查系统安全存储权限后重试。');
      }
    } finally {
      _configuring = false;
    }
  }

  String _stationLabel(StationUpload station) =>
      station.name.isEmpty ? '机位 ${station.profile.stationId}' : station.name;

  void _forgetStation(String id) {
    final station = _stations.remove(id);
    if (station == null) return;
    if (_selected == station) _selected = null;
    station.removeListener(_refresh);
    station.dispose();
  }

  Future<void> _refreshStations() async {
    setState(() => _refreshing = true);
    try {
      await _reloadStations();
    } catch (_) {
      if (mounted) setState(() => _error = '无法刷新机位列表，请重试');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _removeStation(StationUpload station) async {
    final confirmed = await showAppConfirm(
      context,
      title: '从本机移除机位？',
      message:
          '移除「${_stationLabel(station)}」会停止这台电脑上的监听。'
          '收图目录、照片和待传队列会保留，后台机位仍可使用。',
      action: '确认移除',
    );
    if (!confirmed || !mounted) return;
    setState(() => _removing.add(station));
    try {
      await _changeStations(() async {
        final id = station.profile.stationId;
        if (!mounted || _stations[id] != station) return;
        final restartOnFailure = station.running;
        if (station.active) {
          await station.suspend();
          if (station.active || station.message != null) {
            throw StateError(station.message ?? '机位尚未停止，请重试');
          }
        }
        try {
          await _store.removeCos(station.profile);
        } catch (_) {
          if (restartOnFailure && mounted && _foreground) {
            await station.resume();
          }
          rethrow;
        }
        if (!mounted) return;
        _forgetStation(id);
        _refresh();
      });
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          message: error is StateError
              ? error.message
              : '无法移除机位，请检查系统安全存储权限后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _removing.remove(station));
    }
  }

  Widget _list() {
    final stations = _stations.values.toList()
      ..sort(
        (a, b) => (a.profile.stationCode ?? a.profile.stationId).compareTo(
          b.profile.stationCode ?? b.profile.stationId,
        ),
      );
    final api = _api;
    final active = stations.where((station) => station.running).length;
    final uploading = stations.where((station) => station.uploading).length;
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '上传机位',
              style: TextStyle(
                color: WorkstationStyle.ink,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (api != null)
              TextButton.icon(
                onPressed: _refreshing ? null : _refreshStations,
                icon: const Icon(Icons.refresh),
                label: Text(_refreshing ? '正在刷新…' : '刷新机位'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_error case final String error) ...[
          Text(error, style: const TextStyle(color: WorkstationStyle.bad)),
          if (api != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: _load, child: const Text('重试读取机位')),
            ),
        ] else
          Text(
            stations.isEmpty
                ? '这台电脑还没有绑定机位。申请或绑定后可选择收图文件夹。'
                : '已绑定 ${stations.length} 个机位 · $active 个监听中 · $uploading 个上传中',
          ),
        const SizedBox(height: 16),
        if (api != null)
          WorkstationEnrollmentPanel(
            api: api,
            store: _store,
            onBound: _reloadStations,
            onManual: _configure,
          ),
        for (final station in stations)
          Padding(
            key: ValueKey(station.profile.stationId),
            padding: const EdgeInsets.only(top: 12),
            child: Material(
              color: WorkstationStyle.card,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(WorkstationStyle.radius),
                side: const BorderSide(color: WorkstationStyle.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                title: Text(_stationLabel(station)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    StatusTag(
                      label: station.running ? '运行中' : '未运行',
                      color: station.running
                          ? WorkstationStyle.ok
                          : WorkstationStyle.muted,
                      soft: station.running
                          ? WorkstationStyle.okSoft
                          : WorkstationStyle.bg,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (station.profile.scenicName case final String name)
                          name,
                        if (_removing.contains(station))
                          '正在移除…'
                        else if (!const {'监听中', '已暂停'}.contains(station.status))
                          station.status,
                        '待传 ${station.pending} · 异常 ${station.failures}',
                        if (station.latestIngested case final DateTime time)
                          '最近入库 ${MaterialLocalizations.of(context).formatShortDate(time)} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(time), alwaysUse24HourFormat: true)}',
                      ].join('  ·  '),
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: '机位操作',
                      enabled: !_removing.contains(station),
                      onSelected: (_) => unawaited(_removeStation(station)),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'remove', child: Text('从本机移除')),
                      ],
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: _removing.contains(station)
                    ? null
                    : () => setState(() => _selected = station),
              ),
            ),
          ),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final station = _selected;
    return PopScope(
      canPop: !widget.visible || station == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.visible && station != null) {
          setState(() => _selected = null);
        }
      },
      child: IndexedStack(
        index: station == null ? 0 : 1,
        sizing: StackFit.expand,
        children: [
          _list(),
          if (station != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _selected = null),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: const Text('返回机位列表'),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: AutoUploadPanel(
                    key: ValueKey(station.profile.stationId),
                    station: station,
                    allowDrop: widget.visible,
                    onConfigureCos: () => _configure(station),
                    batchTimeline: _batchTimeline(station.profile),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget? _batchTimeline(CosUploadProfile profile) {
    final bridge = widget.printBridge;
    if (bridge == null) return null;
    return ListenableBuilder(
      listenable: bridge,
      builder: (context, _) {
        final config = bridge.config;
        final scenicIds = config['scenicIds'] as List?;
        final wrongScenic =
            profile.scenicId != null &&
            scenicIds?.isNotEmpty == true &&
            !scenicIds!.any((id) => id.toString() == profile.scenicId);
        if (!bridge.connected || !bridge.configured || wrongScenic) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                wrongScenic
                    ? '请切换到该机位所属景区的打印档案后查看取片批次。'
                    : '取片批次需要打印工作台连接景区后查看。',
                style: const TextStyle(
                  color: WorkstationStyle.muted,
                  fontSize: 12,
                ),
              ),
            ),
          );
        }
        final scenicName = (config['scenicName'] as String?)?.trim();
        return PhotoBatchTimeline.inline(
          key: ValueKey((
            bridge,
            config['activeScenicProfileId'],
            config['scenicCode'],
            profile.stationId,
          )),
          call: bridge.call,
          scenicName: scenicName?.isNotEmpty == true ? scenicName! : '（未返回名称）',
          stationId: profile.stationId,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: widget.embedded
        ? null
        : AppBar(
            title: const Text('$appBrandName · 照片传输'),
            actions: const [UpdateButton()],
          ),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            child: _body(),
          ),
        ),
      ),
    ),
  );
}
