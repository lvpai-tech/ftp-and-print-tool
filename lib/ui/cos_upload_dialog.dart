import 'package:material_ui/material_ui.dart';

import '../auto_upload/cos_upload.dart';

/// Edits the direct-upload profile stored in the system keychain.
class CosUploadDialog extends StatefulWidget {
  final Uri api;
  final CosUploadProfile? initial;

  const CosUploadDialog({super.key, required this.api, this.initial});

  @override
  State<CosUploadDialog> createState() => _CosUploadDialogState();
}

class _CosUploadDialogState extends State<CosUploadDialog> {
  late final _station = TextEditingController(text: widget.initial?.stationId);
  late final _token = TextEditingController(text: widget.initial?.token);
  String? _error;

  @override
  void dispose() {
    _station.dispose();
    _token.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final initial = widget.initial;
      final stationId = _station.text.trim();
      final sameStation = initial?.stationId == stationId;
      final profile = CosUploadProfile(
        widget.api.origin,
        stationId,
        _token.text.trim(),
        stationName: sameStation ? initial?.stationName : null,
        stationCode: sameStation ? initial?.stationCode : null,
        scenicName: sameStation ? initial?.scenicName : null,
        scenicId: sameStation ? initial?.scenicId : null,
      );
      Navigator.of(context).pop(profile);
    } on StateError catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('COS 自动直传'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _station,
              readOnly: widget.initial != null,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '机位 ID'),
            ),
            TextField(
              controller: _token,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: '机位密钥', errorText: _error),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存配置')),
    ],
  );
}
