import 'package:material_ui/material_ui.dart';

import '../branding.dart';
import '../printing/app.dart';
import '../workstation_session.dart';
import 'transfer_page.dart';
import 'update_button.dart';
import 'workstation_home.dart';

class WorkstationShell extends StatefulWidget {
  const WorkstationShell({super.key, required this.session});
  final WorkstationSession session;

  @override
  State<WorkstationShell> createState() => _WorkstationShellState();
}

class _WorkstationShellState extends State<WorkstationShell> {
  WorkModule? _module;

  String get _uploadStatus {
    final session = widget.session;
    if (session.transferUploading) return '上传中';
    if (session.transferActive) return '上传任务运行中';
    return switch (session.transferConfigured) {
      true => '自动上传未开启',
      false => '机位待配置',
      null => '正在读取机位配置',
    };
  }

  String get _printStatus {
    final bridge = widget.session.printBridge;
    if (!bridge.connected) return bridge.error == null ? '连接中' : '暂不可用';
    if (bridge.printing) return '打印中';
    if (bridge.state['autoPrint'] == true) return '自动打印已开启';
    if (bridge.busy) return '正在处理';
    return bridge.configured ? '自动打印已关闭' : '景区待配置';
  }

  void _open(WorkModule module) {
    FocusScope.of(context).unfocus();
    setState(() => _module = module);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.printBridge]),
      builder: (context, _) {
        final module = _module;
        final width = MediaQuery.sizeOf(context).width;
        final headerInset = module == null && width >= 800
            ? ((width - workstationContentWidth) / 2).clamp(
                40.0,
                double.infinity,
              )
            : 16.0;
        final home = module == null;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (home) const WorkstationScenicBackground(),
            Scaffold(
              backgroundColor: home
                  ? Colors.transparent
                  : workstationBackground,
              appBar: module == WorkModule.print
                  ? null
                  : AppBar(
                      backgroundColor: home
                          ? const Color(0x90101f39)
                          : Colors.white,
                      surfaceTintColor: Colors.transparent,
                      toolbarHeight: module == null ? 60 : 68,
                      titleSpacing: headerInset,
                      shape: Border(
                        bottom: BorderSide(
                          color: home
                              ? Colors.white24
                              : const Color(0xffe1e7f0),
                        ),
                      ),
                      leading: module == null
                          ? null
                          : IconButton(
                              tooltip: '返回工作台',
                              icon: const Icon(Icons.arrow_back),
                              onPressed: () => setState(() => _module = null),
                            ),
                      title: Text(
                        module?.label ?? appBrandName,
                        style: TextStyle(
                          color: home ? Colors.white : workstationInk,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      actions: [
                        if (home)
                          TextButtonTheme(
                            data: TextButtonThemeData(
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xffe4edff),
                                disabledForegroundColor: Colors.white54,
                              ),
                            ),
                            child: const UpdateButton(),
                          )
                        else
                          const UpdateButton(),
                        SizedBox(width: headerInset - 8),
                      ],
                    ),
              body: SafeArea(
                top: false,
                child: Column(
                  children: [
                    if (session.notice case final notice?)
                      MaterialBanner(
                        content: Text(notice),
                        actions: [
                          TextButton(
                            onPressed: session.clearNotice,
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    Expanded(
                      child: IndexedStack(
                        index: module == null ? 0 : module.index + 1,
                        sizing: StackFit.expand,
                        children: [
                          WorkstationHome(
                            uploadStatus: _uploadStatus,
                            printStatus: _printStatus,
                            uploadActive: session.transferActive,
                            printActive:
                                session.printBridge.busy ||
                                session.printBridge.state['autoPrint'] == true,
                            onOpen: _open,
                          ),
                          TransferPage(
                            embedded: true,
                            onActiveChanged: session.setTransferActive,
                            onUploadingChanged: session.setTransferUploading,
                            onConfiguredChanged: session.setTransferConfigured,
                          ),
                          Workstation(
                            bridge: session.printBridge,
                            embedded: true,
                            onBack: () => setState(() => _module = null),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
