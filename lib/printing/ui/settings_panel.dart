import 'package:material_ui/material_ui.dart';

import '../../ui/app_dialogs.dart';
import '../../ui/dropdown_field.dart';
import '../../workstation_session.dart';
import '../print_bridge.dart';
import 'design.dart';
import 'print_enrollment_panel.dart';

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.bridge,
    required this.perform,
    this.embedded = false,
    this.showChecks = false,
    this.session,
  });
  final PrintBridge bridge;
  final Perform perform;
  final bool embedded, showChecks;
  final WorkstationSession? session;
  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  final printForm = GlobalKey<FormState>();
  late final TextEditingController dpi;
  List<String> printers = [];
  late Map<String, String> routes;
  String? printerError;
  bool loadingPrinters = false;
  bool checkingPrinters = false;
  String? printerStatus;

  Future<void> inspectPrinters() async {
    setState(() {
      checkingPrinters = true;
      printerStatus = null;
    });
    try {
      final saved = Map<String, String>.from(
        widget.bridge.config['printers'] ?? {},
      );
      final source = routes.values.any((name) => name.isNotEmpty)
          ? routes
          : saved;
      final names = source.values.where((name) => name.isNotEmpty).toSet();
      if (names.isEmpty) throw StateError('请先选择打印机');
      final lines = <String>[];
      for (final name in names) {
        final result = await widget.bridge.call('printerStatus', [name]);
        final status = result['printerStatus'];
        final jobs = result['jobs'];
        if (status is! String || status.trim().isEmpty || jobs is! List) {
          throw StateError('无法读取「$name」的状态，请检查连接。');
        }
        lines.add('$name：${_printerState(status)}（${jobs.length} 项任务）');
      }
      if (mounted) setState(() => printerStatus = lines.join('\n'));
    } catch (e) {
      if (mounted) {
        setState(() => printerStatus = null);
        await showAppMessage(
          context,
          title: '操作未完成',
          message: appErrorMessage(e),
        );
      }
    } finally {
      if (mounted) setState(() => checkingPrinters = false);
    }
  }

  String _printerState(String status) => status
      .split(',')
      .map((part) {
        final flag = part.trim();
        return const {
              'Normal': '正常',
              'Idle': '空闲',
              'Offline': '离线',
              'PaperOut': '缺纸',
              'PaperJam': '卡纸',
              'Error': '故障',
              'Printing': '打印中',
              'Busy': '忙碌',
              'Paused': '已暂停',
              'Unknown': '状态未知',
            }[flag] ??
            flag;
      })
      .join('、');

  @override
  void initState() {
    super.initState();
    routes = Map<String, String>.from(widget.bridge.config['printers'] ?? {});
    dpi = TextEditingController(
      text: '${widget.bridge.config['printDpi'] ?? 300}',
    );
    loadPrinters();
  }

  @override
  void dispose() {
    dpi.dispose();
    super.dispose();
  }

  Future<void> savePrintSettings() async {
    if (!printForm.currentState!.validate()) return;
    final saved = await widget.perform('saveConfig', [
      {'printers': routes, 'printDpi': int.parse(dpi.text.trim(), radix: 10)},
    ]);
    if (saved && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('打印设置已保存')));
    }
  }

  List<Map<String, dynamic>> get scenicProfiles {
    final raw = widget.bridge.config['scenicProfiles'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  String get activeScenicId =>
      '${widget.bridge.config['activeScenicProfileId'] ?? ''}';

  Future<void> loadPrinters() async {
    setState(() {
      loadingPrinters = true;
      printerError = null;
    });
    try {
      final result = await widget.bridge.call('listPrinters');
      if (mounted) setState(() => printers = List<String>.from(result));
    } catch (e) {
      if (mounted) {
        setState(() => printerError = null);
        await showAppMessage(
          context,
          title: '操作未完成',
          message: appErrorMessage(e),
        );
      }
    } finally {
      if (mounted) setState(() => loadingPrinters = false);
    }
  }

  Widget _profileList() {
    final profiles = scenicProfiles;
    final activeId = activeScenicId;
    if (profiles.isEmpty) {
      return const Text('尚未开通景区', style: TextStyle(color: muted));
    }
    return Column(
      children: [
        for (final profile in profiles)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              title: Text(
                '${profile['scenicName'] ?? ''}'.trim().isEmpty
                    ? '未命名景区'
                    : '${profile['scenicName']}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                profile['id'] == activeId ? '当前激活' : '点击可激活',
                style: TextStyle(
                  color: profile['id'] == activeId
                      ? const Color(0xff389e0d)
                      : muted,
                ),
              ),
              leading: Icon(
                profile['id'] == activeId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: profile['id'] == activeId
                    ? const Color(0xff1677ff)
                    : muted,
              ),
              trailing: Wrap(
                spacing: 0,
                children: [
                  IconButton(
                    tooltip: profile['id'] == activeId ? '请先切换到其他景区再删除' : '删除',
                    onPressed:
                        widget.bridge.busy ||
                            profiles.length <= 1 ||
                            profile['id'] == activeId
                        ? null
                        : () async {
                            final yes = await showAppConfirm(
                              context,
                              title: '删除景区档案',
                              message:
                                  '确定删除「${profile['scenicName'] ?? profile['id']}」？',
                              action: '删除',
                            );
                            if (yes) {
                              await widget.perform('deleteScenicProfile', [
                                {'id': profile['id']},
                              ]);
                            }
                          },
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                ],
              ),
              onTap: widget.bridge.busy || profile['id'] == activeId
                  ? null
                  : () => widget.perform('activateScenicProfile', [
                      {'id': profile['id']},
                    ]),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => widget.showChecks
      ? _checks()
      : ListView(
          padding: EdgeInsets.all(widget.embedded ? 16 : 32),
          children: [
            Align(
              alignment: widget.embedded
                  ? Alignment.topCenter
                  : Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!widget.embedded) ...[
                      const Text(
                        '景区档案',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.bridge.configured
                            ? '可申请多个景区，打印机路由共用。打印中或自动打印开启时不能切换。'
                            : '通过审批并激活后，可选择本机打印机。',
                        style: const TextStyle(color: muted),
                      ),
                      const SizedBox(height: 16),
                      if (widget.bridge.configured) _profileList(),
                      PrintEnrollmentPanel(
                        bridge: widget.bridge,
                        session: widget.session,
                      ),
                    ],
                    if (widget.bridge.configured) ...[
                      if (!widget.embedded) const SizedBox(height: 28),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '打印机路由',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: loadingPrinters ? null : loadPrinters,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: Text(loadingPrinters ? '读取中…' : '刷新打印机'),
                          ),
                        ],
                      ),
                      const Text(
                        '开头片和照片都用 6 寸相纸；所有景区共用这套打印机。',
                        style: TextStyle(color: muted),
                      ),
                      if (printerError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            printerError!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      if (!loadingPrinters &&
                          printers.isEmpty &&
                          printerError == null)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text('系统没有已安装打印机，请先安装驱动。'),
                        ),
                      for (final entry in const {
                        'COVER': '开头片',
                        'SIZE_6': '6 寸照片',
                        'ORIGINAL': '原片',
                        'CREATIVE': '创意成片',
                      }.entries)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: _PrinterDropdown(
                            key: ValueKey(entry.key),
                            label: entry.value,
                            value: routes[entry.key]?.isNotEmpty == true
                                ? routes[entry.key]
                                : null,
                            options: _options(entry.key).toList(),
                            enabled: !widget.bridge.busy,
                            onChanged: (value) =>
                                setState(() => routes[entry.key] = value),
                            onOpenPreferences:
                                widget.bridge.busy ||
                                    routes[entry.key]?.isNotEmpty != true
                                ? null
                                : () async {
                                    try {
                                      await widget.bridge.call(
                                        'printerPreferences',
                                        [routes[entry.key]],
                                      );
                                    } catch (e) {
                                      if (!context.mounted) return;
                                      await showAppMessage(
                                        context,
                                        title: '操作未完成',
                                        message: appErrorMessage(e),
                                      );
                                    }
                                  },
                          ),
                        ),
                      const SizedBox(height: 24),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('print-inspect-printers'),
                          onPressed: widget.bridge.busy || checkingPrinters
                              ? null
                              : inspectPrinters,
                          icon: const Icon(
                            Icons.monitor_heart_outlined,
                            size: 18,
                          ),
                          label: Text(checkingPrinters ? '正在检查…' : '读取打印机状态'),
                        ),
                      ),
                      if (printerStatus != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16, top: 8),
                          child: SelectableText(
                            printerStatus!,
                            style: const TextStyle(color: muted),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Form(
                        key: printForm,
                        child: TextFormField(
                          key: const ValueKey('print-dpi-field'),
                          controller: dpi,
                          enabled: !widget.bridge.busy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '打印分辨率',
                            suffixText: 'DPI',
                          ),
                          validator: (value) {
                            final number = int.tryParse(
                              value?.trim() ?? '',
                              radix: 10,
                            );
                            if (number == null ||
                                number < 72 ||
                                number > 1200) {
                              return '请输入 72–1200 之间的整数';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '默认 300 DPI，所有景区共用。设备输出分辨率由打印机驱动决定。',
                        style: TextStyle(color: muted),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton(
                          onPressed: widget.bridge.busy
                              ? null
                              : savePrintSettings,
                          child: const Text('保存打印设置'),
                        ),
                      ),
                      const SizedBox(height: 24),
                      SelectableText(
                        '配置目录：${widget.bridge.config['configPath'] ?? ''}',
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );

  Set<String> _options(String kind) => {
    ...printers,
    if (routes[kind]?.isNotEmpty == true) routes[kind]!,
  };

  Widget _checks() {
    final bridge = widget.bridge;
    final supported = bridge.config['statusCommand'] != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '看看打印机是否就绪',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      !bridge.configured
                          ? '请先开通景区打印权限并选择打印机。'
                          : !supported
                          ? '这台电脑暂时无法读取打印机状态，请在系统设置里检查。'
                          : '读取已保存的打印机状态。检查时不会出纸。',
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed:
                            bridge.configured &&
                                supported &&
                                !bridge.busy &&
                                !checkingPrinters
                            ? inspectPrinters
                            : null,
                        icon: const Icon(Icons.monitor_heart_outlined),
                        label: Text(checkingPrinters ? '正在检查…' : '读取打印机状态'),
                      ),
                    ),
                    if (printerStatus case final status?) ...[
                      const SizedBox(height: 12),
                      SelectableText(status),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PrinterDropdown extends StatelessWidget {
  const _PrinterDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.enabled,
    required this.onChanged,
    this.onOpenPreferences,
  });

  final String label;
  final String? value;
  final List<String> options;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback? onOpenPreferences;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(
        child: DropdownField<String>(
          label: label,
          placeholder: '选择打印机',
          searchHint: '搜索打印机',
          options: options,
          labelFor: (name) => name,
          value: value,
          onChanged: enabled ? onChanged : null,
        ),
      ),
      const SizedBox(width: 4),
      IconButton(
        tooltip: '打开系统打印偏好设置',
        onPressed: onOpenPreferences,
        icon: const Icon(Icons.settings_outlined, size: 18),
      ),
    ],
  );
}
