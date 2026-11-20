import 'package:flutter/services.dart';
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
  bool obscureToken = true;
  bool loadingToken = false;

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
    loadStoredToken();
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

  Future<String> revealStoredToken() async {
    final result = await widget.bridge.call('revealToken');
    if (result is! Map) {
      throw StateError('无法读取已保存的密钥');
    }
    return '${result['token'] ?? ''}'.trim();
  }

  Future<void> loadStoredToken() async {
    if (!widget.bridge.configured) return;
    setState(() => loadingToken = true);
    try {
      final value = await revealStoredToken();
      if (mounted && value.isNotEmpty) token.text = value;
    } catch (e) {
      if (mounted) {
        setState(
          () => printerError = e is StateError ? e.message : '读取密钥失败：$e',
        );
      }
    } finally {
      if (mounted) setState(() => loadingToken = false);
    }
  }

  Future<void> copyToken() async {
    var text = token.text.trim();
    if (text.isEmpty && widget.bridge.configured) {
      try {
        text = await revealStoredToken();
        if (text.isNotEmpty) token.text = text;
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(e is StateError ? e.message : '复制失败：$e')),
        );
        return;
      }
    }
    if (text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('没有可复制的密钥')));
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('密钥已复制')));
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
                      () {
                        if (!widget.bridge.configured) {
                          return '先粘贴密钥，点「连接景区」校验通过后再选打印机。';
                        }
                        final name =
                            '${widget.bridge.config['scenicName'] ?? ''}'
                                .trim();
                        return name.isEmpty
                            ? '当前景区：（未返回名称）'
                            : '当前景区：$name';
                      }(),
                      style: const TextStyle(color: muted),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: token,
                      obscureText: obscureToken,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: loadingToken ? '正在读取密钥…' : '景区打印密钥',
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: obscureToken ? '显示密钥' : '隐藏密钥',
                              onPressed: () => setState(
                                () => obscureToken = !obscureToken,
                              ),
                              icon: Icon(
                                obscureToken
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                            IconButton(
                              tooltip: '复制密钥',
                              onPressed: copyToken,
                              icon: const Icon(Icons.copy_outlined),
                            ),
                          ],
                        ),
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
                                  if (widget.bridge.configured) {
                                    await loadStoredToken();
                                  }
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
                          child: _PrinterDropdown(
                            // 不要把当前选中值放进 Key，否则一点选就重建，表现为要点两次。
                            key: ValueKey('${entry.key}-${printers.join('|')}'),
                            label: entry.value,
                            value: routes[entry.key]?.isNotEmpty == true
                                ? routes[entry.key]
                                : null,
                            options: _options(entry.key).toList(),
                            enabled: !widget.bridge.busy,
                            onChanged: (value) => setState(
                              () => routes[entry.key] = value ?? '',
                            ),
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
                                      if (mounted) {
                                        setState(() => printerError = '$e');
                                      }
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
                          label: Text(
                            checkingPrinters ? '正在检查…' : '读取打印机状态',
                          ),
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
                                  await loadStoredToken();
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

/// 菜单在输入框下方展开，不盖住触发框描边。
class _PrinterDropdown extends StatefulWidget {
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
  final ValueChanged<String?> onChanged;
  final VoidCallback? onOpenPreferences;

  @override
  State<_PrinterDropdown> createState() => _PrinterDropdownState();
}

class _PrinterDropdownState extends State<_PrinterDropdown> {
  static const _pickerColor = Color(0xff6741a5);
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value ?? '');
  }

  @override
  void didUpdateWidget(covariant _PrinterDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.value ?? '';
    if (_controller.text != next) _controller.text = next;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, bounds) {
        final menuWidth = (bounds.maxWidth - 48).clamp(160.0, bounds.maxWidth);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownMenu<String>(
                enabled: widget.enabled,
                // 桌面端默认先抢焦点再开菜单；打开后一次点击即可选中。
                requestFocusOnTap: true,
                controller: _controller,
                width: menuWidth > 0 ? menuWidth : null,
                initialSelection: widget.value,
                label: Text(widget.label),
                hintText: '选择打印机',
                expandedInsets: EdgeInsets.zero,
                menuHeight: 320,
                trailingIcon: const Icon(Icons.keyboard_arrow_down_rounded),
                selectedTrailingIcon: const Icon(
                  Icons.keyboard_arrow_up_rounded,
                ),
                inputDecorationTheme: Theme.of(context).inputDecorationTheme,
                dropdownMenuEntries: [
                  for (final name in widget.options)
                    DropdownMenuEntry<String>(
                      value: name,
                      label: name,
                      leadingIcon: const Icon(
                        Icons.print_outlined,
                        size: 18,
                        color: _pickerColor,
                      ),
                      trailingIcon: name == widget.value
                          ? const Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: _pickerColor,
                            )
                          : null,
                    ),
                ],
                onSelected: widget.enabled ? widget.onChanged : null,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '打开系统打印偏好设置',
              onPressed: widget.onOpenPreferences,
              icon: const Icon(Icons.settings_outlined, size: 18),
            ),
          ],
        );
      },
    );
  }
}
