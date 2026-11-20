import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../print_bridge.dart';
import 'design.dart';

class PreviewDialog extends StatefulWidget {
  const PreviewDialog({
    super.key,
    required this.bridge,
    required this.jobId,
    required this.perform,
  });
  final PrintBridge bridge;
  final String jobId;
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
  bool actionBusy = false;
  String? actionMessage;
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
          error = '$e';
          loading = false;
        });
      }
    }
  }

  void showImage() {
    if (items.isEmpty) return;
    final item = items[index];
    final url = '${item['fileUrl']}';
    setState(
      () => image = widget.bridge.call('previewJobImage', [
        item['kind'] == 'COVER'
            ? url
            : '$url${url.contains('?') ? '&' : '?'}preview=true',
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !actionBusy,
    child: Dialog(
      child: SizedBox(
        width: 1000,
        height: 700,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '工单 #${widget.jobId} · 打印预览',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭预览',
                    onPressed: actionBusy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  items.isEmpty
                      ? '只读预览，不占用工单'
                      : '${items[index]['label']} × ${items[index]['copies']}',
                  style: const TextStyle(color: muted),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(error!),
                            TextButton(
                              onPressed: load,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : items.isEmpty
                    ? const Center(child: Text('暂无照片'))
                    : FutureBuilder<dynamic>(
                        key: ValueKey(items[index]['fileUrl']),
                        future: image,
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('${snapshot.error}'),
                                  TextButton(
                                    onPressed: showImage,
                                    child: const Text('重试图片'),
                                  ),
                                ],
                              ),
                            );
                          }
                          if (snapshot.connectionState !=
                                  ConnectionState.done ||
                              !snapshot.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final bytes = base64Decode(
                            (snapshot.data['dataUrl'] as String)
                                .split(',')
                                .last,
                          );
                          return InteractiveViewer(
                            minScale: .5,
                            maxScale: 5,
                            child: Center(
                              child: Image.memory(
                                bytes,
                                fit: BoxFit.contain,
                                gaplessPlayback: false,
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 16),
              if (actionMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SelectableText(
                    actionMessage!,
                    style: TextStyle(
                      color: widget.bridge.error == null ? accent : Colors.red,
                    ),
                  ),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: items.isEmpty || actionBusy
                        ? null
                        : () async {
                            setState(() => actionBusy = true);
                            await widget.perform('trialPrintItem', [
                              items[index],
                            ]);
                            if (mounted) {
                              setState(() {
                                actionBusy = false;
                                actionMessage =
                                    widget.bridge.error ??
                                    '试打印命令已受理，请核对实物；工单状态未修改。';
                              });
                            }
                          },
                    child: const Text('试打印当前张（实际出纸）'),
                  ),
                  IconButton(
                    tooltip: '上一张',
                    onPressed: index == 0 || actionBusy
                        ? null
                        : () {
                            index--;
                            showImage();
                          },
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${items.isEmpty ? 0 : index + 1} / ${items.length}'),
                  IconButton(
                    tooltip: '下一张',
                    onPressed: index >= items.length - 1 || actionBusy
                        ? null
                        : () {
                            index++;
                            showImage();
                          },
                    icon: const Icon(Icons.chevron_right),
                  ),
                  FilledButton(
                    onPressed: items.isEmpty || actionBusy
                        ? null
                        : () async {
                            final location = await getSaveLocation(
                              suggestedName: 'print-${widget.jobId}.zip',
                              acceptedTypeGroups: [
                                const XTypeGroup(
                                  label: 'ZIP',
                                  extensions: ['zip'],
                                ),
                              ],
                            );
                            if (location == null || !mounted) return;
                            setState(() => actionBusy = true);
                            await widget.perform('downloadJobZip', [
                              widget.jobId,
                              location.path,
                            ]);
                            if (mounted) {
                              setState(() {
                                actionBusy = false;
                                actionMessage =
                                    widget.bridge.error ??
                                    'ZIP 已保存：${location.path}';
                              });
                            }
                          },
                    child: const Text('下载本单 ZIP'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
