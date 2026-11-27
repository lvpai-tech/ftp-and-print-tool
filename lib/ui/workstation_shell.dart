import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../branding.dart';
import '../printing/app.dart';
import '../workstation_session.dart';
import 'app_dialogs.dart';
import 'transfer_page.dart';
import 'update_button.dart';
import 'workstation_home.dart';

class WorkstationShell extends StatefulWidget {
  const WorkstationShell({
    super.key,
    required this.session,
    this.onLogout,
    this.onChangeScenic,
  });
  final WorkstationSession session;
  final Future<void> Function()? onLogout, onChangeScenic;

  @override
  State<WorkstationShell> createState() => _WorkstationShellState();
}

class _WorkstationShellState extends State<WorkstationShell> {
  late final _packageInfo = PackageInfo.fromPlatform();
  WorkModule? _module;

  String get _uploadStatus {
    final session = widget.session;
    if (session.transferIssue case final issue?) return issue;
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
    if (bridge.storageUnavailable) return '打印存储需要处理';
    if (!bridge.connected) return bridge.error == null ? '连接中' : '暂不可用';
    if (bridge.printing) return '打印中';
    if (bridge.systemPrinterIssue != null) return '系统打印机需要检查';
    if (bridge.state['autoPrint'] == true) return '自动打印已开启';
    if (bridge.busy) return '正在处理';
    return bridge.configured ? '自动打印已关闭' : '景区待配置';
  }

  void _open(WorkModule module) {
    FocusScope.of(context).unfocus();
    setState(() => _module = module);
  }

  Future<void> _accountAction(String action) async {
    final blockers = widget.session.signOutBlockers;
    if (blockers.isNotEmpty) {
      final goUpload = widget.session.activeStations.isNotEmpty;
      final goPrint =
          widget.session.printBridge.busy ||
          widget.session.printBridge.state['autoPrint'] == true;
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('当前无法$action'),
          content: Text(blockers.join('\n')),
          actions: [
            if (goUpload)
              TextButton(
                onPressed: () {
                  Navigator.pop(dialog);
                  _open(WorkModule.upload);
                },
                child: const Text('去上传'),
              ),
            if (goPrint)
              TextButton(
                onPressed: () {
                  Navigator.pop(dialog);
                  _open(WorkModule.print);
                },
                child: const Text('去打印'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    if (action == '切换景区') {
      await widget.onChangeScenic?.call();
    } else {
      await widget.onLogout?.call();
    }
  }

  Future<void> _showUninstallHelp() async {
    final openFolder = await showAppConfirm(
      context,
      title: '卸载客户端',
      message:
          '等上传、打印完成并停止监听后，从托盘选择「退出客户端」。\n\n'
          '安装版可在 Windows「设置 → 应用 → 已安装的应用」中卸载。'
          'ZIP 便携版可先打开程序文件夹，退出后删除解压出来的程序文件。'
          '请保留收图文件夹和照片。',
      action: '打开程序文件夹',
    );
    if (!openFolder || !mounted) return;

    final folder = p.dirname(Platform.resolvedExecutable);
    try {
      if (await launchUrl(
        p.toUri(folder),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // 系统拒绝打开时，提供可复制的原始路径。
    }
    if (!mounted) return;
    await showAppMessage(
      context,
      title: '无法打开程序文件夹',
      message: '请复制下面的路径，在文件资源管理器的地址栏中打开。\n\n$folder',
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.printBridge]),
      builder: (context, _) {
        final module = _module;
        final width = MediaQuery.sizeOf(context).width;
        final home = module == null;
        final headerInset = home && width >= workstationWideWidth ? 40.0 : 16.0;
        return Stack(
          fit: StackFit.expand,
          children: [
            Scaffold(
              backgroundColor: workstationBackground,
              appBar: module == WorkModule.print
                  ? null
                  : AppBar(
                      backgroundColor: Colors.white,
                      surfaceTintColor: Colors.transparent,
                      toolbarHeight: home ? 72 : 68,
                      titleSpacing: headerInset,
                      shape: const Border(
                        bottom: BorderSide(color: Color(0xffe1e7f0)),
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
                          color: workstationInk,
                          fontSize: home && width >= workstationWideWidth
                              ? 26
                              : null,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      actions: [
                        if (home)
                          TextButtonTheme(
                            data: TextButtonThemeData(
                              style: TextButton.styleFrom(
                                foregroundColor: workstationInk,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FutureBuilder<PackageInfo>(
                                  future: _packageInfo,
                                  builder: (context, snapshot) {
                                    if (snapshot.connectionState !=
                                        ConnectionState.done) {
                                      return const SizedBox.shrink();
                                    }
                                    final info = snapshot.data;
                                    final version = info?.version.trim() ?? '';
                                    final build =
                                        info?.buildNumber.trim() ?? '';
                                    return Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Text(
                                        version.isEmpty || build.isEmpty
                                            ? '版本不可用'
                                            : 'v$version+$build',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: const Color(0xff586575),
                                            ),
                                      ),
                                    );
                                  },
                                ),
                                UpdateButton(session: session),
                                if (session.identity case final identity?)
                                  PopupMenuButton<String>(
                                    tooltip: '工作台账号',
                                    onSelected: _accountAction,
                                    itemBuilder: (_) => [
                                      if (identity.scenics.length > 1)
                                        const PopupMenuItem(
                                          value: '切换景区',
                                          child: Text('切换景区'),
                                        ),
                                      const PopupMenuItem(
                                        value: '切换账号',
                                        child: Text('切换账号'),
                                      ),
                                      const PopupMenuItem(
                                        value: '退出登录',
                                        child: Text('退出登录'),
                                      ),
                                    ],
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth: width < 500 ? 112 : 200,
                                        ),
                                        child: Text(
                                          '${identity.name} · ${session.scenic?.name ?? ''}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: workstationInk,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (Platform.isWindows) ...[
                                  const SizedBox(width: 8),
                                  TextButton(
                                    onPressed: _showUninstallHelp,
                                    child: const Text('卸载客户端…'),
                                  ),
                                ],
                              ],
                            ),
                          )
                        else
                          UpdateButton(session: session),
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
                            visible: module == WorkModule.upload,
                            onActiveChanged: session.setTransferActive,
                            onUploadingChanged: session.setTransferUploading,
                            onConfiguredChanged: session.setTransferConfigured,
                            session: session,
                          ),
                          Workstation(
                            bridge: session.printBridge,
                            embedded: true,
                            session: session,
                            onBack: () => setState(() => _module = null),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (session.updating ||
                session.closingWorkspace ||
                session.workspaceLocked)
              const ModalBarrier(dismissible: false),
          ],
        );
      },
    );
  }
}
