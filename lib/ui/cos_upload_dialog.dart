import 'package:material_ui/material_ui.dart';

import '../auto_upload/cos_upload.dart';

/// Edits the direct-upload profile stored in the system keychain.
class CosUploadDialog extends StatefulWidget {
  final CosUploadProfile? initial;

  const CosUploadDialog({super.key, this.initial});

  @override
  State<CosUploadDialog> createState() => _CosUploadDialogState();
}

class _CosUploadDialogState extends State<CosUploadDialog> {
  late final _api = TextEditingController(text: widget.initial?.api.origin);
  late final _station = TextEditingController(text: widget.initial?.stationId);
  late final _token = TextEditingController(text: widget.initial?.token);
  String? _error;

  @override
  void dispose() {
    _api.dispose();
    _station.dispose();
    _token.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final profile = CosUploadProfile(
        _api.text,
        _station.text.trim(),
        _token.text.trim(),
      );
      Navigator.of(context).pop(profile);
    } catch (_) {
      setState(() => _error = '请填写 HTTPS 服务地址、机位 ID 和有效机位密钥');
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
              controller: _api,
              decoration: const InputDecoration(labelText: '业务服务 HTTPS 地址'),
            ),
            TextField(
              controller: _station,
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
