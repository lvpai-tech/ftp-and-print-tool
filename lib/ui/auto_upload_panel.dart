import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../auto_upload/station_upload.dart';
import '../photo_normalizer.dart';
import 'app_dialogs.dart';
import 'card_tail_dialog.dart';
import 'design.dart';
import 'upload_task_list.dart';

class AutoUploadPanel extends StatefulWidget {
  final StationUpload station;
  final VoidCallback onConfigureCos;
  final Widget? batchTimeline;
  final bool allowDrop;

  const AutoUploadPanel({
    super.key,
    required this.station,
    required this.onConfigureCos,
    this.batchTimeline,
    this.allowDrop = true,
  });

  @override
  State<AutoUploadPanel> createState() => _AutoUploadPanelState();
}

class _AutoUploadPanelState extends State<AutoUploadPanel> {
  StationUpload get station => widget.station;
  String get _folder => station.folder;
  bool _picking = false;
  bool _dragging = false;
  bool _scanLegacyExisting = false;
  bool get _canDrop =>
      widget.allowDrop &&
      !station.legacy &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
      !_picking &&
      !station.busy &&
      ModalRoute.of(context)?.isCurrent != false;

  Future<void> _dropPhotos(DropDoneDetails details) async {
    if (!_canDrop) return;
    setState(() {
      _dragging = false;
      _picking = true;
    });
    final bookmarks = <Uint8List>[];
    final drop = DesktopDrop.instance;
    try {
      final files = details.files.whereType<DropItemFile>().toList();
      if (files.isEmpty || files.length != details.files.length) {
        throw StateError('请拖入照片文件');
      }
      if (Platform.isMacOS) {
        for (final file in files) {
          final bookmark = file.extraAppleBookmark;
          if (bookmark != null &&
              bookmark.isNotEmpty &&
              await drop.startAccessingSecurityScopedResource(
                bookmark: bookmark,
              )) {
            bookmarks.add(bookmark);
          }
        }
      }
      await station.importPhotos(files.map((file) => File(file.path)).toList());
    } catch (error) {
      if (mounted) {
        await showAppMessage(context, message: appErrorMessage(error));
      }
    } finally {
      try {
        for (final bookmark in bookmarks) {
          await drop.stopAccessingSecurityScopedResource(bookmark: bookmark);
        }
      } finally {
        if (mounted) setState(() => _picking = false);
      }
    }
  }

  Future<void> _importPhotos() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: cameraPhotoExtensions,
      );
      if (result.isEmpty || !mounted) return;
      if (result.any((file) => file.path == null)) {
        await showAppMessage(context, message: '部分照片无法读取，请先下载到本机再导入。');
        return;
      }
      await station.importPhotos(
        result.map((file) => File(file.path!)).toList(),
      );
    } catch (_) {
      if (mounted) await showAppMessage(context, message: '无法打开照片，请检查文件访问权限。');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _copyFolder() async {
    await Clipboard.setData(ClipboardData(text: _folder));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制收图路径')));
    }
  }

  Future<void> _openFolder() async {
    try {
      if (await launchUrl(
        p.toUri(_folder),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // 系统无法打开时保留可复制路径。
    }
    if (mounted) {
      await showAppMessage(
        context,
        message: '无法打开文件夹。请复制路径后在文件管理器中打开。\n\n$_folder',
      );
    }
  }

  Future<void> _finishMigration() async {
    final confirmed = await showAppConfirm(
      context,
      title: '切换到托管收图目录',
      message: '请在两个拍摄批次之间操作。先停止向旧目录投递照片，待旧队列处理完毕后切换。',
      action: '确认切换',
    );
    if (confirmed && mounted) await station.finishMigration();
  }

  Future<void> _pickCardPhoto() async {
    try {
      final photo = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: cameraPhotoExtensions,
      );
      final path = photo.singleOrNull?.path;
      if (path == null || !mounted) return;
      await showCardTailDialog(
        context,
        readPhoto: () async =>
            normalizedCameraPhoto(await File(path).readAsBytes(), path),
        guidance: '请根据候选尾号核对卡面。归集由服务端识别结束照。',
      );
    } catch (_) {
      if (mounted) await showAppMessage(context, message: '无法选取照片，请检查文件访问权限');
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported =
        Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isIOS;
    final uploader = station.uploader;
    final active = uploader.running && !uploader.authorizationPaused;
    final working = station.busy || _picking;
    final jobs = uploader.jobs;
    final orderWait = uploader.orderWaitMessage;

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
    final stationLabel = [
      station.profile.scenicName,
      station.profile.stationName,
      station.profile.stationCode,
    ].whereType<String>().where((name) => name.isNotEmpty).join(' · ');

    return DecoratedBox(
      decoration: WorkstationStyle.surface(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
        child: CustomScrollView(
          slivers: [
            SliverList.list(
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
                    if (active)
                      const StatusTag(
                        label: '监听中',
                        color: WorkstationStyle.ok,
                        soft: WorkstationStyle.okSoft,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                if (stationLabel.isNotEmpty) Text(stationLabel),
                const Text(
                  '把相机软件的导出目标设为这个机位的收图文件夹。',
                  style: TextStyle(
                    color: WorkstationStyle.muted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                SelectableText(
                  _folder,
                  style: TextStyle(
                    color: _folder.isEmpty
                        ? WorkstationStyle.muted
                        : WorkstationStyle.ink,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                if ((Platform.isWindows ||
                        Platform.isMacOS ||
                        Platform.isLinux) &&
                    !station.legacy) ...[
                  DropTarget(
                    enable: _canDrop,
                    onDragEntered: (_) => setState(() => _dragging = true),
                    onDragExited: (_) => setState(() => _dragging = false),
                    onDragDone: _dropPhotos,
                    child: InkWell(
                      onTap: working ? null : _importPhotos,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _dragging && _canDrop
                              ? WorkstationStyle.accentSoft
                              : null,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _dragging && _canDrop
                                ? WorkstationStyle.accent
                                : WorkstationStyle.line,
                          ),
                        ),
                        child: const Text('拖入照片到这个机位'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: working || !supported || station.legacy
                          ? null
                          : _importPhotos,
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 18,
                      ),
                      label: Text(_picking ? '选择照片中…' : '导入照片'),
                    ),
                    if (!Platform.isIOS)
                      OutlinedButton.icon(
                        onPressed: working || !supported ? null : _openFolder,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('打开收图文件夹'),
                      ),
                    TextButton(
                      onPressed: _copyFolder,
                      child: const Text('复制路径'),
                    ),
                    TextButton(
                      onPressed: working ? null : widget.onConfigureCos,
                      child: const Text('更新机位密钥'),
                    ),
                    if (station.legacy)
                      TextButton(
                        onPressed: working || !supported
                            ? null
                            : _finishMigration,
                        child: const Text('切换到托管目录'),
                      ),
                    if (station.legacy && !uploader.running)
                      FilterChip(
                        label: const Text('补扫旧目录已有照片'),
                        selected: _scanLegacyExisting,
                        onSelected: working
                            ? null
                            : (value) =>
                                  setState(() => _scanLegacyExisting = value),
                      ),
                  ],
                ),
                if (Platform.isIOS) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'iPad 在前台收图，回到应用后会继续未完成任务。',
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
                            value: '${uploader.settling}',
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
                            onPressed: working || !supported
                                ? null
                                : () => station.setEnabled(
                                    !uploader.running,
                                    scanLegacyExisting: _scanLegacyExisting,
                                  ),
                            icon: Icon(
                              active
                                  ? Icons.stop_circle_outlined
                                  : Icons.play_arrow,
                              size: 18,
                            ),
                            label: Text(
                              working
                                  ? '处理中…'
                                  : uploader.running
                                  ? '暂停监听'
                                  : station.legacy
                                  ? '恢复旧目录监听'
                                  : '继续监听',
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: active
                                  ? WorkstationStyle.ink
                                  : WorkstationStyle.accent,
                              minimumSize: const Size(0, 40),
                            ),
                          ),
                          OutlinedButton(
                            onPressed:
                                !active ||
                                    working ||
                                    !uploader.running ||
                                    failed == 0
                                ? null
                                : () => uploader.retryFailed(),
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
                    uploader.fatalError ??
                        station.message ??
                        (uploader.running ? uploader.message : station.status),
                    style: const TextStyle(
                      color: WorkstationStyle.muted,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (uploader.watcherNotice.isNotEmpty)
                  Text(
                    uploader.watcherNotice,
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
                ...{...uploader.issues, ...uploader.noticeIssues}.entries
                    .where(
                      (entry) =>
                          '${p.relative(entry.key, from: _folder)}：${entry.value}' !=
                          orderWait,
                    )
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
              ],
            ),
            UploadTaskList(
              folder: _folder,
              waiting: uploader.waitingSources,
              needingOrder: uploader.sourcesNeedingOrder,
              jobs: jobs,
              onDiscard: uploader.running
                  ? uploader.discardWaitingSource
                  : null,
              batchTimeline: widget.batchTimeline,
              onConfirmNext: uploader.running
                  ? uploader.confirmNextSource
                  : null,
              onReview: (job) => showCardTailDialog(
                context,
                readPhoto: job.readPhotoForReview,
                guidance: [
                  if (job.captureMetadata != null)
                    job.captureMetadata!.description,
                  '请根据候选尾号核对卡面。归集由服务端识别结束照。',
                ].join('\n'),
              ),
            ),
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  '支持 JPEG、PNG、MPO、HEIF、RAW / DNG、TIFF、WebP 和 AVIF。按发现顺序排队，前一张入库后继续。',
                  style: TextStyle(
                    fontSize: 12,
                    color: WorkstationStyle.muted,
                    height: 1.4,
                  ),
                ),
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
