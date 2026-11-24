import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../ui/app_dialogs.dart';
import '../../ui/design.dart';
import '../print_bridge.dart';
import 'design.dart';

class PrintRecoveryDialog extends StatefulWidget {
  const PrintRecoveryDialog({
    super.key,
    required this.bridge,
    required this.jobId,
    required this.perform,
  });

  final PrintBridge bridge;
  final String jobId;
  final Perform perform;

  @override
  State<PrintRecoveryDialog> createState() => _PrintRecoveryDialogState();
}

class _PrintRecoveryDialogState extends State<PrintRecoveryDialog> {
  late final _details = widget.bridge.call('recoveryDetails', [widget.jobId]);
  final _missing = <int>{};
  bool _verified = false;
  bool _sending = false;

  Future<void> _submit(List<int> indexes) async {
    setState(() => _sending = true);
    final done = await widget.perform('recoverPrintJob', [
      widget.jobId,
      indexes,
    ]);
    if (!mounted) return;
    setState(() => _sending = false);
    if (done) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<dynamic>(
    future: _details,
    builder: (context, snapshot) {
      final details = snapshot.data as Map?;
      final sheets = (details?['sheets'] as List? ?? const []).cast<Map>();
      final indexes = [
        for (final sheet in sheets)
          if (sheet['state'] == 'READY' || _missing.contains(sheet['index']))
            sheet['index'] as int,
      ];
      final awaitingResult = details?['resultPending'] == true;
      final showSelection = sheets.isNotEmpty && !awaitingResult;
      return PopScope(
        canPop: !_sending,
        child: AlertDialog(
          title: Text('核对打印 · #${widget.jobId}'),
          content: SizedBox(
            width: 500,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .53,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (snapshot.hasError)
                      Text(appErrorMessage(snapshot.error!))
                    else if (details == null)
                      const LinearProgressIndicator()
                    else if (awaitingResult)
                      const Text('打印结果已记录，可重试回写。')
                    else ...[
                      const Text('核对系统打印队列和纸面，勾选缺少的照片。尚未送打的照片已自动选中。'),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: (sheets.length * 75.0)
                            .clamp(75, 270)
                            .toDouble(),
                        child: ListView.builder(
                          primary: false,
                          itemCount: sheets.length,
                          itemBuilder: (context, index) =>
                              _sheetTile(sheets[index]),
                        ),
                      ),
                      const Divider(),
                      CheckboxListTile(
                        value: _verified,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('已核对纸面和系统打印队列'),
                        subtitle: const Text('未勾选的照片均已出纸，待补印照片没有仍在排队的作业。'),
                        onChanged: _sending
                            ? null
                            : (value) =>
                                  setState(() => _verified = value == true),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: _sending ? null : () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
            if (showSelection || awaitingResult)
              FilledButton(
                onPressed: (_verified || awaitingResult) && !_sending
                    ? () => _submit(indexes)
                    : null,
                child: Text(
                  _sending
                      ? '处理中…'
                      : awaitingResult
                      ? '重试回写'
                      : indexes.isEmpty
                      ? '确认已出齐'
                      : '补印 ${indexes.length} 张',
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _sheetTile(Map sheet) {
    final index = sheet['index'] as int;
    final state = sheet['state'];
    final status = switch (state) {
      'DONE' => '已确认完成',
      'READY' => '尚未送打',
      _ => '需核对出纸情况',
    };
    final printer = sheet['printer'];
    final spoolId = sheet['spoolId'];
    final queue = state == 'UNCERTAIN' && printer is String
        ? '\n$printer${spoolId == null ? '' : ' · 队列作业 #$spoolId'}'
        : '';
    return CheckboxListTile(
      key: ValueKey(index),
      value: state == 'READY' || _missing.contains(index),
      contentPadding: EdgeInsets.zero,
      title: Text('第 ${index + 1} 张 · ${sheet['label']}'),
      subtitle: Text('$status$queue'),
      secondary: _RecoveryThumbnail(
        bridge: widget.bridge,
        url: '${sheet['fileUrl']}',
        cover: sheet['kind'] == 'COVER',
      ),
      onChanged: _sending || state != 'UNCERTAIN'
          ? null
          : (value) {
              setState(() {
                if (value == true) {
                  _missing.add(index);
                } else {
                  _missing.remove(index);
                }
                _verified = false;
              });
            },
    );
  }
}

class _RecoveryThumbnail extends StatefulWidget {
  const _RecoveryThumbnail({
    required this.bridge,
    required this.url,
    required this.cover,
  });

  final PrintBridge bridge;
  final String url;
  final bool cover;

  @override
  State<_RecoveryThumbnail> createState() => _RecoveryThumbnailState();
}

class _RecoveryThumbnailState extends State<_RecoveryThumbnail> {
  late final _image = _load();

  Future<Uint8List> _load() async {
    final url = widget.cover ? widget.url : '${widget.url}?thumbnail=true';
    final response = await widget.bridge.call('previewJobImage', [url]);
    return base64Decode((response['dataUrl'] as String).split(',').last);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 52,
    height: 42,
    child: FutureBuilder<Uint8List>(
      future: _image,
      builder: (context, snapshot) => snapshot.hasData
          ? Image.memory(snapshot.data!, fit: BoxFit.contain, cacheWidth: 104)
          : const Icon(Icons.photo_outlined, color: WorkstationStyle.muted),
    ),
  );
}
