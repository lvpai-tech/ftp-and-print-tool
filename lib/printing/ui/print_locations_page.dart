import 'package:material_ui/material_ui.dart';

import '../../ui/app_dialogs.dart';
import '../../ui/design.dart';
import '../../workstation_session.dart';
import '../print_bridge.dart';
import 'design.dart';
import 'print_enrollment_panel.dart';

bool printLocationSwitchLocked(PrintBridge bridge) =>
    bridge.busy || bridge.state['autoPrint'] == true;

class PrintLocationsPage extends StatelessWidget {
  const PrintLocationsPage({
    super.key,
    required this.bridge,
    required this.settingsButton,
    required this.onOpen,
    required this.perform,
    this.session,
  });

  final PrintBridge bridge;
  final Widget settingsButton;
  final void Function(String id, String? location) onOpen;
  final Perform perform;
  final WorkstationSession? session;

  @override
  Widget build(BuildContext context) {
    final config = bridge.config;
    final activeId = config['activeScenicProfileId'];
    final saved = (config['scenicProfiles'] as List? ?? const [])
        .whereType<Json>()
        .where((profile) => profile['id'] is String);
    final profiles = [
      ...saved.where((profile) => profile['id'] == activeId),
      ...saved.where((profile) => profile['id'] != activeId),
    ];
    final locked = printLocationSwitchLocked(bridge);
    final autoPrint = bridge.state['autoPrint'] == true;
    final lockMessage = bridge.printing
        ? '当前正在打印，完成后可切换打印点。'
        : autoPrint
        ? '请在当前打印点关闭自动打印后再切换。'
        : '正在处理打印操作，请稍候。';

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '打印点',
                            style: TextStyle(
                              color: WorkstationStyle.ink,
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '本机已开通 ${profiles.length} 个打印点',
                            style: const TextStyle(
                              color: WorkstationStyle.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    settingsButton,
                  ],
                ),
                const SizedBox(height: 16),
                if (bridge.error case final error?) ...[
                  SelectableText(
                    appErrorMessage(error),
                    style: const TextStyle(color: WorkstationStyle.bad),
                  ),
                  const SizedBox(height: 12),
                ],
                PrintEnrollmentPanel(
                  bridge: bridge,
                  session: session,
                  buildLocations: (locations) => Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: profiles.isEmpty
                        ? _emptyState()
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (locked)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    lockMessage,
                                    style: const TextStyle(
                                      color: WorkstationStyle.warn,
                                    ),
                                  ),
                                ),
                              for (final profile in profiles)
                                _locationCard(
                                  context,
                                  profile,
                                  location: locations[profile['id']],
                                  current: profile['id'] == activeId,
                                  canRemove: profiles.length > 1 && !locked,
                                  locked: locked,
                                ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyState() => Container(
    decoration: WorkstationStyle.surface(),
    padding: const EdgeInsets.all(28),
    child: const Column(
      children: [
        Icon(Icons.print_outlined, size: 36, color: WorkstationStyle.accent),
        SizedBox(height: 12),
        Text(
          '还没有打印点',
          style: TextStyle(
            color: WorkstationStyle.ink,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 8),
        Text(
          '申请打印权限。运营审批后，在申请记录中刷新以开通。',
          textAlign: TextAlign.center,
          style: TextStyle(color: WorkstationStyle.muted),
        ),
      ],
    ),
  );

  Widget _locationCard(
    BuildContext context,
    Json profile, {
    required String? location,
    required bool current,
    required bool canRemove,
    required bool locked,
  }) {
    final id = profile['id'] as String;
    final name = '${profile['scenicName'] ?? ''}'.trim();
    final code = '${profile['scenicCode'] ?? ''}'.trim();
    final scenic = [
      name.isEmpty ? '景区名称未返回' : name,
      if (code.isNotEmpty) code,
    ].join(' · ');
    final title = location ?? scenic;
    final status = !current
        ? '已开通'
        : bridge.printing
        ? '打印中'
        : bridge.state['autoPrint'] == true
        ? '自动打印已开启'
        : '当前使用';
    return Padding(
      key: ValueKey('print-location-$id'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: WorkstationStyle.card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WorkstationStyle.radius),
          side: BorderSide(
            color: current ? WorkstationStyle.accent : WorkstationStyle.line,
          ),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: current
                  ? WorkstationStyle.accentSoft
                  : WorkstationStyle.bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.print_outlined,
              color: current ? WorkstationStyle.accent : WorkstationStyle.muted,
            ),
          ),
          title: Text(
            title,
            style: const TextStyle(
              color: WorkstationStyle.ink,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (location != null)
                Text(
                  scenic,
                  style: const TextStyle(color: WorkstationStyle.muted),
                ),
              const SizedBox(height: 4),
              StatusTag(
                label: status,
                color: current ? WorkstationStyle.ok : WorkstationStyle.muted,
                soft: current ? WorkstationStyle.okSoft : WorkstationStyle.bg,
              ),
            ],
          ),
          onTap: current || !locked ? () => onOpen(id, location) : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!current)
                PopupMenuButton<String>(
                  tooltip: '打印点操作',
                  enabled: canRemove,
                  onSelected: (_) => _remove(context, id, title),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'remove', child: Text('从本机移除')),
                  ],
                ),
              Icon(
                current || !locked ? Icons.chevron_right : Icons.lock_outline,
                size: 20,
                color: WorkstationStyle.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, String id, String title) async {
    final agreed = await showAppConfirm(
      context,
      title: '从本机移除打印点？',
      message: '将从本机列表移除「$title」。景区的工单和打印记录会保留。',
      action: '移除',
    );
    if (!agreed || !context.mounted) return;
    await perform('deleteScenicProfile', [
      {'id': id},
    ]);
  }
}
