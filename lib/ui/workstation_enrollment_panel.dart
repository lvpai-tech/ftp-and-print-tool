import 'dart:async';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../auto_upload/workstation_enrollment.dart';
import '../profile_store.dart';
import 'design.dart';

class WorkstationEnrollmentPanel extends StatefulWidget {
  const WorkstationEnrollmentPanel({
    super.key,
    required this.api,
    required this.store,
    required this.onBound,
    required this.onManual,
  });

  final Uri api;
  final ProfileStore store;
  final Future<void> Function() onBound;
  final Future<void> Function() onManual;

  @override
  State<WorkstationEnrollmentPanel> createState() =>
      _WorkstationEnrollmentPanelState();
}

class _WorkstationEnrollmentPanelState extends State<WorkstationEnrollmentPanel>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _client = http.Client();
  late final _enrollment = WorkstationEnrollment(
    widget.api,
    widget.store,
    _client,
  );
  final _applications = <String, _Application>{};
  String? _error;
  bool _applying = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final applications = await widget.store.loadEnrollments(widget.api);
      if (!mounted) return;
      setState(() {
        _error = null;
        for (final local in applications) {
          final draft = local['draft'] as Map<String, dynamic>;
          _applications.putIfAbsent(
            draft['requestId'] as String,
            () => _Application(
              draft['scenicName'] as String,
              draft['location'] as String,
            ),
          );
        }
      });
      _refreshAll();
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取本机的申请记录');
    }
  }

  void _refreshAll() {
    if (!_foreground) return;
    for (final entry in _applications.entries) {
      if (entry.value.result?.terminal != true) {
        unawaited(_refresh(entry.key, entry.value));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _refreshAll();
    } else {
      for (final app in _applications.values) {
        app.timer?.cancel();
      }
    }
  }

  Future<void> _refresh(String id, _Application app) async {
    if (app.busy || !mounted) return;
    app.timer?.cancel();
    setState(() => app.busy = true);
    Duration? retry;
    try {
      final status = await _enrollment.refresh(
        id,
        onApproved: (status) {
          if (mounted) setState(() => app.result = status);
        },
      );
      if (!mounted) return;
      app.error = null;
      app.result = status;
      if (status?.status == 'BOUND' || status == null) {
        await widget.onBound();
        if (mounted) _applications.remove(id);
      } else if (!status.terminal) {
        retry = const Duration(seconds: 15);
      }
    } catch (error) {
      if (!mounted) return;
      app.error = error is EnrollmentError ? error.message : '连接或保存机位申请失败，请重试';
      if (error is! EnrollmentError || error.retryable) {
        retry = const Duration(seconds: 45);
      }
    } finally {
      if (mounted) {
        setState(() => app.busy = false);
        if (_foreground && retry != null) {
          app.timer = Timer(retry, () => _refresh(id, app));
        }
      }
    }
  }

  Future<void> _apply() async {
    final draft =
        await showDialog<({String scenic, String location, String? code})>(
          context: context,
          builder: (_) => const _EnrollmentDialog(),
        );
    if (draft == null || !mounted || _applying) return;
    setState(() => _applying = true);
    try {
      final id = await _enrollment.begin(
        draft.scenic,
        draft.location,
        draft.code,
      );
      if (!mounted) return;
      final app = _Application(draft.scenic, draft.location);
      setState(() => _applications[id] = app);
      unawaited(_refresh(id, app));
    } catch (_) {
      if (mounted) setState(() => _error = '无法保存新申请，请检查系统安全存储权限');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _dismiss(String id, _Application app) async {
    setState(() => app.busy = true);
    try {
      await widget.store.saveEnrollment(widget.api, id, null);
      if (mounted) setState(() => _applications.remove(id));
    } catch (_) {
      if (mounted) {
        setState(() {
          app.busy = false;
          app.error = '无法移除本机申请记录';
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final app in _applications.values) {
      app.timer?.cancel();
    }
    _client.close();
    super.dispose();
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
    return Padding(
      key: ValueKey(id),
      padding: const EdgeInsets.only(top: 12),
      child: DecoratedBox(
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
              if (status?.reason case final String reason) Text(reason),
              if (app.error case final String error)
                Text(
                  error,
                  style: const TextStyle(color: WorkstationStyle.bad),
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: id));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制申请编号')),
                        );
                      }
                    },
                    child: const Text('复制申请编号'),
                  ),
                  if (status?.terminal == true && status?.status != 'BOUND')
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
        for (final entry in _applications.entries) _row(entry.key, entry.value),
      ],
    );
  }
}

class _Application {
  _Application(this.scenic, this.location);

  final String scenic, location;
  EnrollmentStatus? result;
  Timer? timer;
  String? error;
  bool busy = false;
}

class _EnrollmentDialog extends StatefulWidget {
  const _EnrollmentDialog();

  @override
  State<_EnrollmentDialog> createState() => _EnrollmentDialogState();
}

class _EnrollmentDialogState extends State<_EnrollmentDialog> {
  final _scenic = TextEditingController();
  final _location = TextEditingController();
  final _station = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _scenic.dispose();
    _location.dispose();
    _station.dispose();
    super.dispose();
  }

  void _submit() {
    final scenic = _scenic.text.trim();
    final location = _location.text.trim();
    final code = _station.text.trim().toUpperCase();
    if (scenic.isEmpty || location.isEmpty) {
      setState(() => _error = '请填写景区和具体点位');
    } else if (code.isNotEmpty && !RegExp(r'^A(?!00)\d{2}$').hasMatch(code)) {
      setState(() => _error = '请输入有效的机位编码，例如 A01');
    } else {
      Navigator.of(context).pop((
        scenic: scenic,
        location: location,
        code: code.isEmpty ? null : code,
      ));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('申请机位'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _scenic,
              maxLength: 100,
              decoration: const InputDecoration(labelText: '景区名称'),
            ),
            TextField(
              controller: _location,
              maxLength: 100,
              decoration: const InputDecoration(labelText: '具体点位'),
            ),
            TextField(
              controller: _station,
              maxLength: 3,
              decoration: const InputDecoration(labelText: '已有机位编码（选填）'),
            ),
            if (_error case final String error) Text(error),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('提交申请')),
    ],
  );
}
