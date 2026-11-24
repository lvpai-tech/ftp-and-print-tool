import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../release/desktop_update.dart';
import '../release/update_service.dart';
import '../workstation_session.dart';
import 'app_dialogs.dart';

class UpdateButton extends StatefulWidget {
  const UpdateButton({super.key, this.session});
  final WorkstationSession? session;
  @override
  State<UpdateButton> createState() => _UpdateButtonState();
}

class _UpdateButtonState extends State<UpdateButton> {
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    UpdateService? service;
    try {
      final session = widget.session;
      if (session?.updating == true) return;
      if (session != null && Platform.isMacOS && await checkMacUpdate()) return;
      final info = await PackageInfo.fromPlatform();
      final code = int.tryParse(info.buildNumber);
      if (code == null || code < 1) throw StateError('无法读取当前安装版本，请重新安装正式包');
      final setup = session != null && Platform.isWindows && windowsAutoUpdate;
      service = UpdateService(
        windowsInstaller: setup || (Platform.isWindows && updateChannel == 'prd'),
      );
      final release = await service.check();
      if (!mounted) return;
      if (release.code <= code) {
        await showAppMessage(
          context,
          message: '当前已是最新版本 ${info.version}（$code）',
        );
      } else {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _UpdateDialog(
            release: release,
            service: service!,
            install: setup
                ? (file) => installWindowsUpdate(session, release, file)
                : null,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          title: '操作未完成',
          message: switch (error) {
            StateError(:final message) => message,
            PlatformException(message: final String message) => message,
            _ => '更新检查失败，请检查网络或稍后重试',
          },
        );
      }
    } finally {
      service?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: _busy ? null : _check,
    icon: const Icon(Icons.system_update_alt, size: 20),
    label: Text(_busy ? '正在检查…' : '检查更新'),
  );
}

class _UpdateDialog extends StatefulWidget {
  final ReleaseManifest release;
  final UpdateService service;
  final Future<void> Function(File)? install;
  const _UpdateDialog({
    required this.release,
    required this.service,
    this.install,
  });
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _busy = false;
  double _progress = 0;
  String _message = '';
  File? _file;

  Future<void> _download() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      if (widget.release.platform == 'ios') {
        if (!await launchUrl(
          widget.release.url,
          mode: LaunchMode.externalApplication,
        )) {
          throw StateError('无法打开苹果安装入口，请检查系统浏览器');
        }
      } else {
        final cache = await getTemporaryDirectory();
        final file =
            _file ??
            await widget.service.download(widget.release, cache, (value) {
              if (mounted) setState(() => _progress = value);
            });
        if (mounted) {
          setState(() {
            _file = file;
            _message = '下载完成，SHA-256校验通过';
          });
        }
        if (widget.install case final install?) {
          if (mounted) setState(() => _message = '已校验下载文件，正在准备安装…');
          await install(file);
        }
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is StateError
              ? error.message
              : '下载失败，请检查网络及存储空间',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    try {
      if (!await launchUrl(
        Uri.file(_file!.path),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('无法打开更新包，请按显示路径手动打开');
      }
    } catch (_) {
      if (mounted) setState(() => _message = '无法打开更新包，请按显示路径手动打开');
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.release;
    final ios = release.platform == 'ios';
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text('发现新版本 ${release.version}'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${release.platform} · ${release.channel} · code ${release.code}',
                ),
                const SizedBox(height: 12),
                Text(
                  ios
                      ? '前往官方安装入口完成更新。'
                      : widget.install != null
                      ? '下载校验后，等待当前上传和打印完成，再覆盖安装并重启。'
                      : '更新包 ${(release.size / 1048576).toStringAsFixed(1)} MiB，下载后校验完整性。'
                            '请先停止上传并退出旧版本；Windows解压完整ZIP运行，Mac打开DMG安装。',
                ),
                if (_busy)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(
                      value: ios ? null : _progress,
                    ),
                  ),
                if (_message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_message),
                  ),
                if (_file != null) SelectableText(_file!.path),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: _busy
                ? null
                : _file == null || widget.install != null
                ? _download
                : _open,
            child: Text(
              _busy
                  ? '处理中…'
                  : widget.install != null
                  ? '安装并重启'
                  : _file != null
                  ? '打开更新包'
                  : ios
                  ? '前往安装'
                  : '下载并校验',
            ),
          ),
        ],
      ),
    );
  }
}
