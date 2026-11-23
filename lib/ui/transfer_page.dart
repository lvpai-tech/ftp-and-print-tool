import 'package:material_ui/material_ui.dart';

import '../auto_upload/cos_upload.dart';
import '../branding.dart';
import '../printing/print_bridge.dart';
import '../printing/ui/photo_batch_page.dart';
import '../profile_store.dart';
import 'app_dialogs.dart';
import 'auto_upload_panel.dart';
import 'cos_upload_dialog.dart';
import 'design.dart';
import 'update_button.dart';
import 'workstation_enrollment_panel.dart';

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
  final _api = CosUploadProfile.tryParseApiBase(workstationUploadApiBase);
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
      final api = _api;
      if (api == null) {
        _loadError = '上传服务地址无效，请联系管理员';
        return;
      }
      final profile = await _store.loadCos();
      if (!mounted) return;
      if (profile != null && profile.api.origin != api.origin) {
        _loadError = '已保存的机位配置属于其他服务，请填写当前服务的机位凭据';
      } else {
        _profile = profile;
      }
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
    final api = _api;
    if (_saving || api == null) return;
    final profile = await showDialog<CosUploadProfile>(
      context: context,
      builder: (context) => CosUploadDialog(api: api, initial: _profile),
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
      final api = _api;
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_loadError ?? '请先配置机位连接', textAlign: TextAlign.center),
              if (api != null) ...[
                const SizedBox(height: 16),
                WorkstationEnrollmentPanel(
                  api: api,
                  onBound: _load,
                  onManual: _configure,
                ),
              ],
            ],
          ),
        ),
      );
    }
    return AutoUploadPanel(
      cosProfile: profile,
      onConfigureCos: _configure,
      onActiveChanged: (active) => widget.onActiveChanged?.call(active),
      onUploadingChanged: widget.onUploadingChanged,
      batchTimeline: _batchTimeline(profile),
    );
  }

  Widget? _batchTimeline(CosUploadProfile profile) {
    final bridge = widget.printBridge;
    if (bridge == null) return null;
    return ListenableBuilder(
      listenable: bridge,
      builder: (context, _) {
        if (!bridge.connected || !bridge.configured) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                '取片批次需要打印工作台连接景区后查看。',
                style: TextStyle(color: WorkstationStyle.muted, fontSize: 12),
              ),
            ),
          );
        }
        final config = bridge.config;
        final scenicName = (config['scenicName'] as String?)?.trim();
        return PhotoBatchTimeline.inline(
          key: ValueKey((
            bridge,
            config['activeScenicProfileId'],
            config['scenicCode'],
            profile.stationId,
          )),
          call: bridge.call,
          scenicName: scenicName?.isNotEmpty == true ? scenicName! : '（未返回名称）',
          stationId: profile.stationId,
        );
      },
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
