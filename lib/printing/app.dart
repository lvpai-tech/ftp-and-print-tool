import 'package:material_ui/material_ui.dart';

import '../branding.dart';
import '../ui/app_dialogs.dart';
import '../ui/design.dart';
import '../ui/update_button.dart';
import '../workstation_session.dart';
import 'job_query_time.dart';
import 'print_bridge.dart';
import 'ui/date_time_range_field.dart';
import 'ui/design.dart';
import 'ui/job_thumbnails.dart';
import 'ui/photo_batch_page.dart';
import 'ui/preview_dialog.dart';
import 'ui/print_recovery_dialog.dart';
import 'ui/settings_panel.dart';
import 'ui/print_enrollment_panel.dart';

const _generatingFilter = 'GENERATING';

class Workstation extends StatefulWidget {
  const Workstation({
    super.key,
    required this.bridge,
    this.embedded = false,
    this.selectedPage,
    this.onBack,
    this.session,
  });
  final PrintBridge bridge;
  final bool embedded;
  final int? selectedPage;
  final VoidCallback? onBack;
  final WorkstationSession? session;
  @override
  State<Workstation> createState() => _WorkstationState();
}

class _WorkstationState extends State<Workstation> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  PrintBridge get bridge => widget.bridge;
  int _page = 0;
  int get page => widget.selectedPage ?? _page;
  String filter = 'UNPRINTED';
  bool _viewingBatches = false;
  final selected = <String>{};
  DateTimeRange? dates;
  @override
  void initState() {
    super.initState();
    final previous = bridge.state['jobQuery']?['printStatus'];
    if (previous == _generatingFilter || previous == 'PRINTED') {
      filter = previous as String;
    }
    bridge.addListener(changed);
  }

  @override
  void dispose() {
    bridge.removeListener(changed);
    super.dispose();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<bool> perform(String method, [List<dynamic> args = const []]) async {
    try {
      final result = await bridge.run(method, args);
      if (!mounted) return false;
      if (result is Map && result['needConfirm'] == true) {
        final agreed = await confirm(
          '驱动报告缺纸',
          '${result['message']}\n请核实纸匣已有纸，确认是误报后才忽略缺纸继续。',
          '已核实，继续打印',
        );
        if (agreed) {
          return await perform(method, [
            args.first,
            {'ignorePaperOut': true},
          ]);
        }
        return false;
      }
      return true;
    } catch (e) {
      if (mounted) {
        await showAppMessage(
          context,
          title: '操作未完成',
          message: appErrorMessage(e),
        );
      }
      return false;
    }
  }

  Future<bool> confirm(String title, String message, String action) =>
      showAppConfirm(context, title: title, message: message, action: action);

  Future<void> query({int number = 1, int issuePage = 1}) async {
    selected.clear();
    await perform('queryJobs', [
      {
        'printStatus': filter,
        'pageNum': number,
        'pageSize': 20,
        'issuePage': issuePage,
        'createdFrom': dates == null ? '' : shanghaiDateTime(dates!.start),
        'createdTo': dates == null ? '' : shanghaiDateTime(dates!.end),
      },
    ]);
  }

  void openConfig() => _scaffoldKey.currentState?.openEndDrawer();

  String get scenicLabel {
    final name = '${bridge.config['scenicName'] ?? ''}'.trim();
    return name.isEmpty ? '（未返回名称）' : name;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _embeddedShell();
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              extended: MediaQuery.sizeOf(context).width >= 1080,
              backgroundColor: Colors.white,
              selectedIndex: page.clamp(0, 2),
              leading: const Padding(
                padding: EdgeInsets.fromLTRB(12, 24, 12, 32),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.camera_outlined, color: accent, size: 28),
                    SizedBox(width: 10),
                    Text(
                      appBrandName,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              onDestinationSelected: (index) => setState(() => _page = index),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.print_outlined),
                  label: Text('打印工单'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.tune_outlined),
                  label: Text('打印设置'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  label: Text('运行日志'),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _standaloneBody()),
          ],
        ),
      ),
    );
  }

  Widget _standaloneBody() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if ((page == 0 && bridge.configured) || page != 0) header(),
      if (bridge.busy) const LinearProgressIndicator(minHeight: 2),
      if (bridge.error != null)
        Container(
          color: const Color(0xfffff0e8),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: SelectableText(
            appErrorMessage(bridge.error!),
            style: const TextStyle(color: Color(0xff923f20)),
          ),
        ),
      if (bridge.systemPrinterIssue case final issue?)
        MaterialBanner(
          content: Text(issue),
          actions: [
            TextButton(
              onPressed: bridge.checkSystemPrinters,
              child: const Text('重新检查打印机'),
            ),
          ],
        ),
      if (bridge.configured && bridge.config['statusCommand'] == null)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '当前平台未配置打印状态观察：送打受理无法证明实际出纸，请核对实物。',
            style: TextStyle(color: Color(0xff923f20)),
          ),
        ),
      Expanded(
        child: !bridge.connected
            ? Center(
                child: bridge.storageUnavailable
                    ? TextButton(
                        onPressed:
                            widget.session?.startPrinting ??
                            () => bridge.start(),
                        child: const Text('重新检查打印存储'),
                      )
                    : Text(bridge.error == null ? '正在连接打印内核…' : '暂时无法使用打印'),
              )
            : IndexedStack(
                sizing: StackFit.expand,
                index: !bridge.configured || page == 1
                    ? 0
                    : page == 0
                    ? 1
                    : 2,
                children: [
                  SettingsPanel(
                    bridge: bridge,
                    perform: perform,
                    embedded: false,
                    session: widget.session,
                  ),
                  bridge.configured
                      ? jobsView()
                      : const Center(child: Text('请先在「打印设置」申请景区打印权限。')),
                  logsView(),
                ],
              ),
      ),
    ],
  );

  Widget _embeddedShell() {
    final putControlsInHeader =
        widget.onBack != null &&
        MediaQuery.sizeOf(context).width >= 960 &&
        MediaQuery.textScalerOf(context).scale(14) <= 17;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: widget.onBack == null
          ? null
          : AppBar(
              backgroundColor: WorkstationStyle.card,
              surfaceTintColor: Colors.transparent,
              toolbarHeight: 64,
              titleSpacing: 8,
              shape: const Border(
                bottom: BorderSide(color: WorkstationStyle.line),
              ),
              leading: IconButton(
                tooltip: '返回工作台',
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  _scaffoldKey.currentState?.closeEndDrawer();
                  widget.onBack!();
                },
              ),
              title: Row(
                children: [
                  const Text(
                    '打印照片',
                    style: TextStyle(
                      color: WorkstationStyle.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (putControlsInHeader && bridge.connected) ...[
                    const SizedBox(width: 16),
                    const SizedBox(
                      height: 24,
                      child: VerticalDivider(width: 1),
                    ),
                    const SizedBox(width: 8),
                    Flexible(child: _scenicControl()),
                    if (bridge.configured) ...[
                      const SizedBox(width: 12),
                      _connectionStatus(),
                    ],
                  ],
                ],
              ),
              actions: [
                if (putControlsInHeader &&
                    bridge.connected &&
                    bridge.configured)
                  _autoPrintControl(),
                if (putControlsInHeader && bridge.connected)
                  _printSettingsButton(),
                const SizedBox(width: 8),
                UpdateButton(session: widget.session),
                const SizedBox(width: 8),
              ],
            ),
      body: Scaffold(
        key: _scaffoldKey,
        backgroundColor: Colors.transparent,
        endDrawer: Drawer(
          width: MediaQuery.sizeOf(context).width.clamp(280, 560),
          child: SafeArea(
            child: SettingsPanel(
              bridge: bridge,
              perform: perform,
              embedded: true,
              session: widget.session,
            ),
          ),
        ),
        body: SafeArea(
          top: false,
          child: !bridge.connected
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      bridge.error == null
                          ? '正在连接打印内核…'
                          : appErrorMessage(bridge.error!),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _embeddedWorkspace(putControlsInHeader),
        ),
      ),
    );
  }

  Widget _embeddedWorkspace(bool putControlsInHeader) {
    final pad = MediaQuery.sizeOf(context).width >= 960 ? 20.0 : 12.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 12, pad, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!putControlsInHeader)
            Wrap(
              spacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _scenicControl(),
                if (bridge.configured) ...[
                  _connectionStatus(),
                  _autoPrintControl(),
                ],
                _printSettingsButton(),
              ],
            ),
          if (bridge.busy) const LinearProgressIndicator(minHeight: 2),
          if (bridge.error case final error?)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SelectableText(
                appErrorMessage(error),
                style: const TextStyle(color: WorkstationStyle.bad),
              ),
            ),
          if (bridge.configured && bridge.config['statusCommand'] == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '未配置打印状态监测，请核对实物是否出纸。',
                style: TextStyle(color: WorkstationStyle.warn),
              ),
            ),
          if (!putControlsInHeader) const SizedBox(height: 8),
          Expanded(
            child: bridge.configured ? jobsView(compact: true) : _needConfig(),
          ),
        ],
      ),
    );
  }

  Widget _printSettingsButton() => TextButton.icon(
    key: const ValueKey('print-settings-button'),
    onPressed: openConfig,
    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    icon: const Icon(Icons.tune_outlined, size: 18),
    label: const Text('打印设置'),
  );

  Widget _scenicControl() => TextButton(
    key: const ValueKey('print-open-config'),
    onPressed: openConfig,
    style: TextButton.styleFrom(
      foregroundColor: WorkstationStyle.ink,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(40, 44),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.landscape_outlined, size: 18),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            bridge.configured ? scenicLabel : '连接景区',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Icon(Icons.keyboard_arrow_down, size: 18),
      ],
    ),
  );

  Widget _connectionStatus() => Text.rich(
    TextSpan(
      children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Icon(
            bridge.printing ? Icons.print_outlined : Icons.circle,
            size: bridge.printing ? 16 : 7,
            color: bridge.printing
                ? WorkstationStyle.accent
                : WorkstationStyle.ok,
          ),
        ),
        TextSpan(text: bridge.printing ? '  正在打印，请勿关闭设备' : '  打印服务已连接'),
      ],
    ),
    style: const TextStyle(color: WorkstationStyle.muted, fontSize: 13),
  );

  Widget _autoPrintControl() {
    final enabled = bridge.state['autoPrint'] == true;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '自动打印 ${enabled ? '开启' : '关闭'}',
          style: const TextStyle(color: WorkstationStyle.ink, fontSize: 13),
        ),
        if (bridge.printing && !enabled)
          TextButton(
            onPressed: () => perform('autoPrint', [false]),
            child: const Text('当前单结束后停止'),
          ),
        const SizedBox(width: 4),
        Semantics(
          label: '自动打印',
          child: Switch(
            value: enabled,
            activeTrackColor: WorkstationStyle.accent,
            onChanged: bridge.configured && (!bridge.busy || enabled)
                ? (value) async {
                    if (!value ||
                        await confirm(
                          '开启自动打印',
                          '有新任务时会自动打印。请确认打印机和相纸已准备好。',
                          '开启自动打印',
                        )) {
                      if (mounted) await perform('autoPrint', [value]);
                    }
                  }
                : null,
          ),
        ),
      ],
    );
  }

  Widget _needConfig() => DecoratedBox(
    decoration: WorkstationStyle.surface(),
    child: LayoutBuilder(
      builder: (context, bounds) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (bounds.maxHeight - 44).clamp(0, double.infinity),
            maxWidth: 480,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xff69489a), Color(0xff271b45)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.print_outlined,
                  color: Colors.white,
                  size: 34,
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                '开通打印工作台',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: WorkstationStyle.ink,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '选择景区并提交申请。运营通过后，在本机刷新申请状态即可开通。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: WorkstationStyle.muted,
                  height: 1.55,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              PrintEnrollmentPanel(bridge: bridge, session: widget.session),
            ],
          ),
        ),
      ),
    ),
  );

  Widget header() => Container(
    color: Colors.white,
    padding: const EdgeInsets.all(24),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.embedded ? '打印任务' : ['打印工作台', '打印设置', '运行日志'][page],
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              bridge.configured
                  ? '${bridge.config['scenicName']}${bridge.printing ? ' · 正在打印，请勿关闭设备' : ''}'
                  : '连接景区，配置打印机后开始工作',
              style: const TextStyle(color: muted),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              bridge.connected ? Icons.check_circle_outline : Icons.sync,
              size: 18,
              color: bridge.connected ? accent : muted,
            ),
            const SizedBox(width: 6),
            Text(
              bridge.printing
                  ? '打印中'
                  : bridge.connected
                  ? '打印服务已连接'
                  : '连接中',
            ),
            const SizedBox(width: 20),
            _autoPrintControl(),
          ],
        ),
      ],
    ),
  );

  Widget jobsView({bool compact = false}) {
    final state = bridge.state;
    final generating = filter == _generatingFilter;
    final loadedFilter = state['jobQuery']?['printStatus'];
    final matchesFilter =
        loadedFilter == filter || (loadedFilter == null && !generating);
    final pending = filter == 'UNPRINTED';
    final jobs = !matchesFilter
        ? <Json>[]
        : pending
        ? _pendingRows(state)
        : bridge.jobs;
    final ids = generating
        ? <String>{}
        : {
            for (final job in jobs)
              if (_JobAction.values.any((action) => action.supports(job)))
                '${job['id']}',
          };
    selected.retainAll(ids);
    final jobPage = matchesFilter ? state['jobPage'] : null;
    final listError = matchesFilter ? state['listError'] as String? : null;
    final recoveryError = state['recoveryError'] as String? ?? '';
    final loading = state['listBusy'] == true || bridge.working;
    final total = (jobPage?['total'] as num?)?.toInt() ?? 0;
    final number = (jobPage?['pageNum'] as num?)?.toInt() ?? 1;
    final pageSize = (jobPage?['pageSize'] as num?)?.toInt() ?? 20;
    return Padding(
      padding: EdgeInsets.all(compact ? 0 : 16),
      child: Material(
        color: WorkstationStyle.card,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: WorkstationStyle.line),
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, bounds) {
            final table =
                bounds.maxWidth >= 740 &&
                MediaQuery.textScalerOf(context).scale(14) <= 17;
            final header = table && jobs.isNotEmpty
                ? ColoredBox(
                    color: WorkstationStyle.bg,
                    child: DefaultTextStyle.merge(
                      style: const TextStyle(
                        color: WorkstationStyle.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      child: _queueColumns(
                        checkbox: generating ? null : _selectAll(ids),
                        identity: Text(
                          generating ? '取片卡尾号 / 小票' : '取片卡尾号 / 工单',
                        ),
                        photos: const Text('照片预览'),
                        details: const Text('打印内容'),
                        status: const Text('状态'),
                        time: Text(generating ? '提交时间' : '创建时间'),
                        action: generating ? null : const Text('操作'),
                      ),
                    ),
                  )
                : null;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 60),
                  child: _viewingBatches || selected.isEmpty
                      ? _queueToolbar(number)
                      : _batchToolbar(
                          jobs
                              .where((job) => selected.contains('${job['id']}'))
                              .toList(),
                          selectAll: table ? null : _selectAll(ids),
                        ),
                ),
                const Divider(height: 1, color: WorkstationStyle.line),
                if (_viewingBatches)
                  Expanded(
                    child: PhotoBatchTimeline(
                      key: ValueKey(bridge.config['activeScenicProfileId']),
                      call: bridge.call,
                      scenicName: scenicLabel,
                    ),
                  )
                else ...[
                  if (pending && recoveryError.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        recoveryError,
                        style: const TextStyle(color: WorkstationStyle.warn),
                      ),
                    ),
                  if (pending && matchesFilter)
                    _printIssueControls(state, number),
                  ?header,
                  Expanded(
                    child: jobs.isEmpty
                        ? Center(
                            child: Text(
                              _emptyQueueMessage(
                                generating,
                                loading,
                                listError,
                              ),
                              style: const TextStyle(
                                color: WorkstationStyle.muted,
                              ),
                            ),
                          )
                        : ListView.separated(
                            key: PageStorageKey((
                              filter,
                              dates,
                              number,
                              bridge.config['activeScenicProfileId'],
                            )),
                            padding: EdgeInsets.zero,
                            itemCount: jobs.length,
                            separatorBuilder: (_, _) => const Divider(
                              height: 1,
                              color: WorkstationStyle.line,
                            ),
                            itemBuilder: (context, index) => generating
                                ? _generatingRow(jobs[index], table: table)
                                : _jobRow(jobs[index], table: table),
                          ),
                  ),
                  const Divider(height: 1, color: WorkstationStyle.line),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${pending ? '排队' : '共'} $total 单 · 第 $number 页',
                          style: const TextStyle(color: WorkstationStyle.muted),
                        ),
                        IconButton(
                          tooltip: '上一页',
                          onPressed: number > 1 && !bridge.busy
                              ? () => query(number: number - 1)
                              : null,
                          icon: const Icon(Icons.chevron_left),
                        ),
                        IconButton(
                          tooltip: '下一页',
                          onPressed: number * pageSize < total && !bridge.busy
                              ? () => query(number: number + 1)
                              : null,
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  String _emptyQueueMessage(bool generating, bool loading, String? listError) {
    if (!generating) return '暂无符合条件的打印任务';
    if (loading) return '正在查询生成中的任务…';
    if (listError != null && listError.isNotEmpty) {
      return appErrorMessage(listError);
    }
    return '暂无正在生成的任务';
  }

  Widget _queueToolbar(int pageNumber) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Wrap(
          spacing: 2,
          children: [
            for (final entry in const {
              'UNPRINTED': '待打印',
              _generatingFilter: '生成中',
              'PRINTED': '已打印',
            }.entries)
              _queueTab(
                entry.value,
                !_viewingBatches && filter == entry.key,
                () {
                  final changed = filter != entry.key;
                  setState(() {
                    _viewingBatches = false;
                    filter = entry.key;
                  });
                  if (changed) query();
                },
              ),
            _queueTab('查看批次', _viewingBatches, () {
              setState(() => _viewingBatches = true);
            }),
          ],
        ),
        Wrap(
          spacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!_viewingBatches) ...[
              JobCreatedRangeField(
                value: dates,
                enabled: !bridge.busy,
                onChanged: (range) {
                  setState(() => dates = range);
                  query();
                },
              ),
              IconButton(
                tooltip: filter == _generatingFilter ? '刷新生成中的任务' : '刷新打印任务',
                onPressed: bridge.busy ? null : () => query(number: pageNumber),
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
            if (widget.embedded)
              TextButton.icon(
                style: _queueButtonStyle(),
                onPressed: _openLogs,
                icon: const Icon(Icons.history, size: 18),
                label: const Text('打印记录'),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _queueTab(String label, bool active, VoidCallback onPressed) =>
      Semantics(
        selected: active,
        child: TextButton(
          style: _queueButtonStyle(
            foreground: active
                ? WorkstationStyle.accent
                : WorkstationStyle.muted,
            background: active ? WorkstationStyle.accentSoft : null,
          ),
          onPressed: bridge.busy ? null : onPressed,
          child: Text(label),
        ),
      );

  List<Json> _pendingRows(Json state) {
    final issues = state['printIssues']?['list'] as List? ?? const [];
    final local = state['localPrintIssues'] as List? ?? const [];
    final recovery = state['recoveryJobs'] as List? ?? const [];
    final active = state['activePrintJob'];
    final byId = <String, Json>{
      for (final row in [
        ...bridge.jobs,
        ...issues,
        ...local,
        ...recovery,
        ?active,
      ])
        '${row['id']}': Map<String, dynamic>.from(row as Map),
    };
    // 工单 ID 是十进制字符串，按位数和字典序排序以保留任意精度。
    return byId.values.toList()..sort((left, right) {
      final a = '${left['id']}';
      final b = '${right['id']}';
      final length = b.length.compareTo(a.length);
      return length == 0 ? b.compareTo(a) : length;
    });
  }

  Widget _printIssueControls(Json state, int queuePage) {
    final page = state['printIssues'] as Map?;
    final error = state['printIssuesError'] as String? ?? '';
    final total = (page?['total'] as num?)?.toInt() ?? 0;
    final number = (page?['pageNum'] as num?)?.toInt() ?? 1;
    final size = (page?['pageSize'] as num?)?.toInt() ?? 10;
    if (error.isNotEmpty) {
      return TextButton.icon(
        style: _queueButtonStyle(foreground: WorkstationStyle.warn),
        onPressed: bridge.busy
            ? null
            : () => query(number: queuePage, issuePage: number),
        icon: const Icon(Icons.warning_amber_outlined, size: 18),
        label: const Text('打印异常列表加载失败，点击重试'),
      );
    }
    if (total <= size) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('打印异常 $total 单 · 第 $number 页'),
        IconButton(
          tooltip: '上一页打印异常',
          onPressed: number > 1 && !bridge.busy
              ? () => query(number: queuePage, issuePage: number - 1)
              : null,
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          tooltip: '下一页打印异常',
          onPressed: number * size < total && !bridge.busy
              ? () => query(number: queuePage, issuePage: number + 1)
              : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  void _openLogs() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('打印记录'),
      content: SizedBox(width: 560, height: 380, child: logsView()),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  ButtonStyle _queueButtonStyle({
    Color foreground = WorkstationStyle.muted,
    Color? background,
  }) => TextButton.styleFrom(
    foregroundColor: foreground,
    backgroundColor: background,
    minimumSize: const Size(44, 44),
    padding: const EdgeInsets.symmetric(horizontal: 10),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
    ),
  );

  Widget _batchToolbar(List<Json> jobs, {Widget? selectAll}) {
    final actions = _JobAction.values.where(
      (action) => jobs.every(action.supports),
    );
    final ids = jobs.map((job) => '${job['id']}').toList();
    return ColoredBox(
      color: WorkstationStyle.accentSoft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ?selectAll,
            Semantics(
              liveRegion: true,
              child: Text(
                '已选 ${jobs.length} 单',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (actions.isEmpty)
              const Text(
                '所选任务没有共同操作',
                style: TextStyle(color: WorkstationStyle.muted),
              ),
            for (final action in actions)
              if (action == _JobAction.print)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: WorkstationStyle.accent,
                    minimumSize: const Size(44, 44),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
                  ),
                  onPressed: bridge.busy
                      ? null
                      : () => _applyJobAction(action, ids),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('打印选中'),
                )
              else
                TextButton(
                  style: _queueButtonStyle(foreground: WorkstationStyle.ink),
                  onPressed: bridge.busy
                      ? null
                      : () => _applyJobAction(action, ids),
                  child: Text(action.label),
                ),
            TextButton(
              style: _queueButtonStyle(),
              onPressed: () => setState(selected.clear),
              child: const Text('取消选择'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _applyJobAction(_JobAction action, List<String> ids) async {
    if (action == _JobAction.resume &&
        !await confirm('续打剩余照片', '补纸后请先核对纸面和打印队列。照片未出齐且队列无待出作业时再续打。', '续打')) {
      return;
    }
    if (action == _JobAction.confirm &&
        !await confirm('确认已打印', '请先核对纸面已齐。本操作只更新状态，不会再次打印。', '确认已打印')) {
      return;
    }
    if (action == _JobAction.reset &&
        !await confirm('标记为未打印', '将重置整单进度。后续打印会从头出纸，请核对实物，避免重复。', '标记未打印')) {
      return;
    }
    if (mounted) await perform(action.method, [ids]);
  }

  Widget _selectAll(Set<String> ids) => Tooltip(
    message: '选择本页任务',
    child: Checkbox(
      tristate: true,
      value: selected.isEmpty
          ? false
          : selected.length == ids.length
          ? true
          : null,
      onChanged: bridge.busy || ids.isEmpty
          ? null
          : (_) => setState(() {
              if (selected.length == ids.length) {
                selected.clear();
              } else {
                selected.addAll(ids);
              }
            }),
    ),
  );

  Widget _queueColumns({
    Widget? checkbox,
    required Widget identity,
    required Widget photos,
    required Widget details,
    required Widget status,
    required Widget time,
    Widget? action,
  }) => Padding(
    padding: const EdgeInsets.only(left: 4, right: 16),
    child: Row(
      spacing: 10,
      children: [
        SizedBox(
          width: 44,
          child: checkbox ?? const SizedBox(height: kMinInteractiveDimension),
        ),
        Expanded(flex: 14, child: identity),
        Expanded(flex: 22, child: photos),
        Expanded(flex: 19, child: details),
        Expanded(flex: 10, child: status),
        Expanded(flex: 12, child: time),
        SizedBox(width: 104, child: Center(child: action)),
      ],
    ),
  );

  Widget _generatingRow(Json receipt, {required bool table}) {
    final id = receipt['receiptId'] as String;
    final tail = (receipt['cardTail'] as String?)?.trim() ?? '';
    final submitted = DateTime.parse(receipt['submittedAt'] as String);
    final time = formatWallClock(
      submitted.toUtc().add(const Duration(hours: 8)),
    ).substring(0, 16);
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tail.isEmpty ? '无取片卡' : tail,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        Text('小票 #$id', style: _jobMeta),
      ],
    );
    const status = StatusBadge(status: _generatingFilter);
    final submittedLabel = Text(time, style: _jobMeta);
    final originalCount = receipt['originalPhotoCount'] as int?;
    final estimatedTotal = receipt['estimatedTotalSheets'] as int?;
    final summary = receipt['estimatedContentSummary'] as String?;
    final photos = originalCount != null && originalCount > 0
        ? JobThumbnails.originals(
            bridge: bridge,
            receiptId: id,
            originalUrls: (receipt['originalThumbnailUrls'] as List)
                .cast<String>(),
            originalPhotoCount: originalCount,
          )
        : Text(switch (originalCount) {
            0 => '无原片',
            _ when summary == null => '当前服务未提供原片预览',
            _ => '原片待核',
          }, style: _jobMeta);
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (estimatedTotal != null)
          Text(
            '预计 $estimatedTotal 张',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        Text(summary ?? '当前服务未提供打印明细', style: _jobMeta),
      ],
    );
    return ColoredBox(
      key: ValueKey(id),
      color: WorkstationStyle.card,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: table
            ? _queueColumns(
                identity: identity,
                photos: photos,
                details: details,
                status: Align(alignment: Alignment.centerLeft, child: status),
                time: submittedLabel,
              )
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [identity, status],
                    ),
                    photos,
                    details,
                    submittedLabel,
                  ],
                ),
              ),
      ),
    );
  }

  Widget _jobRow(Json job, {required bool table}) {
    final id = '${job['id']}';
    final tail = '${job['cardTail'] ?? ''}'.trim();
    final phone = '${job['phone'] ?? ''}'.trim();
    final total = (job['totalSheets'] as num?)?.toInt();
    final completed = (job['completedSheets'] as num?)?.toInt() ?? 0;
    final reason = '${job['errorReason'] ?? ''}'.trim();
    final state = '${job['status']}';
    final summary = '${job['contentSummary'] ?? '内容未知'}';
    final created = '${job['createdAt'] ?? '—'}'.replaceFirst('T', ' ');
    final time = created.length >= 16 ? created.substring(0, 16) : created;
    final isSelected = selected.contains(id);
    void openPreview() => showDialog<void>(
      context: context,
      builder: (_) => PreviewDialog(
        bridge: bridge,
        jobId: id,
        cardTail: tail,
        perform: perform,
      ),
    );

    final checkbox = Tooltip(
      message: '选择工单 #$id',
      child: Checkbox(
        value: isSelected,
        onChanged:
            bridge.busy ||
                !_JobAction.values.any((action) => action.supports(job))
            ? null
            : (checked) => setState(() {
                if (checked == true) {
                  selected.add(id);
                } else {
                  selected.remove(id);
                }
              }),
      ),
    );
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tail.isNotEmpty
              ? tail
              : phone.isNotEmpty
              ? phone
              : '无取片卡',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        Text('#$id', style: _jobMeta),
        if (tail.isNotEmpty && phone.isNotEmpty) Text(phone, style: _jobMeta),
      ],
    );
    final photos = JobThumbnails(
      key: ValueKey((bridge.config['activeScenicProfileId'], id)),
      bridge: bridge,
      jobId: id,
      contentSummary: summary,
      onOpenPreview: openPreview,
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (total != null && total > 0)
          Text(
            '共 $total 张',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        Text(summary, style: _jobMeta),
        if (completed > 0)
          Text(
            total != null && total > 0
                ? '已完成 $completed / $total 张'
                : '已完成 $completed 张',
            style: _jobMeta,
          ),
        if (reason.isNotEmpty)
          Tooltip(
            message: reason,
            child: Text(
              reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _jobMeta.copyWith(color: WorkstationStyle.warn),
            ),
          ),
      ],
    );
    final status = StatusBadge(
      status: state == 'FAILED' && reason.contains('缺纸') ? 'PAPER_OUT' : state,
    );
    final action = _rowAction(job, id);
    return ColoredBox(
      key: ValueKey(id),
      color: isSelected ? WorkstationStyle.accentSoft : WorkstationStyle.card,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: table
            ? _queueColumns(
                checkbox: checkbox,
                identity: identity,
                photos: photos,
                details: details,
                status: Align(alignment: Alignment.centerLeft, child: status),
                time: Text(time, style: _jobMeta),
                action: action,
              )
            : Padding(
                padding: const EdgeInsets.only(left: 4, right: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    checkbox,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 6,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 4,
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [identity, status],
                          ),
                          details,
                          Text(time, style: _jobMeta),
                          SizedBox(
                            width: double.infinity,
                            child: Wrap(
                              spacing: 6,
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [photos, action],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _rowAction(Json job, String id) {
    if (job['status'] == 'RECOVERY_REQUIRED') {
      return OutlinedButton(
        onPressed: bridge.busy
            ? null
            : () => showDialog<void>(
                context: context,
                builder: (_) => PrintRecoveryDialog(
                  bridge: bridge,
                  jobId: id,
                  perform: perform,
                ),
              ),
        child: const Text('核对打印'),
      );
    }
    final canPrint = _JobAction.print.supports(job);
    final canResume = _JobAction.resume.supports(job);
    if (canPrint || canResume) {
      final action = canPrint ? _JobAction.print : _JobAction.resume;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: WorkstationStyle.accent,
              side: const BorderSide(color: WorkstationStyle.line),
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
            ),
            onPressed: bridge.busy ? null : () => _applyJobAction(action, [id]),
            child: Text(canPrint ? '打印本单' : '续打'),
          ),
          if (canResume) _exceptionMenu(job, id, compact: true),
        ],
      );
    }
    if (_JobAction.confirm.supports(job)) return _exceptionMenu(job, id);
    return const SizedBox.shrink();
  }

  Widget _exceptionMenu(Json job, String id, {bool compact = false}) =>
      PopupMenuButton<_JobAction>(
        enabled: !bridge.busy,
        tooltip: '处理异常',
        icon: compact ? const Icon(Icons.more_horiz, size: 18) : null,
        onSelected: (action) => _applyJobAction(action, [id]),
        itemBuilder: (context) => [
          for (final action in [_JobAction.confirm, _JobAction.reset])
            if (action.supports(job))
              PopupMenuItem(value: action, child: Text(action.label)),
        ],
        child: compact
            ? null
            : const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text('处理异常'), Icon(Icons.expand_more, size: 16)],
                ),
              ),
      );

  static const _jobMeta = TextStyle(
    color: WorkstationStyle.muted,
    fontSize: 12,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  Widget logsView() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text('日志仅记录运行事件', style: TextStyle(color: muted)),
      const SizedBox(height: 16),
      for (final entry in (bridge.snapshot['logs'] as List? ?? []).reversed)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SelectableText('${entry['at']}  ${entry['message']}'),
        ),
    ],
  );
}

enum _JobAction {
  print('printJobs', '打印选中'),
  resume('continueJobs', '继续剩余'),
  confirm('confirmPrinted', '确认已打印'),
  reset('markUnprinted', '标记未打印');

  const _JobAction(this.method, this.label);

  final String method;
  final String label;

  bool supports(Json job) {
    final status = job['status'];
    return switch (this) {
      _JobAction.print => status == 'QUEUED',
      _JobAction.resume => _canResume(job),
      _JobAction.confirm => status == 'FAILED' || status == 'UNKNOWN',
      _JobAction.reset => status == 'FAILED' || status == 'PRINTED',
    };
  }

  static bool _canResume(Json job) {
    final completed = (job['completedSheets'] as num?)?.toInt() ?? 0;
    final total = (job['totalSheets'] as num?)?.toInt() ?? 0;
    return job['status'] == 'FAILED' &&
        completed > 0 &&
        (total <= 0 || completed < total);
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color, background) = switch (status) {
      'QUEUED' => ('待打印', WorkstationStyle.muted, WorkstationStyle.bg),
      _generatingFilter => (
        'AI 创意生成中',
        WorkstationStyle.accent,
        WorkstationStyle.accentSoft,
      ),
      'CLAIMED' => (
        '已领取',
        WorkstationStyle.accent,
        WorkstationStyle.accentSoft,
      ),
      'PRINTING' => (
        '打印中',
        WorkstationStyle.accent,
        WorkstationStyle.accentSoft,
      ),
      'PRINTED' => ('已打印', WorkstationStyle.ok, WorkstationStyle.okSoft),
      'FAILED' => ('需处理', WorkstationStyle.warn, WorkstationStyle.warnSoft),
      'PAPER_OUT' => ('缺纸中断', WorkstationStyle.warn, WorkstationStyle.warnSoft),
      'UNKNOWN' || 'RESULT_UNCONFIRMED' || 'RECOVERY_REQUIRED' => (
        '待核对',
        WorkstationStyle.warn,
        WorkstationStyle.warnSoft,
      ),
      _ => (status, WorkstationStyle.muted, WorkstationStyle.bg),
    };
    return StatusTag(label: label, color: color, soft: background);
  }
}
