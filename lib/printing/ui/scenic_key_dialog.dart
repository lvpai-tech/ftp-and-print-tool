import 'package:material_ui/material_ui.dart';

Future<String?> showScenicKeyDialog(
  BuildContext context, {
  String title = '添加景区密钥',
}) {
  var token = '';
  var obscure = true;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: Text(title),
        scrollable: true,
        content: TextField(
          onChanged: (value) => token = value,
          obscureText: obscure,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '景区打印密钥',
            suffixIcon: IconButton(
              tooltip: obscure ? '显示密钥' : '隐藏密钥',
              onPressed: () => setDialog(() => obscure = !obscure),
              icon: Icon(
                obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, token.trim()),
            child: const Text('校验并保存'),
          ),
        ],
      ),
    ),
  );
}
