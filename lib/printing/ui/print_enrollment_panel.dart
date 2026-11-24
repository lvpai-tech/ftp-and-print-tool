import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../auto_upload/workstation_enrollment.dart';
import '../../ui/app_dialogs.dart';
import '../../ui/dropdown_field.dart';
import '../../ui/workstation_form_dialog.dart';
import '../print_bridge.dart';
import '../print_enrollment.dart';
import '../../workstation_session.dart';

class PrintEnrollmentPanel extends StatefulWidget {
  const PrintEnrollmentPanel({super.key, required this.bridge, this.session});
  final WorkstationSession? session;
  final PrintBridge bridge;

  @override
  State<PrintEnrollmentPanel> createState() => _PrintEnrollmentPanelState();
}

class _PrintEnrollmentPanelState extends State<PrintEnrollmentPanel> {
  final _client = http.Client();
  late final _enrollment = PrintEnrollment(_client, session: widget.session);
  List<Map<String, dynamic>> _records = [];
  bool _busy = false;
  bool _showRecords = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await PrintEnrollment.records();
      final scenicId = widget.session?.scenic?.id;
      if (mounted) {
        setState(
          () => _records = scenicId == null
              ? rows
              : rows.where((row) => row['scenicId'] == scenicId).toList(),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取本机打印申请记录');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is EnrollmentError
              ? error.message
              : appErrorMessage(error),
        );
      }
    } finally {
      await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh(Map<String, dynamic> row) async {
    await _enrollment.refresh(row, (id, token, scenicId) async {
      await widget.bridge.call('installPrintAuthorization', [
        {'id': id, 'token': token, 'scenicId': scenicId},
      ]);
    });
  }

  Future<void> _apply() => _run(() async {
    final scenics = await _enrollment.loadScenics();
    if (!mounted) return;
    if (scenics.isEmpty) throw StateError('暂无可申请的景区');
    final draft =
        await showDialog<({EnrollmentScenic scenic, String location})>(
          context: context,
          builder: (_) => _PrintApplicationDialog(scenics: scenics),
        );
    if (draft == null || !mounted) return;
    setState(() => _showRecords = true);
    await _refresh(await _enrollment.begin(draft.scenic, draft.location));
  });

  static const _labels = {
    'UNSUBMITTED': '待提交',
    'PENDING': '待审核',
    'APPROVED': '待激活',
    'ACTIVATED': '已开通',
    'REJECTED': '已驳回',
    'CANCELLED': '已取消',
    'EXPIRED': '已过期',
  };

  @override
  Widget build(BuildContext context) {
    final disabled = _busy || widget.bridge.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: disabled ? null : _apply,
              icon: const Icon(Icons.add),
              label: const Text('申请打印权限'),
            ),
            OutlinedButton(
              onPressed: () => setState(() => _showRecords = !_showRecords),
              child: Text('申请记录（${_records.length}）'),
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_showRecords)
          if (_records.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('暂无打印申请记录'),
            )
          else
            for (final row in _records)
              Card(
                child: ListTile(
                  title: Text(
                    '${row['scenicName'] ?? row['scenicId']} · ${row['location']}',
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_labels[row['status']] ?? '状态未知'),
                      SelectableText('申请编号 ${row['id']}'),
                      if (row['reviewReason'] is String)
                        Text(row['reviewReason'] as String),
                    ],
                  ),
                  trailing: IconButton(
                    tooltip: '刷新申请状态',
                    onPressed: disabled
                        ? null
                        : () => _run(() => _refresh(row)),
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              ),
      ],
    );
  }
}

class _PrintApplicationDialog extends StatefulWidget {
  const _PrintApplicationDialog({required this.scenics});
  final List<EnrollmentScenic> scenics;

  @override
  State<_PrintApplicationDialog> createState() =>
      _PrintApplicationDialogState();
}

class _PrintApplicationDialogState extends State<_PrintApplicationDialog> {
  final _form = GlobalKey<FormState>();
  final _scenicField = GlobalKey<FormFieldState<EnrollmentScenic>>();
  final _location = TextEditingController();

  @override
  void dispose() {
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkstationFormDialog(
    title: '申请打印权限',
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          FormField<EnrollmentScenic>(
            key: _scenicField,
            validator: (value) => value == null ? '请选择景区' : null,
            builder: (field) => DropdownField<EnrollmentScenic>(
              label: '景区',
              placeholder: '选择景区',
              options: widget.scenics,
              labelFor: (scenic) => scenic.name,
              value: field.value,
              errorText: field.errorText,
              onChanged: field.didChange,
            ),
          ),
          TextFormField(
            controller: _location,
            maxLength: 100,
            decoration: const InputDecoration(labelText: '打印点位或工作台名称'),
            validator: (value) =>
                (value ?? '').trim().isEmpty ? '请填写点位或工作台名称' : null,
          ),
        ],
      ),
    ),
    actions: [
      OutlinedButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, (
              scenic: _scenicField.currentState!.value!,
              location: _location.text.trim(),
            ));
          }
        },
        child: const Text('提交申请'),
      ),
    ],
  );
}
