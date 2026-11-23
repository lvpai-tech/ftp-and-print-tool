import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auto_upload/cos_upload.dart';
import 'transfer.dart';

/// 仅保存本机配置；Windows 和 Apple 平台使用各自的系统安全存储。
class ProfileStore {
  static const _key = 'ftp.profile.v1';
  static const _cosKey = 'cos.auto.profile.v1';
  static const _enrollmentKey = 'cos.enrollment.v1';
  static const _stationPrefix = 'cos.station.v2.';
  static const _watchPrefix = 'cos.watch.v2.';
  static const _applicationPrefix = 'cos.application.v2.';
  final FlutterSecureStorage _storage;

  const ProfileStore({this._storage = const FlutterSecureStorage()});

  static String uploadScope(Uri api) =>
      sha256.convert(utf8.encode(api.origin)).toString();
  String _stationKey(CosUploadProfile profile) =>
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
      if (await _read('$_stationPrefix${_stationKey(profile)}') == null) {
        final watch = await _read('ftp.watch.v1');
        if (watch != null) {
          await saveWatch(profile, {
            'legacyFolder': watch['folder'] as String,
            'recursive': watch['recursive'] as bool,
          });
        }
        await saveCos(profile);
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
    for (final entry in (await _storage.readAll()).entries)
      if (entry.key.startsWith('$_stationPrefix${uploadScope(api)}.'))
        CosUploadProfile.fromJson(
          jsonDecode(entry.value) as Map<String, dynamic>,
        ),
  ];

  Future<void> saveCos(CosUploadProfile profile) => _storage.write(
    key: '$_stationPrefix${_stationKey(profile)}',
    value: jsonEncode(profile.toJson()),
  );

  Future<Map<String, dynamic>?> loadWatch(CosUploadProfile profile) =>
      _read('$_watchPrefix${_stationKey(profile)}');

  Future<void> saveWatch(
    CosUploadProfile profile,
    Map<String, dynamic> value,
  ) => _storage.write(
    key: '$_watchPrefix${_stationKey(profile)}',
    value: jsonEncode(value),
  );

  Future<List<Map<String, dynamic>>> loadEnrollments(Uri api) async => [
    for (final entry in (await _storage.readAll()).entries)
      if (entry.key.startsWith('$_applicationPrefix${uploadScope(api)}.'))
        jsonDecode(entry.value) as Map<String, dynamic>,
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
