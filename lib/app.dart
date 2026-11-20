import 'package:material_ui/material_ui.dart';

import 'branding.dart';
import 'ui/design.dart';
import 'ui/transfer_page.dart';
import 'ui/workstation_shell.dart';
import 'workstation_session.dart';

class PhotoFtpApp extends StatelessWidget {
  const PhotoFtpApp({super.key, this.session});
  final WorkstationSession? session;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: session == null ? '$appBrandName · FTP 上传' : workstationTitle,
    theme: ThemeData(
      useMaterial3: true,
      fontFamilyFallback: const [
        'Microsoft YaHei',
        'PingFang SC',
        'sans-serif',
      ],
      colorScheme: ColorScheme.fromSeed(
        seedColor: session == null
            ? WorkstationStyle.accent
            : const Color(0xff2056b9),
        surface: WorkstationStyle.card,
      ),
      scaffoldBackgroundColor: session == null
          ? WorkstationStyle.bg
          : const Color(0xfff4f7fb),
      dividerColor: WorkstationStyle.line,
      appBarTheme: const AppBarTheme(
        backgroundColor: WorkstationStyle.card,
        foregroundColor: WorkstationStyle.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xfff8fafc),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: WorkstationStyle.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: WorkstationStyle.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(
            color: WorkstationStyle.accent,
            width: 1.4,
          ),
        ),
        labelStyle: const TextStyle(
          color: WorkstationStyle.muted,
          fontSize: 13,
        ),
      ),
    ),
    home: session == null
        ? const TransferPage()
        : WorkstationShell(session: session!),
  );
}
