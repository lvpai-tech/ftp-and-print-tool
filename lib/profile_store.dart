import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auto_upload/cos_upload.dart';
import 'transfer.dart';

/// 仅保存本机配置；Windows 和 Apple 平台使用各自的系统安全存储。
class ProfileStore {
  static const _key = 'ftp.profile.v1';
  static const _cosKey = 'cos.auto.profile.v1';
  final FlutterSecureStorage _storage;

  const ProfileStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  Future<ServerProfile?> load() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    return ServerProfile.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<CosUploadProfile?> loadCos() async {
    final value = await _storage.read(key: _cosKey);
    if (value == null) return null;
    return CosUploadProfile.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> saveCos(CosUploadProfile? profile) => profile == null
      ? _storage.delete(key: _cosKey)
      : _storage.write(key: _cosKey, value: jsonEncode(profile.toJson()));

  Future<void> save(ServerProfile profile) =>
      _storage.write(key: _key, value: jsonEncode(profile.toJson()));
}
