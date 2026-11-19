import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../auto_upload/folder_access.dart';
import '../manual_batch/batch_workspace.dart';
import '../transfer.dart';

/// 摄影师确认批次的桌面工作区；任何识别或监听操作都不会上传。
class ManualBatchPanel extends StatefulWidget {
  final ServerProfile? Function() readProfile;
  final Future<void> Function(ServerProfile) saveProfile;
  final void Function(bool) onActiveChanged;
  final BatchWorkspace? workspace;
  const ManualBatchPanel({
    super.key,
    required this.readProfile,
    required this.saveProfile,
    required this.onActiveChanged,
    this.workspace,
  });
  @override
  State<ManualBatchPanel> createState() => _ManualBatchPanelState();
}

class _ManualBatchPanelState extends State<ManualBatchPanel> {
  final _access = FolderAccess();
  BatchWorkspace? _workspace;
  String _folder = '', _error = '';
  String? _selected;
  bool _working = false;
  bool get _locked => _working || _workspace?.uploading == true;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final work =
          widget.workspace ??
          BatchWorkspace(
            storage: Directory(
              p.join(
                (await getApplicationSupportDirectory()).path,
                'manual-batches',
              ),
            ),
          );
      if (widget.workspace == null) await work.open();
      if (!mounted) {
        await work.close();
        work.dispose();
        return;
      }
      _workspace = work;
      work.addListener(_refresh);
      _refresh();
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开批次工作区，请检查存储权限或其他应用窗口');
    }
  }

  void _refresh() {
    if (!mounted) return;
    final w = _workspace!;
    if (_selected == null && w.batches.isNotEmpty) {
      _selected = w.batches.first.id;
    }
    widget.onActiveChanged(w.watching || w.uploading);
    setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _working = true;
      _error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) _error = e is StateError ? e.message : '操作失败，请检查网络、文件及磁盘权限';
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _choose() => _run(() async {
    final folder = await _access.choose();
    if (folder != null) _folder = folder;
  });
  Future<void> _watch() => _run(() async {
    final w = _workspace!;
    if (w.watching) {
      await w.stopWatching();
      await _access.release();
    } else {
      if (_folder.isEmpty) throw StateError('请先选择接收文件夹');
      _folder = await _access.acquire(_folder);
      await w.startWatching(Directory(_folder));
    }
  });
  Future<void> _add({String? batchId}) => _run(() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'mpo'],
    );
    if (picked.any((f) => f.path == null)) throw StateError('部分图片无本地路径，请重新选择');
    await _workspace!.addFiles(
      picked.map((f) => File(f.path!)).toList(),
      batchId: batchId,
    );
  });
  Future<void> _upload(PhotoBatch batch) => _run(() async {
    final profile = widget.readProfile();
    if (profile == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认上传该批次'),
        content: Text(
          '已识别取片卡 · '
          '${batch.photoIds.length - 1} 张游客照和1张结束照。\n'
          '请核对卡片原图和游客照片。上传开始后成员固定，失败可重试同一批次。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续调整'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('上传此批次'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.saveProfile(profile);
    await _workspace!.uploadBatch(batch.id, profile);
  });
  @override
  void dispose() {
    final w = _workspace;
    w?.removeListener(_refresh);
    if (widget.workspace == null && w != null) {
      unawaited(w.close().whenComplete(w.dispose));
    }
    unawaited(_access.release());
    super.dispose();
  }

  Widget _photo(BatchPhoto photo, PhotoBatch? batch) {
    final ending = batch?.endPhotoId == photo.id;
    return SizedBox(
      width: 160,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    child: Stack(
                      children: [
                        InteractiveViewer(
                          child: Image.file(File(photo.snapshot)),
                        ),
                        Positioned(
                          right: 8,
                          top: 8,
                          child: IconButton(
                            tooltip: '关闭原图',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(photo.snapshot),
                    height: 100,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(
                      height: 100,
                      child: Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              ),
              Text(
                p.basename(photo.source),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                ending
                    ? '取片卡结束照'
                    : photo.secret == null
                    ? '游客照 · 待核对'
                    : '识别到卡片，请核对用途',
                style: const TextStyle(fontSize: 12),
              ),
              if (batch != null && batch.editable)
                Wrap(
                  children: [
                    TextButton(
                      onPressed: _locked
                          ? null
                          : () => _run(
                              () => _workspace!.setEnding(batch.id, photo.id),
                            ),
                      child: Text(ending ? '已选结束照' : '设为结束照'),
                    ),
                    TextButton(
                      onPressed: _locked
                          ? null
                          : () => _run(
                              () => _workspace!.removePhoto(batch.id, photo.id),
                            ),
                      child: const Text('移出批次'),
                    ),
                  ],
                ),
              if (batch == null && _selected != null)
                TextButton(
                  onPressed: _locked
                      ? null
                      : () => _run(
                          () => _workspace!.movePhoto(photo.id, _selected!),
                        ),
                  child: const Text('加入当前批次'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = _workspace;
    final batch = w?.batches.where((b) => b.id == _selected).firstOrNull;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '手动批次',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('本机辅助分组、识别条形码；摄影师核对并点击上传后才发送。移出照片仅回到待分组区。'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _locked || w == null || w.watching
                      ? null
                      : _choose,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择接收文件夹'),
                ),
                OutlinedButton(
                  onPressed: _locked || w == null ? null : _watch,
                  child: Text(w?.watching == true ? '停止收图' : '开始收图（不上传）'),
                ),
                OutlinedButton(
                  onPressed: _locked || w == null ? null : () => _add(),
                  child: const Text('添加照片'),
                ),
                OutlinedButton(
                  onPressed: _locked || w == null
                      ? null
                      : () => _run(() async {
                          await w.newBatch();
                          _selected = w.batches.last.id;
                        }),
                  child: const Text('新建批次'),
                ),
              ],
            ),
            if (_folder.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_folder),
              ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 12),
            Text(w?.message ?? '正在打开本机批次工作区…'),
            if (w != null && w.issues.isNotEmpty)
              Text('${w.issues.length} 张照片读取/识别失败，请检查后重新扫描'),
            if (w != null)
              Wrap(
                spacing: 8,
                children: [
                  for (var i = 0; i < w.batches.length; i++)
                    ChoiceChip(
                      label: Text(
                        '批次 ${i + 1} · ${w.batches[i].photoIds.length}张',
                      ),
                      selected: _selected == w.batches[i].id,
                      onSelected: _locked
                          ? null
                          : (_) => setState(() => _selected = w.batches[i].id),
                    ),
                ],
              ),
            if (batch != null && w != null) ...[
              const SizedBox(height: 16),
              Text(
                batch.secret == null
                    ? '取片卡未识别：请选择清晰结束照或补拍卡片'
                    : '已识别取片卡 · 请与卡片原图核对',
              ),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final id in batch.photoIds) _photo(w.photos[id]!, batch),
                ],
              ),
              if (batch.editable)
                OutlinedButton(
                  onPressed: _locked ? null : () => _add(batchId: batch.id),
                  child: const Text('给当前批次添加照片'),
                ),
              if (batch.state == 'uploading')
                LinearProgressIndicator(value: batch.progress),
              if (batch.state == 'submitted') const Text('已上传清单 · 等待服务器校验归卡'),
              if (batch.state == 'accepted') const Text('服务器已确认归卡'),
              if ([
                'submitted',
                'retry',
                'rejected',
                'accepted',
              ].contains(batch.state))
                OutlinedButton(
                  onPressed: _locked
                      ? null
                      : () => _run(() async {
                          final profile = widget.readProfile();
                          if (profile != null) {
                            await w.checkReceipt(batch.id, profile);
                          }
                        }),
                  child: const Text('检查服务器归卡结果'),
                ),
              if (batch.error.isNotEmpty)
                Text(batch.error, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed:
                    _locked ||
                        !['draft', 'retry'].contains(batch.state) ||
                        batch.secret == null ||
                        batch.photoIds.length < 2
                    ? null
                    : () => _upload(batch),
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text(batch.state == 'retry' ? '重试上传此批次' : '上传此批次'),
              ),
            ],
            if (w != null && w.unassigned.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text('待分组照片（移出照片保留在这里）'),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final photo in w.unassigned) _photo(photo, null),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
