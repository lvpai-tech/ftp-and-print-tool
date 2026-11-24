import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/workstation_storage.dart';
import 'package:path/path.dart' as p;

class _Credentials extends FlutterSecureStorage {
  final Map<String, String> values = {};
  int? writeError;
  int? readAllError;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (writeError case final error?) {
      throw PlatformException(code: 'test', details: error);
    }
    values[key] = value!;
  }

  @override
  Future<String?> read({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> delete({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values.remove(key);

  @override
  Future<bool> containsKey({
    required String key,
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values.containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (readAllError case final error?) {
      throw PlatformException(code: 'test', details: error);
    }
    return Map.of(values);
  }
}

void main() {
  test('钥匙串预检报告写入失败，恢复后清理探针', () async {
    final credentials = _Credentials()..writeError = -25308;
    await expectLater(
      checkWorkstationCredentials(credentials),
      throwsA(
        isA<WorkstationStorageError>().having(
          (error) => error.message,
          'message',
          contains('-25308'),
        ),
      ),
    );
    credentials.writeError = null;
    await checkWorkstationCredentials(credentials);
    expect(credentials.values, isEmpty);
  });

  test('迁移仅补充旧工作台凭据，重试不会覆盖或恢复已删除记录', () async {
    final previous = _Credentials()
      ..values.addAll({
        'printing.enrollment.1': 'old',
        'cos.station.v2.2': 'old',
        'unrelated': 'other',
      });
    final current = _Credentials()..values['printing.enrollment.1'] = 'new';
    await migrateMacWorkstationCredentials(previous, current);
    expect(current.values['printing.enrollment.1'], 'new');
    expect(current.values['cos.station.v2.2'], 'old');
    expect(current.values, isNot(contains('unrelated')));
    await current.delete(key: 'cos.station.v2.2');
    await migrateMacWorkstationCredentials(previous, current);
    expect(current.values, isNot(contains('cos.station.v2.2')));
  });

  test('临时签名缺少旧钥匙串授权时保留已存凭据', () async {
    final previous = _Credentials()..readAllError = -34018;
    final current = _Credentials()..values['printing.installation'] = 'kept';
    await migrateMacWorkstationCredentials(previous, current);
    expect(current.values, {'printing.installation': 'kept'});
  });

  test('目录读写预检会清理探针并报告失效路径', () async {
    final dir = await Directory.systemTemp.createTemp('workstation-access-');
    addTearDown(() => dir.delete(recursive: true));
    await checkWritableDirectory(dir);
    expect(await dir.list().isEmpty, isTrue);
    final entry = await File(p.join(dir.path, 'entry')).create();
    await expectLater(
      checkWritableDirectory(Directory(entry.path)),
      throwsA(isA<FileSystemException>()),
    );
  });
}
