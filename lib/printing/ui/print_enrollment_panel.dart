import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../auto_upload/workstation_enrollment.dart';
import '../../ui/app_dialogs.dart';
import '../../ui/design.dart';
import '../../ui/dropdown_field.dart';
import '../../ui/workstation_form_dialog.dart';
import '../print_bridge.dart';
import '../print_enrollment.dart';
import '../../workstation_session.dart';

class PrintEnrollmentPanel extends StatefulWidget {
  const PrintEnrollmentPanel({
    super.key,
    required this.bridge,
    this.buildLocations,
    this.session,
  });
  final WorkstationSession? session;
  final PrintBridge bridge;
  final Widget Function(Map<String, String> locations)? buildLocations;

  @override
  State<PrintEnrollmentPanel> createState() => _PrintEnrollmentPanelState();
}

class _PrintEnrollmentPanelState extends State<PrintEnrollmentPanel> {
  final _client = http.Client();
  late final _enrollment = PrintEnrollment(_client, session: widget.session);
  final _history = ValueNotifier<List<Json>>([]);
  final _activity = ValueNotifier<({bool busy, String? error})>((
    busy: false,
    error: null,
  ));
  bool _historyOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _client.close();
    _history.dispose();
    _activity.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await PrintEnrollment.records();
      final scenicId = widget.session?.scenic?.id;
      if (mounted) {
        _history.value = scenicId == null
            ? rows
            : rows.where((row) => row['scenicId'] == scenicId).toList();
      }
    } catch (_) {
      if (mounted) {
        _activity.value = (busy: _activity.value.busy, error: '无法读取本机打印申请记录');
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_activity.value.busy || widget.bridge.busy) return;
    _activity.value = (busy: true, error: null);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        _activity.value = (
          busy: true,
          error: error is EnrollmentError
              ? error.message
              : appErrorMessage(error),
        );
      }
    } finally {
      await _load();
      if (mounted) {
        _activity.value = (busy: false, error: _activity.value.error);
      }
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
    final row = await _enrollment.begin(draft.scenic, draft.location);
    if (!mounted) return;
    _history.value = [row, ..._history.value];
    unawaited(_openHistory());
    await _refresh(row);
  });

  Future<void> _openHistory() async {
    if (_historyOpen) return;
    _historyOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => ListenableBuilder(
          listenable: Listenable.merge([_history, _activity, widget.bridge]),
          builder: (context, _) => WorkstationFormDialog(
            title: '打印申请记录',
            width: 580,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                if (_activity.value.busy) const LinearProgressIndicator(),
                if (_activity.value.error case final error?)
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_history.value.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(child: Text('暂无打印申请记录')),
                  ),
                for (final row in _history.value) _recordCard(row),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
    } finally {
      _historyOpen = false;
    }
  }

  Widget _recordCard(Json row) => DecoratedBox(
    key: ValueKey(row['id']),
    decoration: WorkstationStyle.surface(),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${row['scenicName'] ?? row['scenicId']} · ${row['location']}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(_labels[row['status']] ?? '状态未知'),
          SelectableText('申请编号 ${row['id']}'),
          if (row['reviewReason'] case final String reason) Text(reason),
          TextButton(
            onPressed: _activity.value.busy || widget.bridge.busy
                ? null
                : () => _run(() => _refresh(row)),
            child: const Text('刷新申请状态'),
          ),
        ],
      ),
    ),
  );

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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_history, _activity]),
    builder: (context, _) => _buildPanel(context),
  );

  Widget _buildPanel(BuildContext context) {
    final records = _history.value;
    final (:busy, :error) = _activity.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: busy || widget.bridge.busy ? null : _apply,
              icon: const Icon(Icons.add),
              label: const Text('申请打印权限'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : _openHistory,
              icon: const Icon(Icons.history),
              label: Text('申请记录（${records.length}）'),
            ),
          ],
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (widget.buildLocations case final buildLocations?)
          buildLocations({
            for (final row in records)
              if (row
                  case {
                    'id': final String id,
                    'location': final String location,
                  }
                  when location.trim().isNotEmpty)
                id: location.trim(),
          }),
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
