import 'package:material_ui/material_ui.dart';

import 'print_photos_ui_proto.dart';

/// Throwaway entry for the print-photos UI prototype.
///
/// Run:
///   flutter run -t lib/prototype/print_photos_ui_main.dart -d windows
///   flutter run -t lib/prototype/print_photos_ui_main.dart -d chrome
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '打印照片 UI 原型',
      theme: printPhotosProtoTheme(),
      home: const PrintPhotosUiProto(),
    ),
  );
}
