import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// macOS uses the native login Keychain for workstation credentials.
const workstationCredentials = MacLoginKeychainStorage();

class MacLoginKeychainStorage extends FlutterSecureStorage {
  const MacLoginKeychainStorage()
      : super(
          mOptions: const MacOsOptions(
            usesDataProtectionKeychain: false,
            accessibility: null,
          ),
        );

  static const _channel = MethodChannel('ai.lvpai.ftp/login-keychain');

  bool get _useNativeLoginKeychain => Platform.isMacOS;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (!_useNativeLoginKeychain) {
      return super.write(
        key: key,
        value: value,
        iOptions: iOptions,
        aOptions: aOptions,
        lOptions: lOptions,
        webOptions: webOptions,
        mOptions: mOptions,
        wOptions: wOptions,
      );
    }
    if (value == null) {
      await delete(key: key);
      return;
    }
    await _channel.invokeMethod<void>('write', {'key': key, 'value': value});
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (!_useNativeLoginKeychain) {
      return super.read(
        key: key,
        iOptions: iOptions,
        aOptions: aOptions,
        lOptions: lOptions,
        webOptions: webOptions,
        mOptions: mOptions,
        wOptions: wOptions,
      );
    }
    return _channel.invokeMethod<String>('read', {'key': key});
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (!_useNativeLoginKeychain) {
      return super.delete(
        key: key,
        iOptions: iOptions,
        aOptions: aOptions,
        lOptions: lOptions,
        webOptions: webOptions,
        mOptions: mOptions,
        wOptions: wOptions,
      );
    }
    await _channel.invokeMethod<void>('delete', {'key': key});
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (!_useNativeLoginKeychain) {
      return super.containsKey(
        key: key,
        iOptions: iOptions,
        aOptions: aOptions,
        lOptions: lOptions,
        webOptions: webOptions,
        mOptions: mOptions,
        wOptions: wOptions,
      );
    }
    final exists = await _channel.invokeMethod<bool>('containsKey', {
      'key': key,
    });
    if (exists == null) throw StateError('钥匙串未返回凭据存在状态');
    return exists;
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (!_useNativeLoginKeychain) {
      return super.readAll(
        iOptions: iOptions,
        aOptions: aOptions,
        lOptions: lOptions,
        webOptions: webOptions,
        mOptions: mOptions,
        wOptions: wOptions,
      );
    }
    return _readNativeEntries();
  }

  Future<Map<String, String>> _readNativeEntries({
    List<String>? prefixes,
    List<String> keys = const [],
    bool legacy = false,
  }) async {
    final values = await _channel.invokeMapMethod<String, String>(
      legacy ? 'readLegacy' : 'readAll',
      prefixes == null ? null : {'prefixes': prefixes, 'keys': keys},
    );
    if (values == null) throw StateError('钥匙串未返回凭据列表');
    return values;
  }
}

extension WorkstationCredentialQueries on FlutterSecureStorage {
  Future<Map<String, String>> readEntries({
    required String prefix,
    List<String> keys = const [],
  }) async {
    final storage = this;
    if (storage is MacLoginKeychainStorage && storage._useNativeLoginKeychain) {
      return storage._readNativeEntries(prefixes: [prefix], keys: keys);
    }
    return {
      for (final entry in (await storage.readAll()).entries)
        if (entry.key.startsWith(prefix) || keys.contains(entry.key))
          entry.key: entry.value,
    };
  }
}

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
    () => workstationCredentials._readNativeEntries(
      prefixes: _migratedPrefixes,
      keys: _migratedKeys,
      legacy: true,
    ),
    workstationCredentials,
  );
}

Future<void> migrateMacWorkstationCredentials(
  Future<Map<String, String>> Function() readPrevious,
  FlutterSecureStorage current,
) async {
  const migrationKey = 'ai.lvpai.lvpaiFtpClient.login-keychain.v1';
  try {
    if (await current.containsKey(key: migrationKey)) return;
    final Map<String, String> values;
    try {
      values = await readPrevious();
    } on PlatformException catch (error) {
      // Temporary-signed builds cannot use the data-protection Keychain.
      // Missing entitlement (-34018) or errSecParam (-50) from the legacy
      // store must leave migration pending for a build that can access it.
      if (error.details == -34018 || error.details == -50) return;
      rethrow;
    }
    for (final entry in values.entries) {
      if (_isWorkstationCredential(entry.key) &&
          !await current.containsKey(key: entry.key)) {
        await current.write(key: entry.key, value: entry.value);
      }
    }
    await current.write(key: migrationKey, value: 'done');
  } on PlatformException catch (error) {
    throw macWorkstationStorageError(error);
  }
}

const _migratedKeys = [
  'ftp.profile.v1',
  'ftp.watch.v1',
  'cos.auto.profile.v1',
  'cos.enrollment.v1',
  'printing.installation',
];

const _migratedPrefixes = [
  'cos.station.v2.',
  'cos.watch.v2.',
  'cos.application.v2.',
  'printing.enrollment.',
];

bool _isWorkstationCredential(String key) =>
    _migratedKeys.contains(key) || _migratedPrefixes.any(key.startsWith);

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
