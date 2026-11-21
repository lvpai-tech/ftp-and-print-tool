import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../auto_upload/cos_upload.dart';
import '../branding.dart';
import '../profile_store.dart';
import '../transfer.dart';
import 'auto_upload_panel.dart';
import 'cos_upload_dialog.dart';
import 'app_dialogs.dart';
import 'design.dart';
import 'manual_batch_panel.dart';
import 'update_button.dart';

class TransferPage extends StatefulWidget {
  const TransferPage({
    super.key,
    this.embedded = false,
    this.onActiveChanged,
    this.onUploadingChanged,
    this.onConfiguredChanged,
  });

  /// 嵌在工作台壳内时隐藏自带顶栏，由壳提供返回与切换。
  final bool embedded;
  final ValueChanged<bool>? onActiveChanged;
  final ValueChanged<bool>? onUploadingChanged;
  final ValueChanged<bool>? onConfiguredChanged;

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _form = GlobalKey<FormState>();
  final _autoPanelKey = GlobalKey();
  bool _autoMode = true, _autoLocked = false;
  final _name = TextEditingController(text: '我的服务器');
  final _host = TextEditingController();
  final _port = TextEditingController(text: '21');
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _directory = TextEditingController(text: '/');
  final _store = const ProfileStore();
  bool _busy = false, _loading = true, _hidePassword = true;
  bool _hasSavedProfile = false;
  CosUploadProfile? _cosProfile;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await _store.load();
      if (!mounted) return;
      if (profile != null) {
        _name.text = profile.name;
        _host.text = profile.host;
        _port.text = '${profile.port}';
        _user.text = profile.user;
        _password.text = profile.password;
        _directory.text = profile.directory;
        _hasSavedProfile = _fieldsComplete();
      }
      final cosProfile = await _store.loadCos();
      if (!mounted) return;
      _cosProfile = cosProfile;
    } catch (_) {
      _message = '无法读取已保存配置，请重新填写；检查系统安全存储权限';
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        widget.onConfiguredChanged?.call(_configured);
      }
    }
  }

  ServerProfile get _profile => ServerProfile(
    name: _name.text.trim(),
    host: _host.text.trim(),
    port: int.parse(_port.text.trim()),
    user: _user.text.trim(),
    password: _password.text,
    directory: _directory.text.trim(),
  );

  bool _fieldsComplete() {
    final port = int.tryParse(_port.text.trim());
    return _host.text.trim().isNotEmpty &&
        _user.text.trim().isNotEmpty &&
        _password.text.isNotEmpty &&
        _directory.text.trim().isNotEmpty &&
        port != null &&
        port >= 1 &&
        port <= 65535;
  }

  bool get _configured => _hasSavedProfile && _fieldsComplete();

  // 不把库异常原文显示到界面，避免服务端应答或认证内容泄漏。
  String _error(Object error) => error is StateError
      ? error.message
      : error is SocketException
      ? '网络连接失败，请检查主机、端口和网络'
      : '操作失败，请检查账号、目录权限和服务器 FTP 日志';

  String? _validateField(TextEditingController controller, String label) {
    final value = controller.text;
    if (value.trim().isEmpty) return '请填写$label';
    if (value.contains('\r') || value.contains('\n')) return '不能包含换行符';
    if (controller == _port) {
      final port = int.tryParse(value.trim());
      if (port == null || port < 1 || port > 65535) return '端口应为 1—65535';
    }
    if (controller == _host && (value.contains('://') || value.contains('/'))) {
      return '只填写域名或 IP，不含协议和路径';
    }
    return null;
  }

  ServerProfile? _readProfile() {
    for (final entry in [
      (_host, '主机'),
      (_port, '端口'),
      (_directory, '远程目录'),
      (_user, '用户名'),
      (_password, '密码'),
    ]) {
      if (_validateField(entry.$1, entry.$2) != null) return null;
    }
    return _profile;
  }

  void _openConfig() => _scaffoldKey.currentState?.openEndDrawer();

  void _reportActivity({bool? active, bool? uploading}) {
    if (active != null) widget.onActiveChanged?.call(active);
    if (uploading != null) widget.onUploadingChanged?.call(uploading);
  }

  Future<void> _showNeedConfigDialog() async {
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => Dialog(
        backgroundColor: WorkstationStyle.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: WorkstationStyle.accentSoft,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.dns_outlined,
                        color: WorkstationStyle.accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '还不能开始上传',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: WorkstationStyle.ink,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text(
                  '首次使用请先配置机位 FTP（主机、账号、目录）。配置保存后，主界面继续专注收图与上传。',
                  style: TextStyle(color: WorkstationStyle.muted, height: 1.5),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 44),
                          foregroundColor: WorkstationStyle.ink,
                          side: const BorderSide(color: WorkstationStyle.line),
                        ),
                        child: const Text('稍后'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 44),
                          backgroundColor: WorkstationStyle.accent,
                        ),
                        child: const Text('去配置机位'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (go == true && mounted) _openConfig();
  }

  Future<void> _connect({bool save = false}) async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _message = save ? '正在保存配置…' : '正在测试连接与目录权限…';
    });
    PhotoTransfer? transfer;
    try {
      final profile = _profile;
      if (save) {
        await _store.save(profile);
        _hasSavedProfile = true;
      } else {
        transfer = PhotoTransfer(profile);
        await transfer.open(profile.directory);
      }
      if (mounted) {
        setState(
          () => _message = save ? '配置已保存到系统安全存储' : '连接成功，目标目录可访问（上传权限将在传输时验证）',
        );
      }
      if (save && mounted) {
        widget.onConfiguredChanged?.call(_configured);
        Navigator.of(context).maybePop();
      }
    } catch (error) {
      if (mounted) setState(() => _message = _error(error));
    } finally {
      try {
        await transfer?.close();
      } catch (_) {
        if (mounted) setState(() => _message = '连接关闭异常，请检查网络后重试');
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final field in [_name, _host, _port, _user, _password, _directory]) {
      field.dispose();
    }
    super.dispose();
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool secret = false,
    TextInputType? type,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      enabled: !_busy && !_loading && !_autoLocked,
      obscureText: secret && _hidePassword,
      keyboardType: type,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: secret
            ? IconButton(
                tooltip: _hidePassword ? '显示密码' : '隐藏密码',
                onPressed: () => setState(() => _hidePassword = !_hidePassword),
                icon: Icon(
                  _hidePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                ),
              )
            : null,
      ),
      validator: (value) {
        if (value == null || value.trim().isEmpty) return '请填写$label';
        if (value.contains('\r') || value.contains('\n')) return '不能包含换行符';
        if (controller == _port) {
          final port = int.tryParse(value.trim());
          if (port == null || port < 1 || port > 65535) return '端口应为 1—65535';
        }
        if (controller == _host &&
            (value.contains('://') || value.contains('/'))) {
          return '只填写域名或 IP，不含协议和路径';
        }
        return null;
      },
    ),
  );

  Widget _configDrawer() {
    final width = math.min(420.0, MediaQuery.sizeOf(context).width * 0.92);
    return Drawer(
      width: width,
      backgroundColor: WorkstationStyle.card,
      child: SafeArea(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '机位连接',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: WorkstationStyle.ink,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _configured ? '已有配置，可按需修改。' : '首次使用请完整填写后保存。',
                            style: const TextStyle(
                              color: WorkstationStyle.muted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: WorkstationStyle.line),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  children: [
                    const Row(
                      children: [
                        StatusTag(
                          label: 'FTP · 被动',
                          color: WorkstationStyle.accent,
                          soft: WorkstationStyle.accentSoft,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _field('名称', _name),
                    _field('主机', _host),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _field(
                            '端口',
                            _port,
                            type: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: _field('远程目录', _directory)),
                      ],
                    ),
                    _field('用户名', _user),
                    _field('密码', _password, secret: true),
                    const Text(
                      '当前版本使用明文 FTP，请用于可信网络。配置保存在本机，密码由系统安全存储保护。',
                      style: TextStyle(
                        fontSize: 12,
                        color: WorkstationStyle.muted,
                        height: 1.4,
                      ),
                    ),
                    if (_message.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _message,
                        style: const TextStyle(
                          color: WorkstationStyle.muted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy || _loading || _autoLocked
                            ? null
                            : () => _connect(),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 46),
                          foregroundColor: WorkstationStyle.ink,
                          side: const BorderSide(color: WorkstationStyle.line),
                        ),
                        child: const Text('测试连接'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy || _loading || _autoLocked
                            ? null
                            : () => _connect(save: true),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 46),
                          backgroundColor: WorkstationStyle.accent,
                        ),
                        child: const Text('保存配置'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stationSummary() => Material(
    color: _configured
        ? WorkstationStyle.accentSoft
        : WorkstationStyle.warnSoft,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      onTap: _openConfig,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: WorkstationStyle.card,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: WorkstationStyle.line),
              ),
              child: Icon(
                _configured ? Icons.cloud_done_outlined : Icons.dns_outlined,
                color: _configured
                    ? WorkstationStyle.accent
                    : WorkstationStyle.warn,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _configured ? '当前机位' : '机位尚未配置',
                    style: const TextStyle(
                      color: WorkstationStyle.muted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _configured
                        ? '${_name.text.trim()}  ·  ${_host.text.trim()}'
                        : '点击配置 FTP 主机、账号与目录',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _configured
                          ? WorkstationStyle.ink
                          : WorkstationStyle.warn,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            StatusTag(
              label: _configured ? '已保存' : '必填',
              color: _configured ? WorkstationStyle.ok : WorkstationStyle.warn,
              soft: _configured
                  ? WorkstationStyle.okSoft
                  : const Color(0xfffff7ed),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: WorkstationStyle.muted),
          ],
        ),
      ),
    ),
  );

  Widget _modeChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback? onTap,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(9),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: selected ? WorkstationStyle.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: selected ? Colors.white : WorkstationStyle.muted,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : WorkstationStyle.muted,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _modeToggle() => Align(
    alignment: Alignment.centerLeft,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: WorkstationStyle.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: WorkstationStyle.line),
          boxShadow: WorkstationStyle.softShadow,
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _modeChip(
                label: '自动上传模式',
                icon: Icons.folder_open_outlined,
                selected: _autoMode,
                onTap: _busy || _loading || _autoLocked
                    ? null
                    : () => setState(() => _autoMode = true),
              ),
              _modeChip(
                label: '手动上传模式',
                icon: Icons.upload_outlined,
                selected: !_autoMode,
                onTap: _busy || _loading || _autoLocked
                    ? null
                    : () => setState(() => _autoMode = false),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _unconfiguredEmpty() => DecoratedBox(
    decoration: WorkstationStyle.surface(),
    child: LayoutBuilder(
      builder: (context, bounds) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: bounds.maxHeight - 44,
            maxWidth: 480,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xff2563eb), Color(0xff1e3a8a)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.dns_outlined,
                  color: Colors.white,
                  size: 34,
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                '请先配置机位连接',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: WorkstationStyle.ink,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '上传前需要主机、账号和远程目录。配置一次后会保存在本机，之后打开即可直接使用。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: WorkstationStyle.muted,
                  height: 1.55,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _openConfig,
                icon: const Icon(Icons.settings_ethernet),
                label: const Text('去配置机位'),
                style: FilledButton.styleFrom(
                  backgroundColor: WorkstationStyle.accent,
                  minimumSize: const Size(220, 48),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _openConfig,
                child: const Text('也可点击顶部「机位连接」'),
              ),
              if (_autoMode)
                TextButton(
                  onPressed: _loading ? null : _configureCos,
                  child: const Text('配置 COS 自动直传'),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _configureCos() async {
    if (_autoLocked || _busy || _loading) return;
    final result = await showDialog<({CosUploadProfile? profile})>(
      context: context,
      builder: (context) => CosUploadDialog(initial: _cosProfile),
    );
    if (result == null || !mounted) return;
    try {
      await _store.saveCos(result.profile);
      if (mounted) setState(() => _cosProfile = result.profile);
    } catch (_) {
      if (!mounted) return;
      await showAppMessage(context, message: '无法保存配置，请检查系统安全存储权限');
    }
  }

  Widget _content() {
    if (!_configured && (!_autoMode || _cosProfile == null)) {
      return _unconfiguredEmpty();
    }
    return _autoMode
        ? AutoUploadPanel(
            key: _autoPanelKey,
            cosProfile: _cosProfile,
            onConfigureCos: _configureCos,
            readProfile: () {
              final profile = _readProfile();
              if (profile == null) {
                unawaited(_showNeedConfigDialog());
              }
              return profile;
            },
            saveProfile: _store.save,
            onActiveChanged: (active) {
              if (mounted) setState(() => _autoLocked = active);
              _reportActivity(active: active || _busy);
            },
            onUploadingChanged: widget.onUploadingChanged,
          )
        : ManualBatchPanel(
            readProfile: () {
              final profile = _readProfile();
              if (profile == null) {
                unawaited(_showNeedConfigDialog());
              }
              return profile;
            },
            saveProfile: _store.save,
            onActiveChanged: (active) {
              if (mounted) setState(() => _autoLocked = active);
              _reportActivity(active: active || _busy);
            },
            onUploadingChanged: widget.onUploadingChanged,
          );
  }

  Widget _brandBar() {
    final narrow = MediaQuery.sizeOf(context).width < 560;
    final configLabel = _configured ? '机位连接' : (narrow ? '未配置' : '机位连接 · 未配置');
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: WorkstationStyle.card,
        border: Border(bottom: BorderSide(color: WorkstationStyle.line)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xff2563eb), Color(0xff1e3a8a)],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.photo_camera_back_outlined,
              color: Colors.white,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$appBrandName · 照片传输',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: WorkstationStyle.ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '现场上传工作台',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: WorkstationStyle.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: _openConfig,
            icon: Badge(
              isLabelVisible: !_configured,
              smallSize: 8,
              child: const Icon(Icons.dns_outlined, size: 18),
            ),
            label: Text(configLabel),
            style: FilledButton.styleFrom(
              foregroundColor: _configured
                  ? WorkstationStyle.ink
                  : WorkstationStyle.accent,
              backgroundColor: _configured
                  ? const Color(0xfff8fafc)
                  : WorkstationStyle.accentSoft,
              minimumSize: const Size(0, 40),
              visualDensity: VisualDensity.compact,
            ),
          ),
          if (!widget.embedded) ...[
            const SizedBox(width: 8),
            const UpdateButton(),
          ],
        ],
      ),
    );
  }

  Widget _workspace() {
    final pad = MediaQuery.sizeOf(context).width >= 960 ? 28.0 : 16.0;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        child: Padding(
          padding: EdgeInsets.fromLTRB(pad, 20, pad, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.embedded)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _openConfig,
                    icon: Badge(
                      isLabelVisible: !_configured,
                      smallSize: 8,
                      child: const Icon(Icons.dns_outlined, size: 18),
                    ),
                    label: Text(_configured ? '机位连接' : '机位连接 · 未配置'),
                  ),
                ),
              if (widget.embedded) const SizedBox(height: 8),
              _stationSummary(),
              const SizedBox(height: 16),
              _modeToggle(),
              if (_busy || _loading) ...[
                const SizedBox(height: 12),
                const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '处理中…',
                        style: TextStyle(color: WorkstationStyle.muted),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              Expanded(child: _content()),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: _scaffoldKey,
    backgroundColor: Colors.transparent,
    endDrawer: _configDrawer(),
    body: Column(
      children: [
        if (!widget.embedded) _brandBar(),
        Expanded(child: SafeArea(top: false, child: _workspace())),
      ],
    ),
  );
}
