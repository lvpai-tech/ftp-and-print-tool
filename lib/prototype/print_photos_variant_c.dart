import 'package:material_ui/material_ui.dart';

import '../printing/ui/design.dart' as print_ui;
import '../ui/design.dart';
import 'print_photos_fake_data.dart';
import 'print_photos_proto_widgets.dart';

/// Variant C — dual focus: counter find + exceptions, queue collapsed.
class PrintPhotosVariantC extends StatelessWidget {
  const PrintPhotosVariantC({
    super.key,
    required this.autoPrint,
    required this.search,
    required this.hitVisible,
    required this.onToggleAuto,
    required this.onSearch,
    required this.onAction,
  });

  final bool autoPrint;
  final TextEditingController search;
  final bool hitVisible;
  final ValueChanged<bool> onToggleAuto;
  final VoidCallback onSearch;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '打印照片',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: WorkstationStyle.ink,
                      height: 1.1,
                    ),
                  ),
                  SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        protoScenicName,
                        style: TextStyle(
                          fontSize: 14,
                          color: WorkstationStyle.muted,
                        ),
                      ),
                      StatusTag(
                        label: '打印服务已连接',
                        color: WorkstationStyle.ok,
                        soft: WorkstationStyle.okSoft,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            ProtoAutoToggle(value: autoPrint, onChanged: onToggleAuto),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => onAction('打印记录'),
              child: const Text('打印记录'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        DecoratedBox(
          decoration: WorkstationStyle.surface(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Text(
                      '柜台找单',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Spacer(),
                    StatusTag(
                      label: '客人到场优先',
                      color: WorkstationStyle.muted,
                      soft: Color(0xffeef2f4),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ProtoSearchField(
                  controller: search,
                  onSubmit: onSearch,
                  hint: '输入取片码或手机尾号，例如 578 或 8821',
                  actionLabel: '查找并打印',
                ),
                if (hitVisible) ...[
                  const SizedBox(height: 14),
                  _hitCard(),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 960;
            final alerts = _alerts();
            final queue = _queue();
            if (!wide) {
              return Column(
                children: [alerts, const SizedBox(height: 14), queue],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: alerts),
                const SizedBox(width: 14),
                Expanded(child: queue),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _hitCard() {
    final job = protoPendingJobs.first;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Color.lerp(print_ui.accent, WorkstationStyle.line, .55)!,
        ),
        boxShadow: [
          BoxShadow(
            color: print_ui.accent.withValues(alpha: .16),
            blurRadius: 0,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Row(
        children: [
          ProtoThumbs(
            count: job.thumbCount,
            more: job.moreCount,
            size: const Size(72, 90),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  protoJobLabel(job),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '手机 ${job.phone}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: WorkstationStyle.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Text(job.content, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          Column(
            children: [
              FilledButton(
                onPressed: () => onAction('打印本单 ${protoJobLabel(job)}'),
                style: FilledButton.styleFrom(
                  backgroundColor: print_ui.accent,
                  minimumSize: const Size(120, 40),
                ),
                child: const Text('打印本单'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => onAction('查看照片 ${protoJobLabel(job)}'),
                child: const Text('查看照片'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _alerts() {
    return ProtoPanel(
      title: '需处理',
      trailing: const StatusTag(
        label: '2',
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
                        '${protoJobLabel(job)} · ${job.phone}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      const StatusTag(
                        label: '需处理',
                        color: WorkstationStyle.warn,
                        soft: WorkstationStyle.warnSoft,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    job.alertReason ?? '',
                    style: const TextStyle(fontSize: 13, height: 1.45),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () => onAction(
                          job.id == 552
                              ? '确认有纸并继续 ${protoJobLabel(job)}'
                              : '继续剩余 ${protoJobLabel(job)}',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: job.id == 552
                              ? print_ui.accent
                              : WorkstationStyle.bad,
                        ),
                        child: Text(job.id == 552 ? '确认有纸并继续' : '继续剩余'),
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

  Widget _queue() {
    final head = protoPendingJobs.take(3).toList();
    final more = protoPendingJobs.skip(3).toList();
    return ProtoPanel(
      title: '自动队列一览',
      trailing: StatusTag(
        label: autoPrint ? '后台运行中' : '已暂停',
        color: autoPrint ? print_ui.accent : WorkstationStyle.muted,
        soft: autoPrint ? const Color(0xffe6f4f1) : const Color(0xffeef2f4),
      ),
      child: Column(
        children: [
          for (final job in head)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: ProtoThumbs(count: 2, size: const Size(36, 46)),
              title: Text(
                protoJobLabel(job),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(job.content),
              trailing: OutlinedButton(
                onPressed: () => onAction('打印 ${protoJobLabel(job)}'),
                child: const Text('打印'),
              ),
            ),
          Theme(
            data: ThemeData(dividerColor: Colors.transparent),
            child: ExpansionTile(
              title: const Text(
                '更多待打印（折叠）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              trailing: Text(
                '还有 ${more.length} 单',
                style: const TextStyle(
                  fontSize: 12,
                  color: WorkstationStyle.muted,
                ),
              ),
              children: [
                for (final job in more)
                  ListTile(
                    dense: true,
                    title: Text(
                      '${protoJobLabel(job)} · ${job.phone}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(job.content),
                    trailing: TextButton(
                      onPressed: () => onAction('打印 ${protoJobLabel(job)}'),
                      child: const Text('打印'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
