import 'package:material_ui/material_ui.dart';

import '../printing/ui/design.dart' as print_ui;
import '../ui/design.dart';
import 'print_photos_fake_data.dart';
import 'print_photos_proto_widgets.dart';

/// Variant B — queue-first: left rail + large cards.
class PrintPhotosVariantB extends StatelessWidget {
  const PrintPhotosVariantB({
    super.key,
    required this.autoPrint,
    required this.selected,
    required this.filter,
    required this.search,
    required this.onToggleAuto,
    required this.onToggleSelect,
    required this.onFilter,
    required this.onSearch,
    required this.onAction,
  });

  final bool autoPrint;
  final Set<int> selected;
  final String filter;
  final TextEditingController search;
  final ValueChanged<bool> onToggleAuto;
  final ValueChanged<int> onToggleSelect;
  final ValueChanged<String> onFilter;
  final VoidCallback onSearch;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 900;
        if (!wide) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              _rail(compact: true),
              const SizedBox(height: 12),
              ..._mainChildren(),
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 232,
                child: SizedBox.expand(child: _rail(compact: false)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: _mainChildren(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _rail({required bool compact}) {
    return DecoratedBox(
      decoration: WorkstationStyle.surface(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'PRINT DESK',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: WorkstationStyle.muted,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '打印照片',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: WorkstationStyle.ink,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xfff3f8f7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: WorkstationStyle.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const StatusTag(
                        label: '已连接',
                        color: WorkstationStyle.ok,
                        soft: WorkstationStyle.okSoft,
                      ),
                      const Spacer(),
                      Switch(
                        value: autoPrint,
                        activeThumbColor: Colors.white,
                        activeTrackColor: print_ui.accent,
                        onChanged: onToggleAuto,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$protoScenicName\n自动打印${autoPrint ? '开启' : '关闭'} · 每 5 分钟拉未打印',
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: WorkstationStyle.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            for (final entry in const [
              ('pending', '待打印', '6'),
              ('need', '需处理', '2'),
              ('printed', '已打印', '41'),
              ('all', '全部任务', '49'),
            ])
              _navItem(entry.$1, entry.$2, entry.$3),
            if (!compact) ...[
              const Spacer(),
              OutlinedButton(
                onPressed: () => onAction('打印记录'),
                child: const Text('打印记录'),
              ),
              TextButton(
                onPressed: () => onAction('检查更新'),
                child: const Text('检查更新'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _navItem(String key, String label, String count) {
    final active = filter == key;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: active ? const Color(0xffe6f4f1) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onFilter(key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active ? print_ui.accent : WorkstationStyle.ink,
                    ),
                  ),
                ),
                Container(
                  constraints: const BoxConstraints(minWidth: 22),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active
                        ? print_ui.accent.withValues(alpha: .15)
                        : WorkstationStyle.ink.withValues(alpha: .06),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    count,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: active ? print_ui.accent : WorkstationStyle.ink,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _mainChildren() {
    return [
      DecoratedBox(
        decoration: WorkstationStyle.surface(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: ProtoSearchField(
                  controller: search,
                  onSubmit: onSearch,
                  dense: true,
                  actionLabel: '找单打印',
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => onAction('选择日期'),
                child: const Text('日期'),
              ),
              IconButton(
                onPressed: () => onAction('刷新'),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      for (final job in protoPendingJobs) ...[
        _card(job),
        const SizedBox(height: 10),
      ],
      DecoratedBox(
        decoration: WorkstationStyle.surface(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '已选 ${selected.length} 单',
                style: const TextStyle(color: WorkstationStyle.muted),
              ),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => onAction('打印选中'),
                style: FilledButton.styleFrom(backgroundColor: print_ui.accent),
                child: const Text('打印选中'),
              ),
              OutlinedButton(
                onPressed: selected.isEmpty ? null : () => onAction('继续剩余'),
                child: const Text('继续剩余'),
              ),
              OutlinedButton(
                onPressed: selected.isEmpty ? null : () => onAction('确认已打印'),
                child: const Text('确认已打印'),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _card(ProtoJob job) {
    final on = selected.contains(job.id);
    return DecoratedBox(
      decoration: WorkstationStyle.surface(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          children: [
            Checkbox(
              value: on,
              onChanged: (_) => onToggleSelect(job.id),
              activeColor: print_ui.accent,
            ),
            ProtoThumbs(
              count: job.thumbCount,
              more: job.moreCount,
              size: const Size(56, 70),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    protoJobLabel(job),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    job.phone,
                    style: const TextStyle(
                      fontSize: 13,
                      color: WorkstationStyle.muted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    job.content,
                    style: const TextStyle(
                      fontSize: 13,
                      color: print_ui.ink,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '今天 ${job.time}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: WorkstationStyle.muted,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: () => onAction('打印本单 ${protoJobLabel(job)}'),
                  style: FilledButton.styleFrom(
                    backgroundColor: print_ui.accent,
                    minimumSize: const Size(104, 40),
                  ),
                  child: const Text('打印本单'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
