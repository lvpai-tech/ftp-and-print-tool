import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../auto_upload/cos_upload.dart';
import '../auto_upload/folder_access.dart';
import '../auto_upload/folder_uploader.dart';
import '../branding.dart';
import 'card_tail_dialog.dart';
import 'design.dart';

class AutoUploadPanel extends StatefulWidget {
  final void Function(bool) onActiveChanged;
  final ValueChanged<bool>? onUploadingChanged;
  final CosUploadProfile cosProfile;
  final VoidCallback onConfigureCos;
  const AutoUploadPanel({
    super.key,
    required this.onActiveChanged,
    this.onUploadingChanged,
    required this.cosProfile,
    required this.onConfigureCos,
  });
  @override
  State<AutoUploadPanel> createState() => _AutoUploadPanelState();
}

class _AutoUploadPanelState extends State<AutoUploadPanel>
    with WidgetsBindingObserver {
  final _storage = const FlutterSecureStorage();
  final _access = FolderAccess();
  FolderUploader? _uploader;
  String _folder = '', _message = '';
  bool _recursive = true, _existing = false, _working = false, _loading = true;
  bool _backgrounded = false;
  bool get _active =>
      _uploader?.running == true ||
      _uploader?.stopping == true ||
      _uploader?.fatalError != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await _storage.read(key: 'ftp.watch.v1');
      if (!mounted) return;
      if (value != null) {
        final settings = jsonDecode(value) as Map<String, dynamic>;
        _folder = settings['folder'] as String;
        _recursive = settings['recursive'] as bool;
      }
      if (_access.apple) {
        final restored = await _access.restore();
        await _access.release();
        if (!mounted) return;
        _folder = restored ?? '';
      }
    } catch (_) {
      _message = '无法读取监听设置，请重新选择文件夹';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _choose() async {
    setState(() => _working = true);
    try {
      final folder = await _access.choose();
      if (mounted && folder != null) {
        setState(() {
          _folder = folder;
          _message = '';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = '文件夹选择失败，请检查访问权限');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _inbox() async {
    setState(() => _working = true);
    try {
      final folder = await _access.useInbox();
      if (mounted) {
        setState(() {
          _folder = folder;
          _message = '请在「文件 → 我的 iPad → $appBrandName → CameraInbox」放入照片';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = '无法创建本机收图目录，请检查存储空间');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isIOS) return;
    _backgrounded =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (_backgrounded && _active && !_working) unawaited(_toggle());
  }

  void _refresh() {
    widget.onUploadingChanged?.call(_uploader?.running == true);
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    if (_working) return;
    if (_active) {
      setState(() => _working = true);
      try {
        await _uploader!.stop();
        await _access.release();
        _uploader!.removeListener(_refresh);
        _uploader!.dispose();
        _uploader = null;
        _message = Platform.isIOS ? '监听已停止，队列已保存；回到前台后点击开始监听继续' : '已停止监听，队列已保存';
      } catch (_) {
        _message = '队列关闭失败，请检查磁盘权限并重新启动应用';
      } finally {
        if (mounted) {
          setState(() => _working = false);
          widget.onActiveChanged(_active);
        }
      }
      return;
    }
    final cosProfile = widget.cosProfile;
    if (_folder.isEmpty) {
      setState(() => _message = '请先选择接收照片的文件夹');
      return;
    }
    setState(() {
      _working = true;
      _message = '';
    });
    widget.onActiveChanged(true);
    FolderUploader? uploader;
    try {
      _folder = await _access.acquire(_folder);
      final directory = await getApplicationSupportDirectory();
      await _storage.write(
        key: 'ftp.watch.v1',
        value: jsonEncode({'folder': _folder, 'recursive': _recursive}),
      );
      uploader = FolderUploader(
        storage: Directory(p.join(directory.path, 'auto-upload')),
      );
      uploader.addListener(_refresh);
      _uploader = uploader;
      await uploader.start(
        Directory(_folder),
        null,
        cosProfile: cosProfile,
        recursive: _recursive,
        includeExisting: _existing,
      );
    } catch (_) {
      if (uploader != null) {
        uploader.removeListener(_refresh);
        try {
          await uploader.stop();
        } catch (_) {}
        uploader.dispose();
      }
      _uploader = null;
      _message = '无法启动：请检查文件夹、磁盘权限，或是否已有另一窗口监听相同来源和目标';
      try {
        await _access.release();
      } catch (_) {
        _message = '目录授权释放失败，请重新启动应用';
      }
    } finally {
      if (mounted) {
        setState(() => _working = false);
        widget.onActiveChanged(_active);
        if (_backgrounded && _active && !_working) unawaited(_toggle());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uploader?.removeListener(_refresh);
    final uploader = _uploader;
    unawaited(
      () async {
        try {
          await uploader?.stop();
        } finally {
          uploader?.dispose();
          await _access.release();
        }
      }().catchError((Object _) {}),
    );
    super.dispose();
  }

  String _status(AutoJob job) => switch (job.state) {
    'done' => '上传成功',
    'accepted' => '已上传 · 等待入库',
    'ingested' => '已入库 · 等待归卡',
    'grouped' => '已归卡',
    'uploading' => '上传中 ${(job.progress * 100).round()}%',
    'failed' => '失败 · ${job.error}',
    _ =>
      job.attempts == 0 ? '等待上传' : '等待自动重试（${job.attempts}/3） · ${job.error}',
  };

  Future<void> _pickCardPhoto() async {
    try {
      final photo = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'mpo'],
      );
      final path = photo.singleOrNull?.path;
      if (path == null || !mounted) return;
      await showCardTailDialog(
        context,
        readPhoto: File(path).readAsBytes,
        guidance: '请根据候选尾号核对卡面。归集由服务端识别结束照。',
      );
    } catch (_) {
      if (mounted) setState(() => _message = '无法选取照片，请检查文件访问权限');
    }
  }

  (Color, Color) _statusColors(AutoJob job) => switch (job.state) {
    'done' || 'grouped' => (WorkstationStyle.ok, WorkstationStyle.okSoft),
    'uploading' => (WorkstationStyle.accent, WorkstationStyle.accentSoft),
    'failed' => (WorkstationStyle.bad, WorkstationStyle.badSoft),
    _ => (WorkstationStyle.warn, WorkstationStyle.warnSoft),
  };

  @override
  Widget build(BuildContext context) {
    final supported =
        Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isIOS;
    final jobs = _uploader?.jobs ?? <AutoJob>[];
    final orderWait = _uploader?.orderWaitMessage;
    final unordered = _uploader?.sourcesNeedingOrder ?? const <String>[];
    final locked = _active || _working || _loading;
    final pending = jobs.where((j) => j.state == 'pending').length;
    final uploading = jobs.where((j) => j.state == 'uploading').length;
    final done = jobs
        .where(
          (j) => const {
            'done',
            'accepted',
            'ingested',
            'grouped',
          }.contains(j.state),
        )
        .length;
    final failed = jobs.where((j) => j.state == 'failed').length;

    return DecoratedBox(
      decoration: WorkstationStyle.surface(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Expanded(
                        child: Text(
                          '监听与上传',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: WorkstationStyle.ink,
                          ),
                        ),
                      ),
                      if (_active)
                        const StatusTag(
                          label: '监听中',
                          color: WorkstationStyle.ok,
                          soft: WorkstationStyle.okSoft,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '相机软件把照片保存到本地文件夹，本应用自动检测并批量上传。',
                    style: TextStyle(
                      color: WorkstationStyle.muted,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    _folder.isEmpty ? '尚未选择文件夹' : _folder,
                    style: TextStyle(
                      color: _folder.isEmpty
                          ? WorkstationStyle.muted
                          : WorkstationStyle.ink,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: locked || !supported ? null : _choose,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: Text(_folder.isEmpty ? '选择监听文件夹' : '更换文件夹'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: WorkstationStyle.ink,
                          side: const BorderSide(color: WorkstationStyle.line),
                          minimumSize: const Size(0, 40),
                        ),
                      ),
                      TextButton(
                        onPressed: locked ? null : widget.onConfigureCos,
                        child: const Text('COS 直传设置'),
                      ),
                      if (Platform.isIOS)
                        TextButton(
                          onPressed: locked ? null : _inbox,
                          child: const Text('使用本机收图文件夹'),
                        ),
                      FilterChip(
                        label: const Text('包含子文件夹'),
                        selected: _recursive,
                        onSelected: locked
                            ? null
                            : (value) => setState(() => _recursive = value),
                        selectedColor: WorkstationStyle.accentSoft,
                        checkmarkColor: WorkstationStyle.accent,
                      ),
                      FilterChip(
                        label: const Text('同时扫描已有照片'),
                        selected: _existing,
                        onSelected: locked
                            ? null
                            : (value) => setState(() => _existing = value),
                        selectedColor: WorkstationStyle.accentSoft,
                        checkmarkColor: WorkstationStyle.accent,
                      ),
                    ],
                  ),
                  if (Platform.isIOS) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'iPad 仅在前台监听。切换应用或锁屏后停止，回来点击开始监听补传。请使用已下载到本机的目录；相机软件须支持写入此授权目录。',
                      style: TextStyle(
                        color: WorkstationStyle.muted,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (!supported) ...[
                    const Text(
                      '当前平台不支持自动目录模式。',
                      style: TextStyle(color: WorkstationStyle.bad),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _pickCardPhoto,
                        child: const Text('从照片识别尾号'),
                      ),
                    ),
                  ],
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xfff8fafc),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: WorkstationStyle.line),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 18,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _Stat(
                              label: '待准备',
                              value: '${_uploader?.settling ?? 0}',
                              color: WorkstationStyle.muted,
                            ),
                            _Stat(
                              label: '上传中',
                              value: '$uploading',
                              color: WorkstationStyle.accent,
                            ),
                            _Stat(
                              label: '待传',
                              value: '$pending',
                              color: WorkstationStyle.warn,
                            ),
                            _Stat(
                              label: '已上传',
                              value: '$done',
                              color: WorkstationStyle.ok,
                            ),
                            _Stat(
                              label: '失败',
                              value: '$failed',
                              color: WorkstationStyle.bad,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: _working || _loading || !supported
                                  ? null
                                  : _toggle,
                              icon: Icon(
                                _active
                                    ? Icons.stop_circle_outlined
                                    : Icons.play_arrow,
                                size: 18,
                              ),
                              label: Text(
                                _working
                                    ? '处理中…'
                                    : _active
                                    ? '停止监听'
                                    : '开始监听',
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: _active
                                    ? WorkstationStyle.ink
                                    : WorkstationStyle.accent,
                                minimumSize: const Size(0, 40),
                              ),
                            ),
                            OutlinedButton(
                              onPressed:
                                  !_active ||
                                      _working ||
                                      _uploader?.running != true ||
                                      failed == 0
                                  ? null
                                  : () => _uploader!.retryFailed(),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 40),
                                foregroundColor: WorkstationStyle.bad,
                                side: BorderSide(
                                  color: failed == 0
                                      ? WorkstationStyle.line
                                      : WorkstationStyle.bad.withValues(
                                          alpha: .35,
                                        ),
                                ),
                              ),
                              child: const Text('重试失败任务'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _uploader?.fatalError ??
                          (_message.isNotEmpty
                              ? _message
                              : _uploader?.message ?? '尚未开始监听'),
                      style: const TextStyle(
                        color: WorkstationStyle.muted,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (_uploader?.watcherNotice.isNotEmpty == true)
                    Text(
                      _uploader!.watcherNotice,
                      style: const TextStyle(
                        color: WorkstationStyle.warn,
                        fontSize: 12,
                      ),
                    ),
                  if (orderWait != null)
                    Text(
                      orderWait,
                      style: const TextStyle(
                        color: WorkstationStyle.warn,
                        fontSize: 12,
                      ),
                    ),
                  if (unordered.isNotEmpty)
                    OutlinedButton(
                      onPressed: () async {
                        final source = await showDialog<String>(
                          context: context,
                          builder: (context) => SimpleDialog(
                            title: const Text('选择下一张上传的照片'),
                            children: [
                              for (final source in unordered)
                                SimpleDialogOption(
                                  onPressed: () =>
                                      Navigator.pop(context, source),
                                  child: Text(
                                    p.relative(source, from: _folder),
                                  ),
                                ),
                            ],
                          ),
                        );
                        if (mounted && source != null) {
                          _uploader?.confirmNextSource(source);
                        }
                      },
                      child: const Text('多张照片同时被发现，确认上传顺序'),
                    ),
                  ...?_uploader?.issues.entries
                      .take(8)
                      .map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '${p.basename(entry.key)}：${entry.value}',
                            style: const TextStyle(
                              color: WorkstationStyle.warn,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                  const SizedBox(height: 12),
                  const Row(
                    children: [
                      Text(
                        '任务列表',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: WorkstationStyle.ink,
                        ),
                      ),
                      SizedBox(width: 8),
                      Text(
                        '本地预览 · 按入队顺序',
                        style: TextStyle(
                          color: WorkstationStyle.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (jobs.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          '新照片到达后，会自动显示在这里',
                          style: TextStyle(color: WorkstationStyle.muted),
                        ),
                      ),
                    )
                  else ...[
                    for (var index = 0; index < jobs.length; index++) ...[
                      if (index > 0) const SizedBox(height: 10),
                      Builder(
                        builder: (context) {
                          final job = jobs[index];
                          final colors = _statusColors(job);
                          return _JobThumbRow(
                            job: job,
                            status: _status(job),
                            color: colors.$1,
                            soft: colors.$2,
                            onReview: () => showCardTailDialog(
                              context,
                              readPhoto: job.readPhotoForReview,
                              guidance: '请根据候选尾号核对卡面。归集由服务端识别结束照。',
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'JPEG / PNG / MPO · 按发现顺序排队，写入稳定且可解码后上传。前一张入库后继续，失败可重试。退出后保留队列和相机原图。',
                    style: TextStyle(
                      fontSize: 12,
                      color: WorkstationStyle.muted,
                      height: 1.4,
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

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color});
  final String label, value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(color: WorkstationStyle.muted, fontSize: 13),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _JobThumbRow extends StatelessWidget {
  const _JobThumbRow({
    required this.job,
    required this.status,
    required this.color,
    required this.soft,
    required this.onReview,
  });

  final AutoJob job;
  final String status;
  final Color color;
  final Color soft;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: WorkstationStyle.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: WorkstationStyle.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            _LocalThumb(job: job),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.relative,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: WorkstationStyle.ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (job.state == 'uploading')
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: job.progress,
                        minHeight: 6,
                        backgroundColor: WorkstationStyle.accentSoft,
                        color: WorkstationStyle.accent,
                      ),
                    )
                  else
                    StatusTag(label: status, color: color, soft: soft),
                ],
              ),
            ),
            if (job.state == 'uploading') ...[
              const SizedBox(width: 10),
              StatusTag(label: status, color: color, soft: soft),
            ],
            IconButton(
              tooltip: '识别取片卡尾号',
              onPressed: onReview,
              icon: const Icon(Icons.document_scanner_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalThumb extends StatelessWidget {
  const _LocalThumb({required this.job});
  final AutoJob job;

  Widget _placeholder() {
    final done = const {'done', 'ingested', 'grouped'}.contains(job.state);
    return ColoredBox(
      color: const Color(0xfff1f5f9),
      child: Icon(
        done ? Icons.check_circle_outline : Icons.photo_outlined,
        color: done ? WorkstationStyle.ok : WorkstationStyle.muted,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: SizedBox(
        width: 72,
        height: 72,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(job.snapshot),
              width: 72,
              height: 72,
              fit: BoxFit.cover,
              cacheWidth: 144,
              errorBuilder: (context, error, stackTrace) => Image.file(
                File(job.source),
                width: 72,
                height: 72,
                fit: BoxFit.cover,
                cacheWidth: 144,
                errorBuilder: (context, error, stackTrace) => _placeholder(),
              ),
            ),
            if (const {'done', 'ingested', 'grouped'}.contains(job.state))
              const Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(
                    Icons.check_circle,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
