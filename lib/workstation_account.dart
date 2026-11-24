import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auto_upload/cos_upload.dart';
import 'workstation_storage.dart';

typedef WorkstationScenic = ({String id, String name, String code});

class WorkstationIdentity {
  const WorkstationIdentity(this.id, this.name, this.role, this.scenics);
  final String id, name, role;
  final List<WorkstationScenic> scenics;

  bool permits(String? scenicId) =>
      scenics.any((scenic) => scenic.id == scenicId);
}

class WorkstationAccountError implements Exception {
  const WorkstationAccountError(
    this.message, {
    this.invalidSession = false,
    this.deniedDevice = false,
  });
  final String message;
  final bool invalidSession;
  final bool deniedDevice;

  @override
  String toString() => message;
}

class WorkstationAccount {
  WorkstationAccount(this.origin, {FlutterSecureStorage? storage})
    : _storage = storage ?? workstationCredentials;

  factory WorkstationAccount.configured() => WorkstationAccount(
    CosUploadProfile.tryParseApiBase(workstationUploadApiBase),
  );

  final Uri? origin;
  final FlutterSecureStorage _storage;
  String? _token;
  String? get token => _token;
  String get _key => 'workstation-personnel-v1:${origin?.origin ?? ''}';

  void _checkOrigin() {
    if (origin == null) {
      throw const WorkstationAccountError('工作台服务地址无效，请联系管理员');
    }
  }

  Future<int> sendCode(String phone) async {
    final data = await _request(
      'POST',
      '/api/auth/workstation/sms/send',
      body: {'phone': phone},
    );
    final retry = data?['retryAfterSeconds'];
    if (retry is! int || retry <= 0) throw _invalidResponse;
    return retry;
  }

  Future<WorkstationIdentity> login(String phone, String code) async {
    final data = await _request(
      'POST',
      '/api/auth/workstation/login',
      body: {'phone': phone, 'code': code},
    );
    final next = data?['accessToken'];
    final expires = data?['expiresIn'];
    if (next is! String || next.isEmpty || expires is! int || expires <= 0) {
      throw _invalidResponse;
    }
    try {
      final identity = await _identity(next);
      await _withStorage(() => _storage.write(key: _key, value: next));
      _token = next;
      return identity;
    } catch (_) {
      try {
        await _revoke(next);
      } on WorkstationAccountError {
        // 本机未采用此令牌，服务端按有效期清理。
      }
      rethrow;
    }
  }

  Future<WorkstationIdentity?> restore() async {
    _checkOrigin();
    _token ??= await _withStorage(() => _storage.read(key: _key));
    final current = _token;
    if (current == null) return null;
    try {
      return await _identity(current);
    } on WorkstationAccountError catch (error) {
      if (!error.invalidSession) rethrow;
      await forget();
      return null;
    }
  }

  Future<WorkstationIdentity> _identity(String token) async {
    final data = await _request(
      'GET',
      '/api/operation/workstation-session/me',
      bearer: token,
    );
    final id = data?['opUserId'];
    final name = data?['name'];
    final role = data?['role'];
    final rows = data?['scenics'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        role is! String ||
        !const {'admin', 'operator'}.contains(role) ||
        rows is! List) {
      throw _invalidResponse;
    }
    return WorkstationIdentity(
      id,
      name,
      role,
      rows.map(_scenic).toList(growable: false),
    );
  }

  Future<WorkstationScenic> stationScenic(CosUploadProfile profile) async {
    if (profile.api.origin != origin?.origin || _token == null) {
      throw const WorkstationAccountError('机位与当前工作台环境不一致');
    }
    return _scenic(
      await _request(
        'GET',
        '/api/operation/workstation-session/stations/${profile.stationId}',
        bearer: _token,
        deviceToken: profile.token,
      ),
    );
  }

  WorkstationScenic _scenic(Object? row) {
    if (row is! Map ||
        row['id'] is! String ||
        (row['id'] as String).isEmpty ||
        row['name'] is! String ||
        row['code'] is! String) {
      throw _invalidResponse;
    }
    return (
      id: row['id'] as String,
      name: row['name'] as String,
      code: row['code'] as String,
    );
  }

  Future<String?> lastScenic(WorkstationIdentity user) =>
      _storage.read(key: '$_key:scenic:${user.id}');

  Future<void> rememberScenic(
    WorkstationIdentity user,
    WorkstationScenic scenic,
  ) => _storage.write(key: '$_key:scenic:${user.id}', value: scenic.id);

  Future<void> forget() async {
    await _withStorage(() => _storage.delete(key: _key));
    _token = null;
  }

  Future<T> _withStorage<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PlatformException catch (error) {
      if (!Platform.isMacOS) rethrow;
      throw WorkstationAccountError(macWorkstationStorageError(error).message);
    }
  }

  Future<void> logout() async {
    final token = _token;
    await forget();
    if (token != null) await _revoke(token);
  }

  Future<void> _revoke(String token) async {
    try {
      await _request('POST', '/api/auth/workstation/logout', bearer: token);
    } on WorkstationAccountError catch (error) {
      if (!error.invalidSession) rethrow;
    }
  }

  static const _invalidResponse = WorkstationAccountError('工作台服务返回了无效的登录数据');

  Future<Map<String, dynamic>?> _request(
    String method,
    String route, {
    Map<String, String>? body,
    String? bearer,
    String? deviceToken,
  }) async {
    _checkOrigin();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.openUrl(
        method,
        origin!.replace(path: route),
      );
      request.followRedirects = false;
      if (bearer != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      if (deviceToken != null) {
        request.headers.set('X-Workstation-Token', deviceToken);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      final invalid = response.statusCode == 401 || response.statusCode == 403;
      if (response.statusCode != 200) {
        throw WorkstationAccountError(
          invalid ? '当前账号或设备授权无法使用' : '工作台服务暂不可用（HTTP ${response.statusCode}）',
          invalidSession: invalid && deviceToken == null,
          deniedDevice: invalid && deviceToken != null,
        );
      }
      final result = jsonDecode(text);
      if (result is! Map) throw _invalidResponse;
      final code = result['code'];
      if (code != 200) {
        final message = result['message'];
        throw WorkstationAccountError(
          message is String && message.isNotEmpty ? message : '工作台请求未成功，请重试',
          invalidSession:
              deviceToken == null && const {40101, 40102, 40301}.contains(code),
          deniedDevice:
              deviceToken != null &&
              const {40101, 40102, 40301, 40401}.contains(code),
        );
      }
      final data = result['data'];
      if (data == null) return null;
      if (data is! Map<String, dynamic>) throw _invalidResponse;
      return data;
    } on IOException {
      throw const WorkstationAccountError('无法连接工作台服务，请检查网络后重试');
    } on TimeoutException {
      throw const WorkstationAccountError('连接工作台服务超时，请重试');
    } on FormatException {
      throw _invalidResponse;
    } finally {
      client.close(force: true);
    }
  }
}
