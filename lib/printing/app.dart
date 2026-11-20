import 'package:material_ui/material_ui.dart';

import 'print_bridge.dart';
import 'ui/design.dart';
import 'ui/settings_panel.dart';
import 'ui/preview_dialog.dart';

class Workstation extends StatefulWidget {
  const Workstation({
    super.key,
    required this.bridge,
    this.embedded = false,
    this.selectedPage,
  });
  final PrintBridge bridge;
  final bool embedded;
  final int? selectedPage;
  @override
  State<Workstation> createState() => _WorkstationState();
}

class _WorkstationState extends State<Workstation> {
  PrintBridge get bridge => widget.bridge;
  int _page = 0;
  int get page => widget.selectedPage ?? _page;
  String filter = 'ALL';
  final selected = <String>{};
  DateTimeRange? dates;
  @override
  void initState() {
    super.initState();
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

  Future<void> perform(String method, [List<dynamic> args = const []]) async {
    try {
      final result = await bridge.run(method, args);
      if (!mounted) return;
      if (result is Map && result['needConfirm'] == true) {
        final agreed = await confirm(
          '驱动报告缺纸',
          '${result['message']}\n请核实纸匣已有纸，确认是误报后才忽略缺纸继续。',
          '已核实，继续打印',
        );
        if (agreed) {
          await perform(method, [
            args.first,
            {'ignorePaperOut': true},
          ]);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<bool> confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> query({int number = 1}) async {
    selected.clear();
    await perform('queryJobs', [
      {
        'printStatus': filter,
        'pageNum': number,
        'pageSize': 20,
        'createdFrom': dates == null ? '' : '${date(dates!.start)} 00:00:00',
        'createdTo': dates == null ? '' : '${date(dates!.end)} 23:59:59',
      },
    ]);
  }

  String date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Row(
        children: [
          if (!widget.embedded)
            NavigationRail(
              extended: MediaQuery.sizeOf(context).width >= 1080,
              backgroundColor: Colors.white,
              selectedIndex: page,
              leading: const Padding(
                padding: EdgeInsets.fromLTRB(12, 24, 12, 32),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.camera_outlined, color: accent, size: 28),
                    SizedBox(width: 10),
                    Text(
                      '帧集',
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
          if (!widget.embedded) const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!widget.embedded || page == 0 && bridge.configured)
                  header(),
                if (bridge.busy) const LinearProgressIndicator(minHeight: 2),
                if (bridge.error != null)
                  Container(
                    color: const Color(0xfffff0e8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    child: SelectableText(
                      bridge.error!,
                      style: const TextStyle(color: Color(0xff923f20)),
                    ),
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
                          child: Text(
                            bridge.error == null ? '正在连接打印内核…' : '暂时无法使用打印',
                          ),
                        )
                      : IndexedStack(
                          sizing: StackFit.expand,
                          index:
                              (!bridge.configured && !widget.embedded) ||
                                  page == 1 ||
                                  page == 3
                              ? 0
                              : page == 0
                              ? 1
                              : 2,
                          children: [
                            SettingsPanel(
                              bridge: bridge,
                              perform: perform,
                              embedded: widget.embedded,
                              showChecks: page == 3,
                            ),
                            bridge.configured
                                ? jobsView()
                                : const Center(child: Text('请先在「打印设置」连接景区。')),
                            logsView(),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
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
            const Text('自动打印'),
            Switch(
              value: bridge.state['autoPrint'] == true,
              onChanged: bridge.configured && !bridge.busy
                  ? (value) async {
                      if (!value ||
                          await confirm(
                            '开启自动打印',
                            '有新任务时会自动打印。请确认打印机和相纸已准备好。',
                            '开启自动打印',
                          )) {
                        await perform('autoPrint', [value]);
                      }
                    }
                  : null,
            ),
          ],
        ),
      ],
    ),
  );

  Widget jobsView() {
    final jobs = bridge.jobs;
    final ids = jobs.map((e) => '${e['id']}').toSet();
    selected.removeWhere((id) => !ids.contains(id));
    final total = bridge.state['jobPage']?['total'] ?? 0;
    final number = (bridge.state['jobPage']?['pageNum'] as num? ?? 1).toInt();
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final entry in const {
                'ALL': '全部任务',
                'UNPRINTED': '待打印',
                'FAILED': '需处理',
                'PRINTED': '已打印',
              }.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: filter == entry.key,
                  onSelected: bridge.busy
                      ? null
                      : (_) {
                          setState(() => filter = entry.key);
                          query();
                        },
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.date_range_outlined, size: 18),
                label: Text(
                  dates == null
                      ? '选择日期'
                      : '${date(dates!.start)} — ${date(dates!.end)}',
                ),
                onPressed: bridge.busy
                    ? null
                    : () async {
                        final range = await showDateRangePicker(
                          context: context,
                          firstDate: DateTime(2024),
                          lastDate: DateTime.now().add(const Duration(days: 1)),
                          initialDateRange: dates,
                        );
                        if (range != null) {
                          setState(() => dates = range);
                          await query();
                        }
                      },
              ),
              if (dates != null)
                IconButton(
                  tooltip: '清除日期',
                  onPressed: bridge.busy
                      ? null
                      : () {
                          setState(() => dates = null);
                          query();
                        },
                  icon: const Icon(Icons.close),
                ),
              IconButton(
                tooltip: '刷新打印任务',
                onPressed: bridge.busy ? null : () => query(number: number),
                icon: const Icon(Icons.refresh),
              ),
              if (widget.embedded)
                TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('打印记录'),
                      content: SizedBox(
                        width: 560,
                        height: 380,
                        child: logsView(),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('打印记录'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '已选 ${selected.length} 单',
                  style: const TextStyle(color: muted),
                ),
                FilledButton.icon(
                  onPressed: selected.isEmpty || bridge.busy
                      ? null
                      : () => perform('printJobs', [selected.toList()]),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('打印选中'),
                ),
                OutlinedButton(
                  onPressed: selected.isEmpty || bridge.busy
                      ? null
                      : () => perform('continueJobs', [selected.toList()]),
                  child: const Text('继续剩余'),
                ),
                PopupMenuButton<String>(
                  enabled: selected.isNotEmpty && !bridge.busy,
                  tooltip: '工单处理',
                  onSelected: (method) async {
                    final yes = await confirm(
                      method == 'confirmPrinted' ? '确认已出纸' : '标记为未打印',
                      method == 'confirmPrinted'
                          ? '请先核对纸面已齐。本操作更新状态，不会再次打印。'
                          : '将重置整单进度。后续打印会从头出纸，请核对实物，避免重复。',
                      '确认',
                    );
                    if (yes) await perform(method, [selected.toList()]);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'confirmPrinted',
                      child: Text('确认已打印'),
                    ),
                    PopupMenuItem(value: 'markUnprinted', child: Text('标记未打印')),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('更多处理 ▾'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: jobs.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inbox_outlined, size: 42, color: muted),
                          SizedBox(height: 12),
                          Text('暂无符合条件的打印任务'),
                          SizedBox(height: 8),
                          Text(
                            '新工单会自动刷新，也可调整筛选条件',
                            style: TextStyle(color: muted),
                          ),
                        ],
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: constraints.maxWidth,
                            ),
                            child: DataTable(
                              headingRowHeight: 48,
                              dataRowMinHeight: 80,
                              dataRowMaxHeight: 118,
                              columnSpacing: 24,
                              showCheckboxColumn: true,
                              columns: const [
                                DataColumn(label: Text('任务 / 取片码')),
                                DataColumn(label: Text('状态')),
                                DataColumn(label: Text('打印内容')),
                                DataColumn(label: Text('创建时间')),
                                DataColumn(label: Text('操作')),
                              ],
                              rows: jobs.map((job) {
                                final id = '${job['id']}';
                                return DataRow(
                                  selected: selected.contains(id),
                                  onSelectChanged: bridge.busy
                                      ? null
                                      : (value) => setState(() {
                                          if (value == true) {
                                            selected.add(id);
                                          } else {
                                            selected.remove(id);
                                          }
                                        }),
                                  cells: [
                                    DataCell(
                                      Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '#$id',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontFeatures: [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            '尾号 ${job['cardTail'] ?? '—'}',
                                            style: const TextStyle(
                                              color: muted,
                                            ),
                                          ),
                                          Text(
                                            '${job['phone'] ?? '未绑定手机'}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    DataCell(
                                      StatusBadge(status: '${job['status']}'),
                                    ),
                                    DataCell(
                                      SizedBox(
                                        width: 245,
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '${job['contentSummary'] ?? '内容未知'}',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if ((job['completedSheets']
                                                        as num? ??
                                                    0) >
                                                0)
                                              Text(
                                                '已完成 ${job['completedSheets']} / ${job['totalSheets'] ?? '—'} 张',
                                                style: const TextStyle(
                                                  color: accent,
                                                ),
                                              ),
                                            if (job['errorReason'] != null)
                                              Text(
                                                '${job['errorReason']}',
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Color(0xffa33c30),
                                                  fontSize: 12,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      Text(
                                        '${job['createdAt'] ?? '—'}'
                                            .replaceFirst('T', '\n'),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: muted,
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      TextButton(
                                        onPressed: bridge.busy
                                            ? null
                                            : () => showDialog<void>(
                                                context: context,
                                                builder: (_) => PreviewDialog(
                                                  bridge: bridge,
                                                  jobId: id,
                                                  perform: perform,
                                                ),
                                              ),
                                        child: const Text('查看照片'),
                                      ),
                                    ),
                                  ],
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                '共 $total 单 · 第 $number 页',
                style: const TextStyle(color: muted),
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
                onPressed: number * 20 < total && !bridge.busy
                    ? () => query(number: number + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget logsView() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text('只记录运行事件，不记录打印密钥与图片内容', style: TextStyle(color: muted)),
      const SizedBox(height: 16),
      for (final entry in (bridge.snapshot['logs'] as List? ?? []).reversed)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SelectableText('${entry['at']}  ${entry['message']}'),
        ),
    ],
  );
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    final label =
        const {
          'QUEUED': '待打印',
          'PRINTED': '已打印',
          'FAILED': '需处理',
          'CLAIMED': '已领取',
          'PRINTING': '打印中',
        }[status] ??
        status;
    final color = status == 'PRINTED'
        ? accent
        : status == 'FAILED'
        ? const Color(0xffa33c30)
        : muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
