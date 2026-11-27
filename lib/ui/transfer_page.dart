import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../auto_upload/cos_upload.dart';
import '../auto_upload/station_photo_batches.dart';
import '../auto_upload/station_upload.dart';
import '../auto_upload/upload_folders.dart';
import '../auto_upload/upload_slots.dart';
import '../branding.dart';
import '../printing/ui/photo_batch_page.dart';
import '../profile_store.dart';
import '../workstation_account.dart';
import '../workstation_session.dart';
import '../workstation_storage.dart';
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
    this.batchClient,
    this.supportDirectory,
    this.session,
  });

  final bool embedded;
  final bool visible;
  final ValueChanged<bool>? onActiveChanged;
  final ValueChanged<bool>? onUploadingChanged;
  final ValueChanged<bool>? onConfiguredChanged;
  final http.Client? batchClient;
  final Future<Directory> Function()? supportDirectory;
  final WorkstationSession? session;

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage>
    with WidgetsBindingObserver {
  final _store = const ProfileStore();
  final _api = CosUploadProfile.tryParseApiBase(workstationUploadApiBase);
  final _enrollmentPanel = GlobalKey<WorkstationEnrollmentPanelState>();
  final _stations = <String, StationUpload>{};
  final _removing = <StationUpload>{};
  final _transferSlots = UploadSlots(3);
  final _preparationSlots = UploadSlots(2);
  late final _batchClient = widget.batchClient ?? http.Client();
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
    if (!_loading) setState(() => _loading = true);
    try {
      await widget.session?.checkUploadStorage?.call();
      final api = _api;
      if (api == null) throw StateError('上传服务地址无效，请联系管理员');
      await _store.migrateUploads(api);
      await _reloadStations();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = switch (error) {
            StateError(:final message) => message,
            WorkstationAccountError(:final message) => message,
            PlatformException(code: 'KEYCHAIN') when Platform.isMacOS =>
              macWorkstationStorageError(error).message,
            _ => '无法读取机位配置，请重试',
          };
        });
        _refresh();
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

  Future<void> _stopOtherStations() => _changeStations(() async {
    final scenicId = widget.session?.scenic?.id;
    await Future.wait(
      _stations.values
          .where(
            (station) =>
                station.profile.scenicId != scenicId &&
                (station.active || station.enabled),
          )
          .map((station) => station.setEnabled(false)),
    );
  });

  Future<void> _reloadStations() => _changeStations(() async {
    if (!mounted) return;
    final saved = await _store.loadStations(_api!);
    final account = widget.session?.account;
    final profiles = account == null
        ? saved
        : (await Future.wait(
            saved.map((profile) async {
              try {
                final details = await account.stationDetails(profile);
                return CosUploadProfile(
                  profile.api.origin,
                  profile.stationId,
                  profile.token,
                  stationName: details.name,
                  stationCode: details.code,
                  scenicId: details.scenic.id,
                  scenicName: details.scenic.name,
                );
              } on WorkstationAccountError catch (error) {
                if (!error.deniedDevice) rethrow;
                return null;
              }
            }),
          )).whereType<CosUploadProfile>().toList();
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
        personnelToken: account == null
            ? null
            : () => widget.session?.personnelToken,
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
    widget.session?.activeStations = _stations.values
        .where((station) => station.active || station.uploading || station.busy)
        .map(_stationLabel)
        .toList();
    widget.session?.setTransferIssue(
      _error != null
          ? '上传配置需要处理'
          : _stations.values.any((station) => station.folderUnavailable)
          ? '收图目录需要处理'
          : null,
    );
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
    if (widget.batchClient == null) _batchClient.close();
    for (final station in _stations.values) {
      station.removeListener(_refresh);
      station.dispose();
    }
    super.dispose();
  }

  Future<void> _configure([StationUpload? station]) async {
    if (widget.session?.closingWorkspace == true) return;
    final api = _api;
    if (_configuring || _loading || _error != null || api == null) return;
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
      final account = widget.session?.account;
      if (account != null) {
        final details = await account.stationDetails(profile);
        if (details.scenic.id != widget.session?.scenic?.id) {
          throw const WorkstationAccountError('机位不属于当前工作景区');
        }
      }
      await _store.saveCos(profile);
      await _reloadStations();
    } on WorkstationAccountError catch (error) {
      if (mounted) await showAppMessage(context, message: error.message);
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
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final applicationsSynced = await _enrollmentPanel.currentState
          ?.refreshApplications();
      await _reloadStations();
      if (mounted && applicationsSynced == false) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('机位申请同步失败，请在申请记录中查看或重试。')));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is WorkstationAccountError
              ? error.message
              : '无法刷新机位列表，请重试';
        });
      }
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
    final scenicId = widget.session?.scenic?.id;
    final stations =
        _stations.values
            .where(
              (station) =>
                  scenicId == null || station.profile.scenicId == scenicId,
            )
            .toList()
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
        if (api != null && _error == null)
          WorkstationEnrollmentPanel(
            key: _enrollmentPanel,
            api: api,
            store: _store,
            onBound: _reloadStations,
            session: widget.session,
            onManual: _configure,
          ),
        if (scenicId != null &&
            _stations.values.any(
              (station) =>
                  station.active && station.profile.scenicId != scenicId,
            ))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                try {
                  await _stopOtherStations();
                } catch (_) {
                  if (mounted) {
                    await showAppMessage(context, message: '无法停止其他景区的监听，请重试。');
                  }
                }
              },
              child: const Text('停止其他景区监听'),
            ),
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
                    : () => setState(() {
                        _selected = station;
                      }),
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
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: WorkstationStyle.muted,
                    ),
                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
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
                    batchTimeline: _batchTimeline(station),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _batchTimeline(StationUpload station) {
    return ListenableBuilder(
      listenable: station,
      builder: (context, _) {
        final profile = station.profile;
        final batches = StationPhotoBatches(
          _batchClient,
          profile,
          station.personnelToken,
        );
        var ingested = 0;
        var grouped = 0;
        for (final job in station.uploader.jobs) {
          if (job.state == 'ingested') ingested++;
          if (job.state == 'grouped') grouped++;
        }
        return PhotoBatchTimeline.inline(
          key: ValueKey(profile),
          call: batches.call,
          scenicName: profile.scenicName ?? '当前机位',
          stationId: profile.stationId,
          uploadProgress: (ingested: ingested, grouped: grouped),
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
          constraints: BoxConstraints(
            maxWidth: _selected == null ? 1120 : 1320,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              _selected == null ? 20 : 8,
              16,
              24,
            ),
            child: _body(),
          ),
        ),
      ),
    ),
  );
}
