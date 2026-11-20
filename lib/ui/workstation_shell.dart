import 'package:material_ui/material_ui.dart';

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
  int _printStep = 0;

  String get _uploadStatus => widget.session.transferUploading
      ? '上传任务正在运行'
      : widget.session.transferActive
      ? '正在处理'
      : '未运行';

  String get _printStatus {
    final bridge = widget.session.printBridge;
    if (!bridge.connected) return bridge.error == null ? '连接中' : '暂不可用';
    if (bridge.printing) return '打印中';
    if (bridge.state['autoPrint'] == true) return '自动打印已开启';
    if (bridge.busy) return '正在处理';
    return bridge.configured ? '未运行' : '待设置';
  }

  void _open(WorkModule module) {
    FocusScope.of(context).unfocus();
    setState(() {
      if (_module != module) {
        final bridge = widget.session.printBridge;
        if (module == WorkModule.print &&
            (bridge.printing || bridge.state['autoPrint'] == true)) {
          _printStep = 2;
        }
      }
      _module = module;
    });
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
            ? ((width - 1110) / 2).clamp(40.0, double.infinity)
            : 16.0;
        return Scaffold(
          backgroundColor: workstationBackground,
          appBar: AppBar(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            toolbarHeight: 68,
            titleSpacing: headerInset,
            shape: const Border(bottom: BorderSide(color: Color(0xffe1e7f0))),
            leading: module == null
                ? null
                : IconButton(
                    tooltip: '返回工作台',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => setState(() => _module = null),
                  ),
            title: Row(
              children: [
                const WorkstationMark(),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    module?.label ?? '帧集',
                    style: const TextStyle(
                      color: workstationInk,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
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
                if (module != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                    child: Row(
                      children: [
                        for (final item in WorkModule.values)
                          Expanded(
                            child: TextButton(
                              key: ValueKey('switch-${item.name}'),
                              onPressed: () => _open(item),
                              style: TextButton.styleFrom(
                                foregroundColor: item.color,
                                backgroundColor: item == module
                                    ? item.tint
                                    : Colors.white,
                                minimumSize: const Size(0, 48),
                              ),
                              child: Wrap(
                                spacing: 7,
                                runSpacing: 2,
                                alignment: WrapAlignment.center,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Icon(item.icon, size: 17),
                                  Text(item.label),
                                  Text(
                                    item == WorkModule.upload
                                        ? _uploadStatus
                                        : _printStatus,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (module == WorkModule.print)
                    WorkstationSteps(
                      module: module,
                      selected: _printStep,
                      onSelected: (step) => setState(() => _printStep = step),
                    ),
                ],
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
                      ),
                      Workstation(
                        bridge: session.printBridge,
                        embedded: true,
                        selectedPage: const [1, 3, 0][_printStep],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
