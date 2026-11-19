import 'package:material_ui/material_ui.dart';
import 'ui/transfer_page.dart';

class PhotoFtpApp extends StatelessWidget {
  const PhotoFtpApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '旅派 · FTP 上传',
    theme: ThemeData(
      useMaterial3: true,
      fontFamilyFallback: const [
        'Microsoft YaHei',
        'PingFang SC',
        'sans-serif',
      ],
      colorSchemeSeed: const Color(0xff2563eb),
      scaffoldBackgroundColor: const Color(0xfff4f7fb),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: const TransferPage(),
  );
}
