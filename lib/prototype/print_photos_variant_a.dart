import 'package:material_ui/material_ui.dart';

import '../printing/ui/design.dart' as print_ui;
import '../ui/design.dart';
import 'print_photos_fake_data.dart';
import 'print_photos_proto_widgets.dart';

/// Variant A — command desk: status + search + dual columns.
class PrintPhotosVariantA extends StatelessWidget {
  const PrintPhotosVariantA({
    super.key,
    required this.autoPrint,
    required this.selected,
    required this.search,
    required this.onToggleAuto,
    required this.onToggleSelect,
    required this.onClearSelect,
    required this.onSearch,
    required this.onAction,
  });

  final bool autoPrint;
  final Set<int> selected;
  final TextEditingController search;
  final ValueChanged<bool> onToggleAuto;
  final ValueChanged<int> onToggleSelect;
  final VoidCallback onClearSelect;
  final VoidCallback onSearch;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 960;
            final status = _statusCard();
            final auto = _autoCard();
            if (!wide) {
              return Column(children: [status, const SizedBox(height: 12), auto]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 12, child: status),
                const SizedBox(width: 14),
                Expanded(flex: 10, child: auto),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        ProtoSearchField(
          controller: search,
          onSubmit: onSearch,
          hint: '输入取片码或手机号，回车找单打印',
        ),
        const SizedBox(height: 8),
        const Text(
          '柜台客人到场时优先用搜索；自动队列继续在后台跑。',
          style: TextStyle(fontSize: 12, color: WorkstationStyle.muted),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 980;
            final queue = _queuePanel();
            final alerts = _alertsPanel();
            if (!wide) {
              return Column(
                children: [queue, const SizedBox(height: 14), alerts],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 14, child: queue),
                const SizedBox(width: 14),
                Expanded(flex: 9, child: alerts),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _statusCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff0f7668), Color(0xff163a44), Color(0xff12252d)],
        ),
        boxShadow: WorkstationStyle.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PRINT DESK',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: .72),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            protoScenicName,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _glassPill(
                Icons.check_circle_outline,
                '打印服务已连接',
              ),
              _glassPill(
                Icons.autorenew,
                autoPrint ? '自动打印运行中' : '自动打印已关闭',
              ),
              _glassPill(Icons.schedule, '上次拉取 12 秒前'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _glassPill(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _autoCard() {
    return DecoratedBox(
      decoration: WorkstationStyle.surface(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '自动打印',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: WorkstationStyle.ink,
                    ),
                  ),
                ),
                Switch(
                  value: autoPrint,
                  activeThumbColor: Colors.white,
                  activeTrackColor: print_ui.accent,
                  onChanged: onToggleAuto,
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '新任务会按队列自动出纸。柜台取片或异常时，用搜索与「需处理」。',
              style: TextStyle(
                fontSize: 13,
                color: WorkstationStyle.muted,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _stat('6', '待打印')),
                const SizedBox(width: 8),
                Expanded(
                  child: _stat('2', '需处理', valueColor: WorkstationStyle.warn),
                ),
                const SizedBox(width: 8),
                Expanded(child: _stat('41', '今日已打')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String value, String label, {Color? valueColor}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xfff6f9fa),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: WorkstationStyle.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: valueColor ?? WorkstationStyle.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: WorkstationStyle.muted),
          ),
        ],
      ),
    );
  }

  Widget _queuePanel() {
    final jobs = protoPendingJobs.take(4).toList();
    return ProtoPanel(
      title: '打印队列',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => onAction('筛选待打印'),
            child: const Text('待打印'),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => onAction('刷新队列'),
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ],
      ),
      footer: selected.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Text(
                    '已选 ${selected.length} 单',
                    style: const TextStyle(color: WorkstationStyle.muted),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () => onAction('打印选中'),
                    style: FilledButton.styleFrom(
                      backgroundColor: print_ui.accent,
                    ),
                    child: const Text('打印选中'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: onClearSelect,
                    child: const Text('取消选择'),
                  ),
                ],
              ),
            ),
      child: Column(
        children: [
          for (final job in jobs) _jobRow(job),
        ],
      ),
    );
  }

  Widget _jobRow(ProtoJob job) {
    final on = selected.contains(job.id);
    return InkWell(
      onTap: () => onToggleSelect(job.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Checkbox(
              value: on,
              onChanged: (_) => onToggleSelect(job.id),
              activeColor: print_ui.accent,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        protoJobLabel(job),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        job.phone,
                        style: const TextStyle(
                          fontSize: 13,
                          color: WorkstationStyle.muted,
                        ),
                      ),
                      const StatusTag(
                        label: '队列中',
                        color: print_ui.accent,
                        soft: Color(0xffe6f4f1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ProtoThumbs(count: job.thumbCount, more: job.moreCount),
                  const SizedBox(height: 6),
                  Text(
                    '${job.content} · 今天 ${job.time}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: WorkstationStyle.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              children: [
                FilledButton(
                  onPressed: () => onAction('打印本单 ${protoJobLabel(job)}'),
                  style: FilledButton.styleFrom(
                    backgroundColor: print_ui.accent,
                    minimumSize: const Size(96, 36),
                  ),
                  child: const Text('打印本单'),
                ),
                TextButton(
                  onPressed: () => onAction('查看 ${protoJobLabel(job)}'),
                  child: const Text('查看'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _alertsPanel() {
    return ProtoPanel(
      title: '需处理',
      trailing: const StatusTag(
        label: '优先人工',
        color: WorkstationStyle.warn,
        soft: WorkstationStyle.warnSoft,
      ),
      child: Column(
        children: [
          for (final job in protoAlerts) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        protoJobLabel(job),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      StatusTag(
                        label: job.id == 552 ? '缺纸' : '中断',
                        color: job.id == 552
                            ? WorkstationStyle.warn
                            : WorkstationStyle.bad,
                        soft: job.id == 552
                            ? WorkstationStyle.warnSoft
                            : WorkstationStyle.badSoft,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    job.alertReason ?? '',
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: WorkstationStyle.ink,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () =>
                            onAction('继续打印 ${protoJobLabel(job)}'),
                        style: FilledButton.styleFrom(
                          backgroundColor: print_ui.accent,
                        ),
                        child: const Text('继续打印'),
                      ),
                      OutlinedButton(
                        onPressed: () => onAction('查看 ${protoJobLabel(job)}'),
                        child: const Text('查看照片'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (job != protoAlerts.last)
              const Divider(height: 1, color: WorkstationStyle.line),
          ],
        ],
      ),
    );
  }
}
