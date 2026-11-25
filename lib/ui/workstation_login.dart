import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../branding.dart';
import '../workstation_account.dart';
import 'workstation_home.dart';

class WorkstationLogin extends StatefulWidget {
  const WorkstationLogin({
    super.key,
    required this.account,
    required this.onLogin,
    this.notice,
  });

  final WorkstationAccount account;
  final Future<void> Function(WorkstationIdentity) onLogin;
  final String? notice;

  @override
  State<WorkstationLogin> createState() => _WorkstationLoginState();
}

class _WorkstationLoginState extends State<WorkstationLogin> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _phoneFocus = FocusNode();
  final _codeFocus = FocusNode();
  Timer? _clock;
  DateTime? _resendAt;
  var _busy = false;
  var _sending = false;
  String? _phoneError, _codeError, _feedback;

  int get _remaining {
    final until = _resendAt;
    if (until == null) return 0;
    final seconds = (until.difference(DateTime.now()).inMilliseconds / 1000)
        .ceil();
    return seconds > 0 ? seconds : 0;
  }

  bool _validPhone() {
    if (RegExp(r'^1[0-9]{10}$').hasMatch(_phone.text)) return true;
    setState(() => _phoneError = '请输入有效的 11 位手机号');
    _phoneFocus.requestFocus();
    return false;
  }

  Future<void> _send() async {
    if (_busy || _sending || _remaining > 0 || !_validPhone()) return;
    setState(() {
      _sending = true;
      _feedback = _phoneError = _codeError = null;
    });
    try {
      final retry = await widget.account.sendCode(_phone.text);
      if (!mounted) return;
      _resendAt = DateTime.now().add(Duration(seconds: retry));
      _clock?.cancel();
      _clock = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_remaining == 0) timer.cancel();
        if (mounted) setState(() {});
      });
      _feedback = '验证码请求已受理，请查看短信。';
      _codeFocus.requestFocus();
    } on WorkstationAccountError catch (error) {
      if (mounted) _phoneError = error.message;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _login() async {
    if (_busy || _sending || !_validPhone()) return;
    if (!RegExp(r'^[0-9]{6}$').hasMatch(_code.text)) {
      setState(() => _codeError = '请输入 6 位短信验证码');
      _codeFocus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _feedback = _codeError = null;
    });
    try {
      final identity = await widget.account.login(_phone.text, _code.text);
      await widget.onLogin(identity);
    } on WorkstationAccountError catch (error) {
      if (mounted) _codeError = error.message;
    } catch (_) {
      if (mounted) _codeError = '无法保存工作台会话，请检查系统安全存储权限';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    _phone.dispose();
    _code.dispose();
    _phoneFocus.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sending = OutlinedButton(
      onPressed: _busy || _sending || _remaining > 0 ? null : _send,
      style: OutlinedButton.styleFrom(minimumSize: const Size(116, 48)),
      child: Text(
        _sending
            ? '发送中…'
            : _remaining > 0
            ? '$_remaining 秒后重发'
            : '获取验证码',
        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      ),
    );
    final codeField = TextField(
      controller: _code,
      focusNode: _codeFocus,
      readOnly: _busy || _sending,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(6),
      ],
      onSubmitted: (_) => _login(),
      onChanged: (_) {
        if (_codeError != null) setState(() => _codeError = null);
      },
      decoration: InputDecoration(
        labelText: '短信验证码',
        hintText: '6 位验证码',
        errorText: _codeError,
      ),
    );
    return WorkstationLoginFrame(
      children: [
        Text(appBrandName, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '工作台登录',
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 24),
        if (widget.notice case final notice?) ...[
          Text(
            notice,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _phone,
          focusNode: _phoneFocus,
          autofocus: true,
          readOnly: _busy || _sending,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.telephoneNumberNational],
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(11),
          ],
          onSubmitted: (_) => _codeFocus.requestFocus(),
          onChanged: (_) {
            if (_phoneError != null || _feedback != null) {
              setState(() => _phoneError = _feedback = null);
            }
          },
          decoration: InputDecoration(
            labelText: '手机号',
            hintText: '运营账号手机号',
            errorText: _phoneError,
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (_, constraints) => constraints.maxWidth < 280
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [codeField, const SizedBox(height: 8), sending],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: codeField),
                    const SizedBox(width: 12),
                    sending,
                  ],
                ),
        ),
        if (_feedback case final message?) ...[
          const SizedBox(height: 12),
          Semantics(liveRegion: true, child: Text(message)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy || _sending ? null : _login,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: Text(_busy ? '正在登录…' : '登录'),
        ),
      ],
    );
  }
}

class WorkstationLoginFrame extends StatelessWidget {
  const WorkstationLoginFrame({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: workstationBackground,
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, bounds) => SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (bounds.maxHeight - 40)
                  .clamp(0, double.infinity)
                  .toDouble(),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  margin: EdgeInsets.zero,
                  elevation: 6,
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: children,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
