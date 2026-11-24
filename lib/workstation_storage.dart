import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const workstationCredentials = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);

class WorkstationStorageError extends StateError {
  WorkstationStorageError(super.message);
}

Future<void>? _macCheck;

Future<void> checkMacUploadStorage() async {
  try {
    final support = await getApplicationSupportDirectory();
    final queueDirectory = await Directory(p.join(support.path, 'auto-upload'))
        .create(recursive: true);
    await checkWritableDirectory(queueDirectory);
  } on FileSystemException {
    throw WorkstationStorageError('无法读写工作台数据目录，请检查目录权限和可用空间后重试。');
  } on MissingPlatformDirectoryException {
    throw WorkstationStorageError('找不到工作台数据目录，请恢复当前用户的数据目录后重试。');
  }
  await checkMacWorkstationCredentials();
}

Future<void> checkMacWorkstationCredentials() {
  if (!Platform.isMacOS) return Future.value();
  return _macCheck ??= _checkAndMigrate().whenComplete(() => _macCheck = null);
}

Future<void> _checkAndMigrate() async {
  await checkWorkstationCredentials(workstationCredentials);
  await migrateMacWorkstationCredentials(
    const FlutterSecureStorage(),
    workstationCredentials,
  );
}

Future<void> migrateMacWorkstationCredentials(
  FlutterSecureStorage previous,
  FlutterSecureStorage current,
) async {
  const migrationKey = 'ai.lvpai.lvpaiFtpClient.login-keychain.v1';
  try {
    if (await current.containsKey(key: migrationKey)) return;
    final Map<String, String> values;
    try {
      values = await previous.readAll();
    } on PlatformException catch (error) {
      // Ad hoc builds have no access group in the data protection Keychain.
      if (error.details == -34018) return;
      rethrow;
    }
    final existing = await current.readAll();
    for (final entry in values.entries) {
      if (_isWorkstationCredential(entry.key) &&
          !existing.containsKey(entry.key)) {
        await current.write(key: entry.key, value: entry.value);
      }
    }
    await current.write(key: migrationKey, value: 'done');
  } on PlatformException catch (error) {
    throw macWorkstationStorageError(error);
  }
}

bool _isWorkstationCredential(String key) =>
    const {
      'ftp.profile.v1',
      'ftp.watch.v1',
      'cos.auto.profile.v1',
      'cos.enrollment.v1',
      'printing.installation',
    }.contains(key) ||
    const [
      'cos.station.v2.',
      'cos.watch.v2.',
      'cos.application.v2.',
      'printing.enrollment.',
    ].any(key.startsWith);

Future<void> checkWorkstationCredentials(FlutterSecureStorage storage) async {
  // A read of an empty Keychain can succeed even when creating items is denied.
  final key = 'workstation.access-check.${Random.secure().nextInt(1 << 32)}';
  try {
    await storage.write(key: key, value: 'check');
    try {
      if (await storage.read(key: key) != 'check') {
        throw WorkstationStorageError('无法读回本机钥匙串项目。请解锁登录钥匙串后重试。');
      }
    } finally {
      await storage.delete(key: key);
    }
  } on PlatformException catch (error) {
    throw macWorkstationStorageError(error);
  }
}

WorkstationStorageError macWorkstationStorageError(PlatformException error) {
  final code = error.details;
  final detail = code is int ? '（系统错误 $code）' : '';
  return WorkstationStorageError(
    '本机钥匙串暂不可用$detail。请解锁登录钥匙串，在系统提示中允许帧集快拍访问后重试。',
  );
}

Future<void> checkWritableDirectory(Directory directory) async {
  final probe = await directory.createTemp('.lvpai-access-');
  final file = File(p.join(probe.path, 'check'));
  try {
    await file.writeAsString('check', flush: true);
    await file.readAsString();
  } finally {
    if (await file.exists()) await file.delete();
    await probe.delete();
  }
}
