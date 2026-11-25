import 'dart:async';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../auto_upload/workstation_enrollment.dart';
import '../profile_store.dart';
import '../workstation_session.dart';
import 'design.dart';
import 'dropdown_field.dart';
import 'workstation_form_dialog.dart';

class WorkstationEnrollmentPanel extends StatefulWidget {
  const WorkstationEnrollmentPanel({
    super.key,
    required this.api,
    required this.store,
    required this.onBound,
    required this.onManual,
    this.session,
  });

  final Uri api;
  final WorkstationSession? session;
  final ProfileStore store;
  final Future<void> Function() onBound;
  final Future<void> Function() onManual;

  @override
  WorkstationEnrollmentPanelState createState() =>
      WorkstationEnrollmentPanelState();
}

class WorkstationEnrollmentPanelState extends State<WorkstationEnrollmentPanel>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _client = http.Client();
  late final _enrollment = WorkstationEnrollment(
    widget.api,
    widget.store,
    _client,
    session: widget.session,
  );
  final _applications = <String, _Application>{};
  final _history = ValueNotifier<List<MapEntry<String, _Application>>>(
    const [],
  );
  late final Future<void> _initialLoad;
  String? _error;
  bool _applying = false;
  bool _historyOpen = false;

  void _updateApplications(VoidCallback update) => setState(() {
    update();
    _history.value = _applications.entries.toList()
      ..sort((a, b) => b.value.sortTime.compareTo(a.value.sortTime));
  });

  @override
  void initState() {
    super.initState();
    _initialLoad = _load();
  }

  Future<void> _load() async {
    try {
      final applications = await widget.store.loadEnrollments(widget.api);
      if (!mounted) return;
      _updateApplications(() {
        _error = null;
        for (final local in applications) {
          final draft = local['draft'] as Map<String, dynamic>;
          final scenic = widget.session?.scenic;
          if (scenic != null &&
              (draft['scenicId'] != null
                  ? draft['scenicId'] != scenic.id
                  : draft['scenicName'] != scenic.name)) {
            continue;
          }
          final id = draft['requestId'] as String;
          _applications.putIfAbsent(
            id,
            () =>
                _Application(
                    draft['scenicName'] as String,
                    draft['location'] as String,
                    createdAt: DateTime.tryParse(
                      local['createdAt'] as String? ?? '',
                    ),
                  )
                  ..result =
                      _enrollment.savedResult(local, id) ??
                      (local['submitted'] == true
                          ? EnrollmentStatus(
                              id,
                              local['pending'] == null ? 'PENDING' : 'APPROVED',
                            )
                          : null),
          );
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取本机的申请记录');
    }
  }

  Future<bool> refreshApplications() async {
    await _initialLoad;
    if (!mounted) return false;
    if (_error != null) await _load();
    if (!mounted) return false;
    final pending = _applications.entries
        .where((entry) => entry.value.result?.terminal != true)
        .toList();
    await Future.wait(pending.map((entry) => _refresh(entry.key, entry.value)));
    return _error == null &&
        pending.every((entry) => entry.value.error == null);
  }

  Future<void> _refresh(String id, _Application app) =>
      app.refreshing ??= _refreshApplication(id, app);

  Future<void> _refreshApplication(String id, _Application app) async {
    _updateApplications(() => app.busy = true);
    try {
      final status = await _enrollment.refresh(
        id,
        onApproved: (status) {
          if (mounted) _updateApplications(() => app.result = status);
        },
      );
      if (!mounted) return;
      app.error = null;
      if (status == null) {
        _applications.remove(id);
      } else if (status.status == 'BOUND') {
        await widget.onBound();
      }
      app.result = status;
    } catch (error) {
      if (!mounted) return;
      app.error = error is EnrollmentError ? error.message : '连接或保存机位申请失败，请重试';
    } finally {
      app.refreshing = null;
      if (mounted) _updateApplications(() => app.busy = false);
    }
  }

  Future<void> _apply() async {
    final draft =
        await showDialog<({EnrollmentScenic scenic, String location})>(
          context: context,
          builder: (_) =>
              _EnrollmentDialog(loadScenics: _enrollment.loadScenics),
        );
    if (draft == null || !mounted || _applying) return;
    setState(() => _applying = true);
    try {
      final id = await _enrollment.begin(
        draft.scenic.name,
        draft.location,
        scenicId: draft.scenic.id,
      );
      if (!mounted) return;
      final app = _Application(
        draft.scenic.name,
        draft.location,
        createdAt: DateTime.now(),
      );
      _updateApplications(() => _applications[id] = app);
      unawaited(_refresh(id, app));
      unawaited(_openHistory());
    } catch (_) {
      if (mounted) setState(() => _error = '无法保存新申请，请检查系统安全存储权限');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _dismiss(String id, _Application app) async {
    _updateApplications(() => app.busy = true);
    try {
      await widget.store.saveEnrollment(widget.api, id, null);
      if (mounted) _updateApplications(() => _applications.remove(id));
    } catch (_) {
      if (mounted) {
        _updateApplications(() {
          app.busy = false;
          app.error = '无法移除本机申请记录';
        });
      }
    }
  }

  @override
  void dispose() {
    _client.close();
    _history.dispose();
    super.dispose();
  }

  Future<void> _openHistory() async {
    if (_historyOpen) return;
    _historyOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => ValueListenableBuilder(
          valueListenable: _history,
          builder: (context, applications, _) => WorkstationFormDialog(
            title: '机位申请记录',
            width: 580,
            content: applications.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(child: Text('暂无机位申请记录')),
                  )
                : Column(
                    spacing: 12,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in applications)
                        _row(entry.key, entry.value),
                    ],
                  ),
            actions: [
              if (applications.isNotEmpty)
                OutlinedButton.icon(
                  onPressed:
                      applications.any(
                        (entry) =>
                            !entry.value.busy &&
                            entry.value.result?.terminal != true,
                      )
                      ? refreshApplications
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新全部申请'),
                ),
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

  Widget _row(String id, _Application app) {
    final status = app.result;
    final label = switch (status?.status) {
      'PENDING' => '待审核',
      'APPROVED' => '审核通过，等待绑定',
      'BOUND' => '已绑定',
      'REJECTED' => '已驳回',
      'CANCELLED' => '已取消',
      'EXPIRED' => '已过期',
      _ => app.busy ? '正在提交' : '待提交',
    };
    return DecoratedBox(
      key: ValueKey(id),
      decoration: WorkstationStyle.surface(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [app.scenic, app.location].join(' · '),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(label),
            if (status?.binding?['stationCode'] case final String code)
              Text('机位编码 $code'),
            if (status?.reason case final String reason) Text(reason),
            if (app.error case final String error)
              Text(error, style: const TextStyle(color: WorkstationStyle.bad)),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: id));
                    if (mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('已复制申请编号')));
                    }
                  },
                  child: const Text('复制申请编号'),
                ),
                if (status?.terminal == true)
                  TextButton(
                    onPressed: app.busy ? null : () => _dismiss(id, app),
                    child: const Text('移除记录'),
                  )
                else
                  TextButton(
                    onPressed: app.busy ? null : () => _refresh(id, app),
                    child: const Text('刷新申请状态'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _applying ? null : _apply,
              icon: const Icon(Icons.add),
              label: Text(_applying ? '正在提交…' : '申请机位'),
            ),
            TextButton(onPressed: widget.onManual, child: const Text('手动绑定机位')),
            TextButton.icon(
              onPressed: _openHistory,
              icon: const Icon(Icons.history),
              label: Text('申请记录（${_applications.length}）'),
            ),
          ],
        ),
        if (_error case final String error)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(error),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
      ],
    );
  }
}

class _Application {
  _Application(this.scenic, this.location, {this.createdAt});

  final String scenic, location;
  final DateTime? createdAt;
  int get sortTime => createdAt?.millisecondsSinceEpoch ?? 0;
  EnrollmentStatus? result;
  String? error;
  bool busy = false;
  Future<void>? refreshing;
}

class _EnrollmentDialog extends StatefulWidget {
  const _EnrollmentDialog({required this.loadScenics});

  final Future<List<EnrollmentScenic>> Function() loadScenics;

  @override
  State<_EnrollmentDialog> createState() => _EnrollmentDialogState();
}

class _EnrollmentDialogState extends State<_EnrollmentDialog> {
  final _location = TextEditingController();
  late Future<List<EnrollmentScenic>> _scenics;
  EnrollmentScenic? _scenic;
  bool _missingLocation = false;

  @override
  void initState() {
    super.initState();
    _scenics = widget.loadScenics();
  }

  @override
  void dispose() {
    _location.dispose();
    super.dispose();
  }

  void _submit() {
    final scenic = _scenic;
    if (scenic == null) return;
    final location = _location.text.trim();
    if (location.isEmpty) {
      setState(() => _missingLocation = true);
    } else {
      Navigator.of(context).pop((scenic: scenic, location: location));
    }
  }

  Widget _scenicField() => FutureBuilder<List<EnrollmentScenic>>(
    future: _scenics,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Text('正在加载景区…');
      }
      final scenics = snapshot.data;
      if (scenics == null || scenics.isEmpty) {
        return Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(scenics == null ? '景区列表加载失败' : '暂无可申请的景区'),
            TextButton(
              onPressed: () {
                final retry = widget.loadScenics();
                setState(() {
                  _scenics = retry;
                });
              },
              child: const Text('重试'),
            ),
          ],
        );
      }
      return DropdownField<EnrollmentScenic>(
        label: '景区',
        placeholder: '请选择景区',
        options: scenics,
        labelFor: (scenic) => scenic.name,
        value: _scenic,
        onChanged: (scenic) => setState(() => _scenic = scenic),
      );
    },
  );

  @override
  Widget build(BuildContext context) => WorkstationFormDialog(
    title: '申请机位',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _scenicField(),
        const SizedBox(height: 12),
        TextField(
          controller: _location,
          maxLength: 100,
          decoration: InputDecoration(
            labelText: '具体点位',
            errorText: _missingLocation ? '请填写具体点位' : null,
          ),
          onChanged: (value) {
            if (_missingLocation && value.trim().isNotEmpty) {
              setState(() => _missingLocation = false);
            }
          },
        ),
      ],
    ),
    actions: [
      OutlinedButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _scenic == null ? null : _submit,
        child: const Text('提交申请'),
      ),
    ],
  );
}
