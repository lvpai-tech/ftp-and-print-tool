import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auto_upload/cos_upload.dart';
import 'transfer.dart';
import 'workstation_storage.dart';

/// 仅保存本机配置；Windows 和 Apple 平台使用各自的系统安全存储。
class ProfileStore {
  static const _key = 'ftp.profile.v1';
  static const _cosKey = 'cos.auto.profile.v1';
  static const _enrollmentKey = 'cos.enrollment.v1';
  static const _stationPrefix = 'cos.station.v2.';
  static const _watchPrefix = 'cos.watch.v2.';
  static const _oldWatchKey = 'ftp.watch.v1';
  static const _applicationPrefix = 'cos.application.v2.';
  final FlutterSecureStorage _storage;

  const ProfileStore({this._storage = workstationCredentials});

  static String uploadScope(Uri api) =>
      sha256.convert(utf8.encode(api.origin)).toString();
  static String uploadKey(CosUploadProfile profile) =>
      '${uploadScope(profile.api)}.${profile.stationId}';

  Future<ServerProfile?> load() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    return ServerProfile.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> migrateUploads(Uri api) async {
    final legacy = await _read(_cosKey);
    if (legacy?['api'] == api.origin) {
      final profile = CosUploadProfile.fromJson(legacy!);
      if (await _read('$_stationPrefix${uploadKey(profile)}') == null) {
        final watch = await _read(_oldWatchKey);
        if (watch != null && await loadWatch(profile) == null) {
          await saveWatch(profile, {
            'legacyFolder': watch['folder'] as String,
            'recursive': watch['recursive'] as bool,
          });
        }
        await saveCos(profile, keepManagedDefault: true);
      }
    }
    final enrollment = await _read(_enrollmentKey);
    if (enrollment?['api'] == api.origin) {
      final id =
          (enrollment!['draft'] as Map<String, dynamic>)['requestId'] as String;
      if (await loadEnrollment(api, id) == null) {
        await saveEnrollment(api, id, enrollment);
      }
      await _storage.delete(key: _enrollmentKey);
    }
  }

  Future<List<CosUploadProfile>> loadStations(Uri api) async => [
    for (final value in (await _storage.readEntries(
      prefix: '$_stationPrefix${uploadScope(api)}.',
    )).values)
      CosUploadProfile.fromJson(jsonDecode(value) as Map<String, dynamic>),
  ];

  Future<void> saveCos(
    CosUploadProfile profile, {
    bool keepManagedDefault = false,
  }) async {
    final key = '$_stationPrefix${uploadKey(profile)}';
    if (!keepManagedDefault &&
        await _storage.containsKey(key: key) == false &&
        await loadWatch(profile) == null) {
      await saveWatch(profile, {'folderRequired': true, 'enabled': false});
    }
    await _storage.write(key: key, value: jsonEncode(profile.toJson()));
  }

  Future<void> removeCos(CosUploadProfile profile) async {
    final key = '$_stationPrefix${uploadKey(profile)}';
    final saved = await _read(key);
    if (saved != null && saved['token'] != profile.token) {
      throw StateError('机位密钥已更新，请刷新后再移除');
    }
    final legacy = await _read(_cosKey);
    if (legacy?['api'] == profile.api.origin &&
        legacy?['stationId'] == profile.stationId) {
      await _storage.delete(key: _cosKey);
    }
    await _storage.delete(key: key);
  }

  Future<Map<String, dynamic>?> loadWatch(CosUploadProfile profile) =>
      _read('$_watchPrefix${uploadKey(profile)}');

  Future<void> saveWatch(
    CosUploadProfile profile,
    Map<String, dynamic> value,
  ) => _storage.write(
    key: '$_watchPrefix${uploadKey(profile)}',
    value: jsonEncode(value),
  );

  Future<List<({String? key, String path, String? identity})>>
  loadWatchFolders() async {
    final entries = await _storage.readEntries(
      prefix: _watchPrefix,
      keys: const [_oldWatchKey, _cosKey],
    );
    final folders = <({String? key, String path, String? identity})>[];
    for (final entry in entries.entries) {
      if (!entry.key.startsWith(_watchPrefix)) continue;
      final watch = jsonDecode(entry.value) as Map<String, dynamic>;
      final path = (watch['folder'] ?? watch['legacyFolder']) as String?;
      if (path != null && path.isNotEmpty) {
        folders.add((
          key: entry.key.substring(_watchPrefix.length),
          path: path,
          identity: watch['folderIdentity'] as String?,
        ));
      }
    }

    final oldWatch = entries[_oldWatchKey];
    final oldCos = entries[_cosKey];
    if (oldWatch != null) {
      final watch = jsonDecode(oldWatch) as Map<String, dynamic>;
      final path = watch['folder'] as String?;
      final owner = oldCos == null
          ? null
          : uploadKey(
              CosUploadProfile.fromJson(
                jsonDecode(oldCos) as Map<String, dynamic>,
              ),
            );
      if (path != null &&
          path.isNotEmpty &&
          (owner == null
              ? !folders.any((item) => item.path == path)
              : !entries.containsKey('$_watchPrefix$owner'))) {
        folders.add((key: owner, path: path, identity: null));
      }
    }
    return folders;
  }

  Future<List<Map<String, dynamic>>> loadEnrollments(Uri api) async => [
    for (final value in (await _storage.readEntries(
      prefix: '$_applicationPrefix${uploadScope(api)}.',
    )).values)
      jsonDecode(value) as Map<String, dynamic>,
  ];

  Future<Map<String, dynamic>?> loadEnrollment(Uri api, String id) =>
      _read('$_applicationPrefix${uploadScope(api)}.$id');

  Future<Map<String, dynamic>?> _read(String key) async {
    final value = await _storage.read(key: key);
    return value == null ? null : jsonDecode(value) as Map<String, dynamic>;
  }

  Future<void> saveEnrollment(Uri api, String id, Map<String, dynamic>? value) {
    final key = '$_applicationPrefix${uploadScope(api)}.$id';
    return value == null
        ? _storage.delete(key: key)
        : _storage.write(key: key, value: jsonEncode(value));
  }

  Future<void> save(ServerProfile profile) =>
      _storage.write(key: _key, value: jsonEncode(profile.toJson()));
}
