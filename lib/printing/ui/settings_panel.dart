import 'package:material_ui/material_ui.dart';

import '../print_bridge.dart';
import 'design.dart';

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.bridge,
    required this.perform,
    this.embedded = false,
    this.showChecks = false,
  });
  final PrintBridge bridge;
  final Perform perform;
  final bool embedded, showChecks;
  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  final token = TextEditingController();
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
      final names = (widget.embedded ? saved : routes).values
          .where((name) => name.isNotEmpty)
          .toSet();
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
        setState(() => printerStatus = e is StateError ? e.message : '$e');
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
    loadPrinters();
  }

  @override
  void dispose() {
    token.dispose();
    super.dispose();
  }

  Future<void> loadPrinters() async {
    setState(() {
      loadingPrinters = true;
      printerError = null;
    });
    try {
      final result = await widget.bridge.call('listPrinters');
      if (mounted) setState(() => printers = List<String>.from(result));
    } catch (e) {
      if (mounted) setState(() => printerError = '$e');
    } finally {
      if (mounted) setState(() => loadingPrinters = false);
    }
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
                    const Text(
                      '景区连接',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.bridge.configured
                          ? '当前景区：${widget.bridge.config['scenicName']}'
                          : '输入景区打印密钥，连接后即可查看打印任务。',
                      style: const TextStyle(color: muted),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: token,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: widget.bridge.configured
                            ? '更换密钥（留空保留）'
                            : '景区打印密钥',
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (!widget.bridge.configured)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton(
                          onPressed: widget.bridge.busy
                              ? null
                              : () async {
                                  await widget.perform('configure', [
                                    {'token': token.text.trim()},
                                  ]);
                                  if (widget.bridge.configured) token.clear();
                                },
                          child: Text(widget.embedded ? '连接景区' : '验证并连接景区'),
                        ),
                      ),
                    if (widget.bridge.configured) ...[
                      const SizedBox(height: 32),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.embedded ? '为照片选择打印机' : '打印机路由',
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
                        '开头片和照片都用 6 寸相纸。',
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
                          child: DropdownButtonFormField<String>(
                            key: ValueKey(
                              '${entry.key}-${routes[entry.key]}-${printers.join()}',
                            ),
                            initialValue: routes[entry.key]?.isNotEmpty == true
                                ? routes[entry.key]
                                : null,
                            isExpanded: true,
                            borderRadius: BorderRadius.circular(14),
                            dropdownColor: Colors.white,
                            menuMaxHeight: 320,
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                            selectedItemBuilder: (_) => [
                              for (final name in _options(entry.key))
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            decoration: InputDecoration(
                              labelText: entry.value,
                              suffixIcon: IconButton(
                                tooltip: '打开系统打印偏好设置',
                                onPressed:
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
                                          if (mounted) {
                                            setState(() => printerError = '$e');
                                          }
                                        }
                                      },
                                icon: const Icon(
                                  Icons.settings_outlined,
                                  size: 18,
                                ),
                              ),
                            ),
                            items: [
                              for (final name in _options(entry.key))
                                DropdownMenuItem(
                                  value: name,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.print_outlined,
                                        size: 18,
                                        color: _pickerColor,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          name,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (name == routes[entry.key])
                                        const Icon(
                                          Icons.check_rounded,
                                          size: 18,
                                          color: _pickerColor,
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                            onChanged: widget.bridge.busy
                                ? null
                                : (value) => setState(
                                    () => routes[entry.key] = value ?? '',
                                  ),
                          ),
                        ),
                      const SizedBox(height: 24),
                      if (!widget.embedded)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: widget.bridge.busy || checkingPrinters
                                ? null
                                : inspectPrinters,
                            icon: const Icon(
                              Icons.monitor_heart_outlined,
                              size: 18,
                            ),
                            label: const Text('读取驱动与队列状态'),
                          ),
                        ),
                      if (!widget.embedded && printerStatus != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: SelectableText(
                            printerStatus!,
                            style: const TextStyle(color: muted),
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton(
                          onPressed: widget.bridge.busy
                              ? null
                              : () async {
                                  await widget.perform('saveConfig', [
                                    {
                                      'token': token.text.trim(),
                                      'printers': routes,
                                    },
                                  ]);
                                  token.clear();
                                },
                          child: Text(widget.embedded ? '保存设置' : '保存并立即生效'),
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

  static const _pickerColor = Color(0xff6741a5);

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
                          ? '请先在「打印设置」连接景区并选择打印机。'
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
