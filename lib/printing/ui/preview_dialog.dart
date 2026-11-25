import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../../ui/app_dialogs.dart';
import '../../ui/design.dart';
import '../print_bridge.dart';
import 'design.dart';

class PreviewDialog extends StatefulWidget {
  const PreviewDialog({
    super.key,
    required this.bridge,
    required this.jobId,
    required this.cardTail,
    required this.perform,
  });
  final PrintBridge bridge;
  final String jobId;
  final String cardTail;
  final Perform perform;
  @override
  State<PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<PreviewDialog> {
  List<Json> items = [];
  int index = 0;
  Future<dynamic>? image;
  String? error;
  bool loading = true;
  bool trialPrintBusy = false;
  bool zipBusy = false;

  String get _titleTail {
    final tail = widget.cardTail.trim();
    return tail.isEmpty ? '无取片卡' : tail;
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final job = await widget.bridge.call('previewJob', [widget.jobId]);
      if (!mounted) return;
      setState(() {
        items = (job['items'] as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        loading = false;
      });
      showImage();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = appErrorMessage(e);
          loading = false;
        });
      }
    }
  }

  void showImage() {
    if (items.isEmpty) return;
    final item = items[index];
    final url = '${item['fileUrl']}';
    final future = widget.bridge.call('previewJobImage', [
      item['kind'] == 'COVER'
          ? url
          : '$url${url.contains('?') ? '&' : '?'}preview=true',
    ]);
    // 必须用块体：箭头赋值会把 Future 当 setState 回调返回值，触发框架报错。
    setState(() {
      image = future;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sheetLabel = items.isEmpty
        ? '只读预览，不占用工单'
        : '${items[index]['label']} × ${items[index]['copies']}';
    return PopScope(
      canPop: !trialPrintBusy,
      child: Dialog(
        backgroundColor: WorkstationStyle.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: WorkstationStyle.line),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 760),
          child: SizedBox(
            width: 1000,
            height: 700,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 22, 16, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(
                                    text: '取片码 ',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      color: WorkstationStyle.muted,
                                    ),
                                  ),
                                  TextSpan(
                                    text: _titleTail,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      color: WorkstationStyle.ink,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                  const TextSpan(
                                    text: '  ·  打印预览',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      color: WorkstationStyle.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              sheetLabel,
                              style: const TextStyle(
                                fontSize: 13,
                                color: WorkstationStyle.muted,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭预览',
                        onPressed: trialPrintBusy
                            ? null
                            : () => Navigator.pop(context),
                        style: IconButton.styleFrom(
                          foregroundColor: WorkstationStyle.muted,
                          minimumSize: const Size(40, 40),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon: const Icon(Icons.close_rounded, size: 22),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 18, 28, 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xfff4f6fa),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: WorkstationStyle.line),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(13),
                        child: _previewBody(),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 4, 28, 22),
                  child: Row(
                    children: [
                      OutlinedButton(
                        onPressed: items.isEmpty || trialPrintBusy || zipBusy
                            ? null
                            : _trialPrint,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: WorkstationStyle.ink,
                          side: const BorderSide(color: WorkstationStyle.line),
                          minimumSize: const Size(0, 42),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: const Text('试打印当前张（实际出纸）'),
                      ),
                      const Spacer(),
                      _Pager(
                        index: items.isEmpty ? 0 : index + 1,
                        total: items.length,
                        onPrevious: index == 0 || trialPrintBusy
                            ? null
                            : () {
                                index--;
                                showImage();
                              },
                        onNext: index >= items.length - 1 || trialPrintBusy
                            ? null
                            : () {
                                index++;
                                showImage();
                              },
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: items.isEmpty || trialPrintBusy || zipBusy
                            ? null
                            : _downloadZip,
                        style: FilledButton.styleFrom(
                          backgroundColor: WorkstationStyle.accent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 42),
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: ListenableBuilder(
                          listenable: widget.bridge,
                          builder: (context, _) => Text(_zipButtonLabel),
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
    );
  }

  Widget _previewBody() {
    if (loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error!, style: const TextStyle(color: WorkstationStyle.bad)),
            const SizedBox(height: 10),
            TextButton(onPressed: load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (items.isEmpty) {
      return const Center(
        child: Text('暂无照片', style: TextStyle(color: WorkstationStyle.muted)),
      );
    }
    return FutureBuilder<dynamic>(
      key: ValueKey(items[index]['fileUrl']),
      future: image,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  appErrorMessage(snapshot.error!),
                  style: const TextStyle(color: WorkstationStyle.bad),
                ),
                const SizedBox(height: 10),
                TextButton(onPressed: showImage, child: const Text('重试图片')),
              ],
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
          return const Center(
            child: Text(
              '图片加载中',
              style: TextStyle(color: WorkstationStyle.muted, fontSize: 13),
            ),
          );
        }
        final bytes = base64Decode(
          (snapshot.data['dataUrl'] as String).split(',').last,
        );
        return InteractiveViewer(
          minScale: .5,
          maxScale: 5,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: WorkstationStyle.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x14000000)),
                  boxShadow: WorkstationStyle.softShadow,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _trialPrint() async {
    setState(() => trialPrintBusy = true);
    final ok = await widget.perform('trialPrintItem', [items[index]]);
    if (!mounted) return;
    setState(() => trialPrintBusy = false);
    if (ok) {
      await showAppMessage(context, message: '试打印命令已受理，请核对实物；工单状态未修改。');
    }
  }

  String get _zipButtonLabel {
    if (!zipBusy) return '下载本单 ZIP';
    final progress = widget.bridge.zipProgress;
    if (progress == null) return '正在导出 ZIP…';
    if (progress.saving) return '正在保存 ZIP…';
    return '已下载 ${progress.completed} / ${progress.total} 张';
  }

  Future<void> _downloadZip() async {
    if (zipBusy || trialPrintBusy) return;
    setState(() => zipBusy = true);
    String message;
    var title = '提示';
    try {
      final location = await getSaveLocation(
        suggestedName: 'print-${widget.jobId}.zip',
        acceptedTypeGroups: [
          const XTypeGroup(label: 'ZIP', extensions: ['zip']),
        ],
      );
      if (!mounted || location == null) return;
      await widget.bridge.run('downloadJobZip', [widget.jobId, location.path]);
      message = 'ZIP 已保存：${location.path}';
    } catch (error) {
      title = 'ZIP 导出未完成';
      message = appErrorMessage(error);
    } finally {
      if (mounted) setState(() => zipBusy = false);
    }
    if (mounted) await showAppMessage(context, title: title, message: message);
  }
}

class _Pager extends StatelessWidget {
  const _Pager({
    required this.index,
    required this.total,
    required this.onPrevious,
    required this.onNext,
  });

  final int index;
  final int total;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: WorkstationStyle.bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: WorkstationStyle.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '上一张',
            onPressed: onPrevious,
            style: IconButton.styleFrom(
              foregroundColor: WorkstationStyle.ink,
              disabledForegroundColor: WorkstationStyle.muted.withValues(
                alpha: .35,
              ),
              minimumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
            ),
            icon: const Icon(Icons.chevron_left_rounded, size: 22),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '$index / $total',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: WorkstationStyle.ink,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          IconButton(
            tooltip: '下一张',
            onPressed: onNext,
            style: IconButton.styleFrom(
              foregroundColor: WorkstationStyle.ink,
              disabledForegroundColor: WorkstationStyle.muted.withValues(
                alpha: .35,
              ),
              minimumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
            ),
            icon: const Icon(Icons.chevron_right_rounded, size: 22),
          ),
        ],
      ),
    );
  }
}
