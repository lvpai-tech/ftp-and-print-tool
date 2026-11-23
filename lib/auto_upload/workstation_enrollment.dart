import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../profile_store.dart';
import 'cos_upload.dart';

class EnrollmentError implements Exception {
  const EnrollmentError(this.message, {this.retryable = false});
  final String message;
  final bool retryable;
}

class EnrollmentStatus {
  const EnrollmentStatus(this.id, this.status, {this.reason, this.binding});

  final String id;
  final String status;
  final String? reason;
  final Map<String, dynamic>? binding;

  bool get terminal =>
      const {'REJECTED', 'CANCELLED', 'EXPIRED'}.contains(status);
}

/// Owns the persisted request and claim so retries use the original credentials.
class WorkstationEnrollment {
  WorkstationEnrollment(this.api, this.store, this.client);

  final Uri api;
  final ProfileStore store;
  final http.Client client;

  Future<EnrollmentStatus> begin(
    String scenicName,
    String location,
    String? code,
  ) async {
    if (await _load() != null) return (await refresh())!;
    final random = Random.secure();
    final idBytes = List.generate(16, (_) => random.nextInt(256));
    idBytes[6] = (idBytes[6] & 0x0f) | 0x40;
    idBytes[8] = (idBytes[8] & 0x3f) | 0x80;
    final id = _hex(idBytes);
    final requestId =
        '${id.substring(0, 8)}-${id.substring(8, 12)}-'
        '${id.substring(12, 16)}-${id.substring(16, 20)}-${id.substring(20)}';
    await store.saveEnrollment({
      'api': api.origin,
      'secret': _hex(List.generate(32, (_) => random.nextInt(256))),
      'draft': {
        'requestId': requestId,
        'scenicName': scenicName,
        'location': location,
        'stationCode': ?code,
      },
    });
    return (await refresh())!;
  }

  Future<EnrollmentStatus?> refresh() async {
    final local = await _load();
    if (local == null) return null;
    final draft = local['draft'] as Map<String, dynamic>;
    final id = draft['requestId'] as String;
    final secret = local['secret'] as String;
    final path = '/applications/$id';
    final snapshot = local['submitted'] == true
        ? await _request('GET', path, secret)
        : await _request('POST', '/applications', secret, body: draft);
    final status = _status(snapshot, id);
    if (local['submitted'] != true) {
      local['submitted'] = true;
      await store.saveEnrollment(local);
    }
    if (status.status != 'APPROVED' && status.status != 'BOUND') return status;

    var pending = local['pending'] as Map<String, dynamic>?;
    if (pending == null) {
      if (status.status == 'BOUND') {
        throw const EnrollmentError('机位已激活，但本机配置缺失，请联系运营重新绑定');
      }
      final claimed = await _request('POST', '$path/claim', secret);
      final binding = claimed['binding'] as Map<String, dynamic>?;
      final stationId = binding?['stationId'];
      final token = claimed['stationToken'];
      if (stationId is! String ||
          stationId != status.binding?['stationId'] ||
          token is! String) {
        throw const EnrollmentError('领取的机位配置不完整');
      }
      pending = CosUploadProfile(
        api.origin,
        stationId,
        token,
        stationName: binding?['stationName'] as String?,
        stationCode: binding?['stationCode'] as String?,
        scenicName: binding?['scenicName'] as String?,
      ).toJson();
      local['pending'] = pending;
      await store.saveEnrollment(local);
    }

    final profile = CosUploadProfile.fromJson(pending);
    if (profile.api.origin != api.origin ||
        profile.stationId != status.binding?['stationId']) {
      throw const EnrollmentError('待激活配置与当前机位不一致，请联系运营');
    }
    final activated = _status(
      await _request(
        'POST',
        '$path/activate',
        secret,
        stationToken: profile.token,
      ),
      id,
    );
    if (activated.status != 'BOUND' ||
        activated.binding?['stationId'] != profile.stationId) {
      throw const EnrollmentError('服务端未确认机位激活');
    }
    await store.saveCos(profile);
    await store.saveEnrollment(null);
    return activated;
  }

  Future<void> clearLocal() async {
    if (await _load() != null) await store.saveEnrollment(null);
  }

  Future<Map<String, dynamic>?> _load() async {
    final value = await store.loadEnrollment();
    return value?['api'] == api.origin ? value : null;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  EnrollmentStatus _status(Map<String, dynamic> data, String id) {
    final status = data['status'];
    const states = {
      'PENDING',
      'APPROVED',
      'BOUND',
      'REJECTED',
      'CANCELLED',
      'EXPIRED',
    };
    if (data['id'] != id || !states.contains(status)) {
      throw const EnrollmentError('机位申请状态无效');
    }
    return EnrollmentStatus(
      id,
      status as String,
      reason: data['reason'] as String?,
      binding: data['binding'] as Map<String, dynamic>?,
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path,
    String secret, {
    Map<String, dynamic>? body,
    String? stationToken,
  }) async {
    final uri = api.replace(path: '/api/operation/workstation-enrollment$path');
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers['X-Workstation-Enrollment-Token'] = secret;
    if (stationToken != null) {
      request.headers['X-Workstation-Token'] = stationToken;
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw EnrollmentError(
        '机位申请请求失败（HTTP ${response.statusCode}）',
        retryable: response.statusCode == 429 || response.statusCode >= 500,
      );
    }
    final payload = jsonDecode(utf8.decode(response.bodyBytes));
    if (payload is! Map<String, dynamic>) {
      throw const EnrollmentError('机位申请响应无效');
    }
    if (payload['code'] != 200) {
      final message = payload['message'];
      final code = payload['code'];
      throw EnrollmentError(
        message is String && message.isNotEmpty ? message : '机位申请请求失败',
        retryable: code == 42901 || code == 50002,
      );
    }
    final data = payload['data'];
    if (data is! Map<String, dynamic>) {
      throw const EnrollmentError('机位申请响应缺少数据');
    }
    return data;
  }
}
