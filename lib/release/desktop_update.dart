import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../workstation_session.dart';
import 'update_service.dart';

const windowsAutoUpdate = bool.fromEnvironment('LVPAI_WINDOWS_AUTO_UPDATE');
const _macUpdater = MethodChannel('ai.lvpai.ftp/desktop-update');

void connectMacUpdater(WorkstationSession session) {
  _macUpdater.setMethodCallHandler((call) async {
    if (call.method == 'recover') {
      await session.recoverAfterUpdateFailure(restartPrinting: true);
      session.report('更新未完成，已恢复工作台。请重新检查更新。');
      return null;
    }
    if (call.method != 'prepare') throw MissingPluginException();
    try {
      await session.prepareForUpdate();
      return true;
    } catch (error) {
      session.report(error is StateError ? error.message : '无法安全退出，请稍后重试更新');
      return false;
    }
  });
}

Future<bool> checkMacUpdate() async {
  final platform = UpdateService.currentPlatform();
  ReleaseManifest.validateChannel(updateChannel);
  return await _macUpdater.invokeMethod<bool>(
        'check',
        '$releaseOrigin/ftp-client/$updateChannel/$platform/appcast.xml',
      ) ??
      false;
}

Future<void> installWindowsUpdate(
  WorkstationSession session,
  ReleaseManifest release,
  File installer,
) async {
  final systemRoot = Platform.environment['SystemRoot'];
  if (systemRoot == null || !p.isAbsolute(systemRoot)) {
    throw StateError('无法定位 Windows 安装环境');
  }
  final powershell = p.join(
    systemRoot,
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
  final script = await rootBundle.loadString('windows/installer/update.ps1');
  final encoded = ByteData(script.length * 2);
  for (var i = 0; i < script.length; i++) {
    encoded.setUint16(i * 2, script.codeUnitAt(i), Endian.little);
  }
  final arguments = [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-EncodedCommand',
    base64Encode(encoded.buffer.asUint8List()),
  ];
  final environment = {
    'LVPAI_UPDATE_INSTALLER': installer.path,
    'LVPAI_UPDATE_EXECUTABLE': Platform.resolvedExecutable,
    'LVPAI_UPDATE_PID': '$pid',
    'LVPAI_UPDATE_SHA256': release.sha256Hex,
  };
  final verification = await Process.run(
    powershell,
    arguments,
    environment: {...environment, 'LVPAI_UPDATE_MODE': 'verify'},
  );
  if (verification.exitCode == 11) {
    throw StateError('请先使用正式 Setup.exe 安装当前版本，再通过工作台更新。');
  }
  if (verification.exitCode != 0) {
    throw StateError('安装包完整性或签名校验失败，无法安装。');
  }
  await session.prepareForUpdate();
  try {
    await Process.start(
      powershell,
      arguments,
      environment: {...environment, 'LVPAI_UPDATE_MODE': 'install'},
      mode: ProcessStartMode.detached,
    );
  } catch (_) {
    await session.recoverAfterUpdateFailure(restartPrinting: true);
    rethrow;
  }
  exit(0);
}
