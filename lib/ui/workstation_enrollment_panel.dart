import 'dart:async';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../auto_upload/workstation_enrollment.dart';
import '../profile_store.dart';

class WorkstationEnrollmentPanel extends StatefulWidget {
  const WorkstationEnrollmentPanel({
    super.key,
    required this.api,
    required this.onBound,
    required this.onManual,
  });

  final Uri api;
  final Future<void> Function() onBound;
  final Future<void> Function() onManual;

  @override
  State<WorkstationEnrollmentPanel> createState() =>
      _WorkstationEnrollmentPanelState();
}

class _WorkstationEnrollmentPanelState extends State<WorkstationEnrollmentPanel>
    with WidgetsBindingObserver {
  final _client = http.Client();
  late final _enrollment = WorkstationEnrollment(
    widget.api,
    const ProfileStore(),
    _client,
  );
  EnrollmentStatus? _status;
  Timer? _timer;
  String? _error;
  bool _busy = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_refresh());
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _client.close();
    super.dispose();
  }

  Future<void> _refresh() => _run(_enrollment.refresh);

  Future<void> _run(Future<EnrollmentStatus?> Function() action) async {
    if (_busy || !mounted) return;
    _timer?.cancel();
    setState(() => _busy = true);
    try {
      final status = await action();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
      });
      if (status?.status == 'BOUND') {
        await widget.onBound();
      } else if (_foreground && status != null && !status.terminal) {
        _timer = Timer(const Duration(seconds: 15), _refresh);
      }
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is EnrollmentError
            ? error.message
            : '连接或保存机位申请失败，请重试',
      );
      if (_foreground && (error is! EnrollmentError || error.retryable)) {
        _timer = Timer(const Duration(seconds: 45), _refresh);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final draft =
        await showDialog<({String scenic, String location, String? code})>(
          context: context,
          builder: (_) => const _EnrollmentDialog(),
        );
    if (draft == null || !mounted) return;
    await _run(
      () => _enrollment.begin(draft.scenic, draft.location, draft.code),
    );
  }

  Future<void> _manual() async {
    if (_busy) return;
    _timer?.cancel();
    setState(() => _busy = true);
    try {
      await widget.onManual();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_foreground && _status?.terminal == false) {
          _timer = Timer(const Duration(seconds: 15), _refresh);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final error = _error;
    final label = switch (status?.status) {
      'PENDING' => '待审核',
      'APPROVED' => '审核通过，等待绑定',
      'BOUND' => '已绑定',
      'REJECTED' => '已驳回',
      'CANCELLED' => '已取消',
      'EXPIRED' => '已过期',
      _ => null,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) Text(label),
        if (status != null)
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: status.id));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('已复制申请编号')));
              }
            },
            child: Text('复制申请编号 ${status.id}', textAlign: TextAlign.center),
          ),
        if (status?.reason case final String reason)
          Text(reason, textAlign: TextAlign.center),
        if (error != null) Text(error, textAlign: TextAlign.center),
        if (status?.terminal == true)
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _enrollment.clearLocal();
                    return null;
                  }),
            child: const Text('重新申请'),
          )
        else if (status != null || error != null)
          TextButton(
            onPressed: _busy ? null : _refresh,
            child: const Text('刷新申请状态'),
          )
        else
          FilledButton(
            onPressed: _busy ? null : _apply,
            child: const Text('申请机位'),
          ),
        TextButton(
          onPressed: _busy ? null : _manual,
          child: const Text('去配置机位'),
        ),
      ],
    );
  }
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
