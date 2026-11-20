import 'package:material_ui/material_ui.dart';

/// 从异常取出可展示文案，去掉 Dart `StateError` 的 `Bad state:` 前缀。
String appErrorMessage(Object error) {
  if (error is StateError) return error.message;
  final text = '$error';
  const prefix = 'Bad state: ';
  if (text.startsWith(prefix)) return text.substring(prefix.length);
  return text;
}

Future<void> showAppMessage(
  BuildContext context, {
  String title = '提示',
  required String message,
  String action = '知道了',
}) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SelectableText(message),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(action),
        ),
      ],
    ),
  );
}

Future<bool> showAppConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String cancel = '取消',
  required String action,
}) async {
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SelectableText(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
}
