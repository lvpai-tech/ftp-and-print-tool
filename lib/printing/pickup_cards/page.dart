import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

import '../../ui/dropdown_field.dart';
import '../../ui/workstation_form_dialog.dart';
import '../../workstation_session.dart';
import 'api.dart';

class PickupCardsPage extends StatefulWidget {
  const PickupCardsPage({
    super.key,
    required this.session,
    required this.visible,
  });

  final WorkstationSession session;
  final bool visible;

  @override
  State<PickupCardsPage> createState() => _PickupCardsPageState();
}

class _PickupCardsPageState extends State<PickupCardsPage> {
  late final _scenic = widget.session.scenic!;
  late final _api = PickupCardsApi(
    widget.session.account!,
    widget.session.identity!.id,
    _scenic.id,
  );
  final _quantity = TextEditingController(text: '2');
  List<PickupExport> _exports = [];
  PickupExportRequest? _pending;
  Timer? _poll;
  String? _error, _listError, _message, _printer;
  bool _restored = false;
  bool _codesOnly = false;
  bool _busy = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (widget.visible && _exports.any((batch) => batch.active)) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _quantity.dispose();
    super.dispose();
  }

  String _describe(Object error) => switch (error) {
    StateError(:final message) => message,
    TypeError() || FormatException() => '取片卡数据格式无效，请刷新或联系管理员',
    _ => '$error',
  };

  Future<void> _restore() async {
    try {
      final pending = await _api.restorePending();
      if (!mounted) return;
      setState(() {
        _pending = pending;
        _restored = true;
        if (pending != null) {
          _quantity.text = '${pending.quantity}';
          _codesOnly = pending.codesOnly;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = _describe(error));
    }
  }

  Future<void> _refresh() async {
    if (_refreshing || _busy) return;
    setState(() => _refreshing = true);
    try {
      final exports = await _api.recent();
      if (mounted) {
        setState(() {
          _exports = exports;
          _listError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _listError = _describe(error));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _describe(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showBatch(PickupExport batch) {
    if (!mounted) return;
    setState(() {
      _exports = [
        batch,
        ..._exports.where((existing) => existing.route != batch.route),
      ];
    });
  }

  Future<void> _submit(PickupFormat format) async {
    final count = int.tryParse(_quantity.text.trim());
    if (count == null || count < 1 || count > 5000) {
      setState(() => _error = '请输入 1–5,000 张');
      return;
    }
    await _perform(() async {
      final request =
          _pending ?? PickupExportRequest(count, _codesOnly, format);
      await _api.remember(request);
      if (!mounted) return;
      setState(() => _pending = request);
      final batch = await _api.submit(request);
      await _api.remember(null);
      if (!mounted) return;
      setState(() => _pending = null);
      _showBatch(batch);
    });
  }

  Future<void> _discardPending() => _perform(() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => WorkstationFormDialog(
        title: '放弃本机的待确认提交？',
        content: const Text('后台可能已经收到该请求。请先在最近导出中核对，避免再次制卡。'),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('放弃此次提交'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _api.remember(null);
    if (mounted) setState(() => _pending = null);
  });

  Future<void> _openFiles(PickupExport batch) => _perform(() async {
    final files = await _api.files(batch);
    if (!mounted) return;
    final action = await showDialog<({PickupFile file, bool print})>(
      context: context,
      builder: (dialog) => WorkstationFormDialog(
        title: '${batch.format.code} · ${batch.batchNo}',
        width: 640,
        actions: const [],
        content: Column(
          spacing: 10,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final file in files)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    file.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.pop(dialog, (file: file, print: false)),
                        icon: const Icon(Icons.download_outlined),
                        label: Text(file.part == 0 ? '下载全部（ZIP）' : '下载'),
                      ),
                      if (_supportsPrinting &&
                          file.part > 0 &&
                          batch.format == PickupFormat.pdf)
                        FilledButton.icon(
                          onPressed: () =>
                              Navigator.pop(dialog, (file: file, print: true)),
                          icon: const Icon(Icons.print_outlined),
                          label: const Text('选择打印机'),
                        ),
                    ],
                  ),
                  const Divider(),
                ],
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action.print) {
      await _print(batch, action.file);
    } else {
      await _save(batch, action.file);
    }
  });

  static bool get _supportsPrinting => Platform.isWindows || Platform.isMacOS;

  Future<void> _save(PickupExport batch, PickupFile file) async {
    final extension = file.part == 0 ? 'zip' : batch.format.extension;
    final location = await getSaveLocation(
      suggestedName: file.name,
      acceptedTypeGroups: [
        XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
      ],
    );
    if (location == null || !mounted) return;
    final target = File(location.path);
    final temporary = await target.parent.createTemp('.pickup-cards-');
    try {
      final download = File(path.join(temporary.path, file.name));
      await _api.download(batch, file, download);
      await download.rename(target.path);
    } finally {
      await temporary.delete(recursive: true);
    }
    if (mounted) setState(() => _message = '已保存到 ${target.path}');
  }

  Future<void> _print(PickupExport batch, PickupFile file) async {
    final session = widget.session;
    final bridge = session.printBridge;
    if (!bridge.connected) await session.startPrinting();
    if (!mounted) return;
    if (!bridge.connected) throw StateError(bridge.error ?? '请先启动打印服务');
    final printers = (await bridge.call('listPrinters') as List)
        .cast<String>()
        .toSet()
        .toList();
    if (!mounted) return;
    if (printers.isEmpty) throw StateError('请先在系统设置中添加取片卡打印机');
    String? choice = printers.contains(_printer) ? _printer : null;
    final printer = await showDialog<String>(
      context: context,
      builder: (dialog) {
        return StatefulBuilder(
          builder: (context, setChoice) => WorkstationFormDialog(
            title: '确认打印取片卡',
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                Text('${file.name}\n请装入 54 × 90 mm 卡纸。每页一张，按原尺寸打印。'),
                DropdownField<String>(
                  label: '取片卡打印机',
                  placeholder: '请选择系统打印队列',
                  options: printers,
                  value: choice,
                  labelFor: (name) => name,
                  searchHint: '搜索打印机名称',
                  onChanged: (name) => setChoice(() => choice = name),
                ),
              ],
            ),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: choice == null
                    ? null
                    : () => Navigator.pop(dialog, choice),
                child: const Text('送打此卷'),
              ),
            ],
          ),
        );
      },
    );
    if (printer == null || !mounted) return;
    _printer = printer;
    final temporary = await Directory.systemTemp.createTemp('lvpai-pickup-');
    try {
      final pdf = File(path.join(temporary.path, file.name));
      await _api.download(batch, file, pdf);
      if (!mounted ||
          !widget.visible ||
          session.personnelToken == null ||
          session.updating) {
        return;
      }
      final result = await bridge.run('printPickupCardPdf', [
        printer,
        pdf.path,
      ]);
      if (result is! Map || result['submitted'] != true) {
        throw StateError('未收到送打确认，请核对系统队列和已出卡片后再决定是否补打');
      }
      final jobId = result['jobId'];
      final message =
          '已提交到「$printer」${jobId == null ? '' : ' · $jobId'}，请核对出纸。';
      if (mounted) {
        setState(() => _message = message);
      } else {
        session.report(message);
      }
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = _pending;
    final generating = _restored && !_busy && !_refreshing;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Card.outlined(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 12,
                      children: [
                        Text(
                          '${_scenic.name} · 卡片设置',
                          style: theme.textTheme.titleLarge,
                        ),
                        const Text('PDF 每页一张，尺寸 54 × 90 mm。完整卡面沿用运营后台背景设置。'),
                        SizedBox(
                          width: 200,
                          child: TextField(
                            controller: _quantity,
                            enabled: !_busy && _restored && pending == null,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: const InputDecoration(
                              labelText: '生成数量',
                              helperText: '1–5,000 张',
                              suffixText: '张',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _codesOnly,
                          onChanged: !_restored || _busy || pending != null
                              ? null
                              : (checked) =>
                                    setState(() => _codesOnly = checked!),
                          title: const Text('仅打印识别码'),
                          subtitle: const Text('预印卡纸用，保留太阳码、条形码和编号。'),
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (!_restored)
                              OutlinedButton(
                                onPressed: _restore,
                                child: const Text('读取生成设置'),
                              )
                            else if (pending != null) ...[
                              FilledButton(
                                onPressed: generating
                                    ? () => _submit(pending.format)
                                    : null,
                                child: Text('核对并重试生成 ${pending.format.code}'),
                              ),
                              TextButton(
                                onPressed: _busy ? null : _discardPending,
                                child: const Text('放弃此次提交'),
                              ),
                            ] else ...[
                              FilledButton(
                                onPressed: generating
                                    ? () => _submit(PickupFormat.pdf)
                                    : null,
                                child: const Text('生成 PDF'),
                              ),
                              OutlinedButton(
                                onPressed: generating
                                    ? () => _submit(PickupFormat.excel)
                                    : null,
                                child: const Text('生成 Excel'),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (_busy || _refreshing) const LinearProgressIndicator(),
                if (_error case final error?)
                  Text(error, style: TextStyle(color: theme.colorScheme.error)),
                if (_message case final message?) SelectableText(message),
                Row(
                  children: [
                    Expanded(
                      child: Text('最近导出', style: theme.textTheme.titleMedium),
                    ),
                    TextButton.icon(
                      onPressed: _busy || _refreshing
                          ? null
                          : () {
                              setState(() => _error = null);
                              unawaited(_refresh());
                            },
                      icon: const Icon(Icons.refresh),
                      label: const Text('刷新'),
                    ),
                  ],
                ),
                if (_listError case final listError?)
                  Text(
                    listError,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                if (_exports.isEmpty && !_refreshing && _listError == null)
                  const Text('当前景区暂无取片卡导出。'),
                for (final batch in _exports)
                  Card.outlined(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        spacing: 6,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${batch.batchNo} · ${batch.format.code} · ${batch.quantity} 张',
                          ),
                          Text(
                            batch.statusLabel,
                            style: theme.textTheme.bodySmall,
                          ),
                          if (batch.error case final error?
                              when batch.status == 'FAILED')
                            Text(
                              error,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          if (batch.ready)
                            OutlinedButton(
                              onPressed: _busy ? null : () => _openFiles(batch),
                              child: Text(
                                batch.format == PickupFormat.pdf &&
                                        _supportsPrinting
                                    ? '下载或打印'
                                    : '下载文件',
                              ),
                            ),
                          if (batch.retryable)
                            OutlinedButton(
                              onPressed: _busy || _refreshing
                                  ? null
                                  : () => _perform(
                                      () async =>
                                          _showBatch(await _api.retry(batch)),
                                    ),
                              child: const Text('重新导出此批'),
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
}
