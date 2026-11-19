import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../auto_upload/folder_uploader.dart';
import '../auto_upload/folder_access.dart';
import '../transfer.dart';

class AutoUploadPanel extends StatefulWidget {
  final ServerProfile? Function() readProfile;
  final Future<void> Function(ServerProfile) saveProfile;
  final void Function(bool) onActiveChanged;
  const AutoUploadPanel({
    super.key,
    required this.readProfile,
    required this.saveProfile,
    required this.onActiveChanged,
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
          _message = '请在「文件 → 我的 iPad → 旅派 FTP → CameraInbox」放入照片';
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
    final profile = widget.readProfile();
    if (profile == null) return;
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
      await widget.saveProfile(profile);
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
        profile,
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
    'uploading' => '上传中 ${(job.progress * 100).round()}%',
    'failed' => '失败 · ${job.error}',
    _ =>
      job.attempts == 0 ? '等待上传' : '等待自动重试（${job.attempts}/3） · ${job.error}',
  };

  @override
  Widget build(BuildContext context) {
    final supported =
        Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isIOS;
    final jobs = _uploader?.jobs ?? <AutoJob>[];
    final locked = _active || _working || _loading;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '自动监听',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('相机软件把照片保存到本地文件夹，本应用自动检测并批量上传。'),
            const SizedBox(height: 20),
            SelectableText(_folder.isEmpty ? '尚未选择文件夹' : _folder),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: locked || !supported ? null : _choose,
                icon: const Icon(Icons.folder_open),
                label: const Text('选择监听文件夹'),
              ),
            ),
            if (Platform.isIOS) ...[
              TextButton(
                onPressed: locked ? null : _inbox,
                child: const Text('使用本机收图文件夹'),
              ),
              const Text(
                'iPad 仅在前台监听。切换应用或锁屏后停止，回来点击开始监听补传。请使用已下载到本机的目录；相机软件须支持写入此授权目录。',
              ),
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('包含子文件夹'),
              value: _recursive,
              onChanged: locked
                  ? null
                  : (value) => setState(() => _recursive = value!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('同时扫描已有照片'),
              subtitle: const Text('默认只接收新增照片；重新启动会补传离线期间新增的照片。'),
              value: _existing,
              onChanged: locked
                  ? null
                  : (value) => setState(() => _existing = value!),
            ),
            const Text(
              'JPEG / PNG / MPO · 保留相对目录与相机源文件 · 写入稳定且可解码后入队 · 最多自动尝试3次',
            ),
            const SizedBox(height: 16),
            if (!supported) const Text('当前平台不支持自动目录模式。'),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _working || _loading || !supported
                      ? null
                      : _toggle,
                  icon: Icon(
                    _active ? Icons.stop_circle_outlined : Icons.play_arrow,
                  ),
                  label: Text(
                    _working
                        ? '处理中…'
                        : _active
                        ? '停止监听'
                        : '开始监听',
                  ),
                ),
                OutlinedButton(
                  onPressed: !_active || _working || _uploader?.running != true
                      ? null
                      : () => _uploader!.retryFailed(),
                  child: const Text('重试失败任务'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Semantics(
              liveRegion: true,
              child: Text(
                _uploader?.fatalError ??
                    (_message.isNotEmpty
                        ? _message
                        : _uploader?.message ?? '尚未开始监听'),
              ),
            ),
            if (_uploader?.watcherNotice.isNotEmpty == true)
              Text(_uploader!.watcherNotice),
            const SizedBox(height: 12),
            Text(
              '等待写入 ${_uploader?.settling ?? 0}  · 待传 ${jobs.where((j) => j.state == 'pending').length}'
              '  · 成功 ${jobs.where((j) => j.state == 'done').length}  · 失败 ${jobs.where((j) => j.state == 'failed').length}',
            ),
            ...?_uploader?.issues.entries
                .take(8)
                .map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('${p.basename(entry.key)}：${entry.value}'),
                  ),
                ),
            const SizedBox(height: 12),
            if (jobs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: Text('新照片到达后，会自动显示在这里')),
              ),
            if (jobs.isNotEmpty)
              SizedBox(
                height: 360,
                child: ListView.builder(
                  itemCount: jobs.length,
                  itemBuilder: (context, index) {
                    final job = jobs[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        job.state == 'done'
                            ? Icons.check_circle_outline
                            : Icons.photo_outlined,
                      ),
                      title: Text(
                        job.relative,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_status(job)),
                          if (job.state == 'uploading')
                            LinearProgressIndicator(value: job.progress),
                        ],
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              '停止后当前照片会完成上传。应用退出后不再监听，下次点击开始监听恢复队列。上传后不删除相机原图。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
