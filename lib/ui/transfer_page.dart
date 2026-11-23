import 'package:material_ui/material_ui.dart';

import '../auto_upload/cos_upload.dart';
import '../branding.dart';
import '../printing/print_bridge.dart';
import '../printing/ui/photo_batch_page.dart';
import '../profile_store.dart';
import 'app_dialogs.dart';
import 'auto_upload_panel.dart';
import 'cos_upload_dialog.dart';
import 'update_button.dart';

class TransferPage extends StatefulWidget {
  const TransferPage({
    super.key,
    this.embedded = false,
    this.onActiveChanged,
    this.onUploadingChanged,
    this.onConfiguredChanged,
    this.printBridge,
  });

  /// 嵌在工作台壳内时由壳提供导航。
  final bool embedded;
  final ValueChanged<bool>? onActiveChanged;
  final ValueChanged<bool>? onUploadingChanged;
  final ValueChanged<bool>? onConfiguredChanged;
  final PrintBridge? printBridge;

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  final _store = const ProfileStore();
  CosUploadProfile? _profile;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await _store.loadCos();
      if (!mounted) return;
      _profile = profile;
    } catch (_) {
      _loadError = '无法读取机位配置，请重新填写';
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        widget.onConfiguredChanged?.call(_profile != null);
      }
    }
  }

  Future<void> _configure() async {
    if (_saving) return;
    final profile = await showDialog<CosUploadProfile>(
      context: context,
      builder: (context) => CosUploadDialog(initial: _profile),
    );
    if (profile == null || !mounted) return;
    setState(() => _saving = true);
    try {
      await _store.saveCos(profile);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loadError = null;
      });
      widget.onConfiguredChanged?.call(true);
    } catch (_) {
      if (mounted) {
        await showAppMessage(context, message: '无法保存配置，请检查系统安全存储权限');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final profile = _profile;
    if (profile == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError ?? '请先配置机位连接'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : _configure,
              icon: const Icon(Icons.settings_ethernet),
              label: const Text('去配置机位'),
            ),
          ],
        ),
      );
    }
    return AutoUploadPanel(
      cosProfile: profile,
      onConfigureCos: _configure,
      onActiveChanged: (active) => widget.onActiveChanged?.call(active),
      onUploadingChanged: widget.onUploadingChanged,
      onOpenBatches: widget.printBridge == null
          ? null
          : () => _openPhotoBatches(profile.stationId),
    );
  }

  Future<void> _openPhotoBatches(String stationId) async {
    final bridge = widget.printBridge!;
    if (!bridge.connected || !bridge.configured) {
      await showAppMessage(context, message: '请先在打印工作台连接景区，再设置取片批次。');
      return;
    }
    final scenicName = (bridge.config['scenicName'] as String?)?.trim();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PhotoBatchPage(
          call: bridge.call,
          scenicName: scenicName?.isNotEmpty == true ? scenicName! : '（未返回名称）',
          initialStationId: stationId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: widget.embedded
        ? null
        : AppBar(
            title: const Text('$appBrandName · 照片传输'),
            actions: const [UpdateButton()],
          ),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            child: _body(),
          ),
        ),
      ),
    ),
  );
}
