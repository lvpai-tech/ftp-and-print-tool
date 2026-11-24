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

enum _FolderAction { copyPath, updateKey }

class _AutoUploadPanelState extends State<AutoUploadPanel> {
  StationUpload get station => widget.station;
  String get _folder => station.folder;
  bool _picking = false;
  bool _dragging = false;
  bool? _scanExisting;
  bool get _canDrop =>
      widget.allowDrop &&
      station.canImport &&
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

  Future<void> _pickFolder() async {
    setState(() => _picking = true);
    try {
      final picked = await station.chooseFolder();
      if (picked == null || !mounted) return;
      await station.changeFolder(picked);
      if (!mounted) return;
      if (station.message case final String message) {
        await showAppMessage(context, message: message);
      } else {
        setState(() => _scanExisting = null);
      }
    } catch (error) {
      if (mounted) {
        await showAppMessage(context, message: appErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
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
        sourcePath: path,
        guidance: '请根据候选尾号核对卡面。归集由服务端识别结束照。',
      );
    } catch (_) {
      if (mounted) await showAppMessage(context, message: '无法选取照片，请检查文件访问权限');
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final supported = desktop || Platform.isIOS;
    final uploader = station.uploader;
    final active = station.running;
    final working = station.busy || _picking;
    final jobs = uploader.jobs;
    final orderWait = uploader.orderWaitMessage;
    final pending = jobs.where((job) => job.state == 'pending').length;
    final uploading = jobs.where((job) => job.state == 'uploading').length;
    final done = jobs
        .where(
          (job) => const {
            'done',
            'accepted',
            'ingested',
            'grouped',
          }.contains(job.state),
        )
        .length;
    final failed = jobs.where((job) => job.state == 'failed').length;
    final status = station.status;
    final (statusColor, statusBackground) = switch (status) {
      '授权失效' => (WorkstationStyle.bad, WorkstationStyle.badSoft),
      '需要处理' ||
      '待确认顺序' ||
      '有异常' => (WorkstationStyle.warn, WorkstationStyle.warnSoft),
      '监听中' || '上传中' => (WorkstationStyle.ok, WorkstationStyle.okSoft),
      _ => (WorkstationStyle.muted, WorkstationStyle.bg),
    };
    final actionShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    );
    final secondaryAction = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 44),
      shape: actionShape,
      foregroundColor: WorkstationStyle.ink,
      side: const BorderSide(color: WorkstationStyle.line),
    );
    final identity = Row(
      spacing: 14,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: WorkstationStyle.accentSoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.photo_camera_outlined,
            color: WorkstationStyle.accent,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    station.name.isEmpty
                        ? '机位 ${station.profile.stationId}'
                        : station.name,
                    style: const TextStyle(
                      color: WorkstationStyle.ink,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  StatusTag(
                    label: status,
                    color: statusColor,
                    soft: statusBackground,
                  ),
                ],
              ),
              if (station.profile.scenicName case final name?)
                Text(
                  name,
                  style: const TextStyle(
                    color: WorkstationStyle.muted,
                    fontSize: 13,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: working || !supported || !station.hasFolder
              ? null
              : () => station.setEnabled(
                  !uploader.running,
                  scanExisting: _scanExisting,
                ),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            shape: actionShape,
            backgroundColor: active
                ? WorkstationStyle.ink
                : WorkstationStyle.accent,
            foregroundColor: WorkstationStyle.card,
          ),
          icon: Icon(
            uploader.running ? Icons.pause : Icons.play_arrow,
            size: 20,
          ),
          label: Text(
            uploader.running
                ? '暂停监听'
                : station.legacy
                ? '恢复旧目录监听'
                : station.enabled
                ? '继续监听'
                : '开始监听',
          ),
        ),
        OutlinedButton.icon(
          onPressed: working || !supported || !station.canImport
              ? null
              : _importPhotos,
          style: secondaryAction,
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
          label: Text(_picking ? '正在处理…' : '导入照片'),
        ),
        if (failed > 0)
          OutlinedButton.icon(
            onPressed: active && !working ? uploader.retryFailed : null,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 44),
              shape: actionShape,
              foregroundColor: WorkstationStyle.bad,
              side: const BorderSide(color: WorkstationStyle.line),
            ),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试失败任务'),
          ),
      ],
    );
    final folderPath = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        const Icon(
          Icons.folder_outlined,
          size: 20,
          color: WorkstationStyle.accent,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 3,
            children: [
              const Text(
                '收图文件夹',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              if (station.hasFolder)
                SelectableText(
                  _folder,
                  style: const TextStyle(
                    color: WorkstationStyle.muted,
                    fontSize: 13,
                  ),
                )
              else
                const Text('选择相机照片的导出目录。'),
            ],
          ),
        ),
      ],
    );
    final folderActions = <Widget>[
      OutlinedButton(
        onPressed: working || !supported ? null : _pickFolder,
        style: secondaryAction.copyWith(
          backgroundColor: const WidgetStatePropertyAll(WorkstationStyle.card),
        ),
        child: Text(station.hasFolder ? '更换收图文件夹' : '选择收图文件夹'),
      ),
      if (!Platform.isIOS && station.hasFolder)
        IconButton(
          tooltip: '打开收图文件夹',
          onPressed: working || !supported ? null : _openFolder,
          icon: const Icon(Icons.folder_open_outlined, size: 20),
        ),
      PopupMenuButton<_FolderAction>(
        tooltip: '文件夹操作',
        icon: const Icon(Icons.more_horiz, size: 20),
        enabled: station.hasFolder || !working,
        onSelected: (action) {
          switch (action) {
            case _FolderAction.copyPath:
              _copyFolder();
            case _FolderAction.updateKey:
              widget.onConfigureCos();
          }
        },
        itemBuilder: (_) => [
          if (station.hasFolder)
            const PopupMenuItem(
              value: _FolderAction.copyPath,
              child: Text('复制路径'),
            ),
          PopupMenuItem(
            value: _FolderAction.updateKey,
            enabled: !working,
            child: const Text('更新机位密钥'),
          ),
        ],
      ),
    ];
    final showScan = (station.legacy || station.custom) && !uploader.running;
    final scanOption = FilterChip(
      label: const Text('补扫目录已有照片'),
      selected: _scanExisting ?? station.scanExisting,
      onSelected: working
          ? null
          : (value) => setState(() => _scanExisting = value),
    );
    final dropTarget = desktop && station.canImport
        ? DropTarget(
            enable: _canDrop,
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: _dropPhotos,
            child: OutlinedButton.icon(
              onPressed: working ? null : _importPhotos,
              style: secondaryAction.copyWith(
                backgroundColor: _dragging && _canDrop
                    ? const WidgetStatePropertyAll(WorkstationStyle.accentSoft)
                    : null,
              ),
              icon: const Icon(Icons.file_download_outlined, size: 18),
              label: const Text('拖入照片到这个机位'),
            ),
          )
        : null;
    final stats = _UploadStats(
      items: [
        _Stat(
          label: '待准备',
          value: uploader.settling,
          color: WorkstationStyle.muted,
        ),
        _Stat(label: '待传', value: pending, color: WorkstationStyle.warn),
        _Stat(label: '上传中', value: uploading, color: WorkstationStyle.accent),
        _Stat(label: '已上传', value: done, color: WorkstationStyle.ok),
        _Stat(label: '失败', value: failed, color: WorkstationStyle.bad),
      ],
    );

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: DecoratedBox(
            decoration: WorkstationStyle.surface(),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 740;
                  final scanInline = constraints.maxWidth >= 900;
                  final folderControls = Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: wide ? WrapAlignment.end : WrapAlignment.start,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (scanInline && showScan) scanOption,
                      ...folderActions,
                    ],
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 12,
                    children: [
                      if (wide)
                        Row(
                          spacing: 16,
                          children: [
                            Expanded(child: identity),
                            Flexible(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: actions,
                              ),
                            ),
                          ],
                        )
                      else ...[
                        identity,
                        actions,
                      ],
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _dragging && _canDrop
                              ? WorkstationStyle.accentSoft
                              : WorkstationStyle.bg.withValues(alpha: .65),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 4,
                          children: [
                            if (wide)
                              Row(
                                spacing: 16,
                                children: [
                                  Expanded(child: folderPath),
                                  Flexible(
                                    flex: 2,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: folderControls,
                                    ),
                                  ),
                                ],
                              )
                            else ...[
                              folderPath,
                              folderControls,
                            ],
                            if (showScan && !scanInline)
                              Padding(
                                padding: const EdgeInsets.only(left: 28),
                                child: scanOption,
                              ),
                          ],
                        ),
                      ),
                      if (wide && dropTarget != null)
                        Row(
                          spacing: 16,
                          children: [
                            Expanded(flex: 2, child: stats),
                            Flexible(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: dropTarget,
                              ),
                            ),
                          ],
                        )
                      else ...[
                        stats,
                        if (dropTarget != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: dropTarget,
                          ),
                      ],
                      if (Platform.isIOS)
                        const Text(
                          'iPad 在前台收图，回到应用后会继续未完成任务。',
                          style: TextStyle(color: WorkstationStyle.muted),
                        ),
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
                      if ((uploader.fatalError ??
                              station.message ??
                              (uploader.running ? uploader.message : null))
                          case final message?
                          when message.isNotEmpty && message != station.status)
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            message,
                            style: const TextStyle(
                              color: WorkstationStyle.muted,
                            ),
                          ),
                        ),
                      if (uploader.watcherNotice.isNotEmpty)
                        Text(
                          uploader.watcherNotice,
                          style: const TextStyle(color: WorkstationStyle.warn),
                        ),
                      if (orderWait != null)
                        Text(
                          orderWait,
                          style: const TextStyle(color: WorkstationStyle.warn),
                        ),
                      ...{...uploader.issues, ...uploader.noticeIssues}.entries
                          .where(
                            (entry) =>
                                '${p.relative(entry.key, from: _folder)}：${entry.value}' !=
                                orderWait,
                          )
                          .take(8)
                          .map(
                            (entry) => Text(
                              '${p.basename(entry.key)}：${entry.value}',
                              style: const TextStyle(
                                color: WorkstationStyle.warn,
                              ),
                            ),
                          ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        UploadTaskList(
          folder: _folder,
          waiting: uploader.waitingSources,
          needingOrder: uploader.sourcesNeedingOrder,
          jobs: jobs,
          batchTimeline: widget.batchTimeline,
          onDiscard: uploader.running ? uploader.discardWaitingSource : null,
          onConfirmNext: uploader.running ? uploader.confirmNextSource : null,
          onReview: (job) => showCardTailDialog(
            context,
            readPhoto: job.readPhotoForReview,
            sourcePath: job.source,
            guidance: [
              if (job.captureMetadata != null) job.captureMetadata!.description,
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
    );
  }
}

class _UploadStats extends StatelessWidget {
  const _UploadStats({required this.items});

  final List<_Stat> items;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final columns = (constraints.maxWidth / (82 * scale)).floor().clamp(
        1,
        items.length,
      );
      final width = constraints.maxWidth / columns;
      return Wrap(
        runSpacing: 10,
        children: [
          for (var index = 0; index < items.length; index++)
            Container(
              width: width,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: index % columns == 0
                    ? null
                    : const Border(
                        left: BorderSide(color: WorkstationStyle.line),
                      ),
              ),
              child: items[index],
            ),
        ],
      );
    },
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 2,
    children: [
      Text(
        label,
        style: const TextStyle(color: WorkstationStyle.muted, fontSize: 12),
      ),
      Text(
        '$value',
        style: TextStyle(
          color: value == 0 ? WorkstationStyle.ink : color,
          fontSize: 21,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}
