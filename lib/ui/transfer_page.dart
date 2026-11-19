import 'dart:io';
import 'package:material_ui/material_ui.dart';
import '../profile_store.dart';
import 'auto_upload_panel.dart';
import 'manual_batch_panel.dart';
import 'update_button.dart';
import '../transfer.dart';

class TransferPage extends StatefulWidget {
  const TransferPage({super.key});
  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  final _form = GlobalKey<FormState>();
  final _autoPanelKey = GlobalKey();
  bool _autoMode = false, _autoLocked = false;
  final _name = TextEditingController(text: '我的服务器');
  final _host = TextEditingController();
  final _port = TextEditingController(text: '21');
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _directory = TextEditingController(text: '/');
  final _store = const ProfileStore();
  bool _busy = false, _loading = true, _hidePassword = true;
  String _message = '配置服务器后，选择照片开始上传';

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
      }
    } catch (_) {
      _message = '无法读取已保存配置，请重新填写；检查系统安全存储权限';
    } finally {
      if (mounted) setState(() => _loading = false);
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

  // 不把库异常原文显示到界面，避免服务端应答或认证内容泄漏。
  String _error(Object error) => error is StateError
      ? error.message
      : error is SocketException
      ? '网络连接失败，请检查主机、端口和网络'
      : '操作失败，请检查账号、目录权限和服务器 FTP 日志';

  Future<void> _connect({bool save = false}) async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _message = save ? '正在保存配置…' : '正在测试连接与目录权限…';
    });
    PhotoTransfer? transfer;
    try {
      final profile = _profile;
      if (save) {
        await _store.save(profile);
      } else {
        transfer = PhotoTransfer(profile);
        await transfer.open(profile.directory);
      }
      if (mounted) {
        setState(
          () => _message = save ? '配置已保存到系统安全存储' : '连接成功，目标目录可访问（上传权限将在传输时验证）',
        );
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
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      enabled: !_busy && !_loading && !_autoLocked,
      obscureText: secret && _hidePassword,
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

  Widget _server() => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '服务器配置',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('FTP · 被动模式 · 原图传输'),
            const SizedBox(height: 24),
            _field('名称', _name),
            _field('主机', _host),
            _field('端口', _port),
            _field('用户名', _user),
            _field('密码', _password, secret: true),
            _field('远程目录', _directory),
            const Text(
              '当前版本使用明文 FTP，请用于可信网络。配置保存在本机，密码由系统安全存储保护。',
              style: TextStyle(fontSize: 12, color: Color(0xff596579)),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy || _loading || _autoLocked
                      ? null
                      : () => _connect(),
                  icon: const Icon(Icons.link),
                  label: const Text('测试连接'),
                ),
                FilledButton.tonal(
                  onPressed: _busy || _loading || _autoLocked
                      ? null
                      : () => _connect(save: true),
                  child: const Text('保存配置'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _content() => _autoMode
      ? AutoUploadPanel(
          key: _autoPanelKey,
          readProfile: () => _form.currentState!.validate() ? _profile : null,
          saveProfile: _store.save,
          onActiveChanged: (active) {
            if (mounted) setState(() => _autoLocked = active);
          },
        )
      : ManualBatchPanel(
          readProfile: () => _form.currentState!.validate() ? _profile : null,
          saveProfile: _store.save,
          onActiveChanged: (active) {
            if (mounted) setState(() => _autoLocked = active);
          },
        );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('旅派 · 照片传输'),
      backgroundColor: Colors.white,
      actions: const [UpdateButton(), SizedBox(width: 12)],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('手动模式'),
                  icon: Icon(Icons.upload),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('自动模式'),
                  icon: Icon(Icons.folder_open),
                ),
              ],
              selected: {_autoMode},
              onSelectionChanged: _busy || _loading || _autoLocked
                  ? null
                  : (selection) => setState(() => _autoMode = selection.first),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
            child: Row(
              children: [
                if (_busy || _loading)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Expanded(
                  child: Text(_autoMode ? '自动监听模式 · 请选择照片接收目录' : _message),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: constraints.maxWidth >= 960
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 350, child: _server()),
                          const SizedBox(width: 16),
                          Expanded(child: _content()),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _server(),
                          const SizedBox(height: 16),
                          _content(),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
