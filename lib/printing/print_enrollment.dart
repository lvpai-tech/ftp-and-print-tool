import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../auto_upload/cos_upload.dart' show workstationUploadApiBase;
import '../auto_upload/workstation_enrollment.dart';
import '../profile_store.dart';

/// Owns the request and device credentials in the operating system's secure storage.
class PrintEnrollment {
  PrintEnrollment(this.client);

  final http.Client client;
  static const storage = FlutterSecureStorage();
  static final origin = _origin();
  static final prefix =
      'printing.enrollment.${ProfileStore.uploadScope(origin)}.';
  static final random = Random.secure();

  static Uri _origin() {
    final override = Platform.environment['PRINT_AGENT_BASE'];
    final base = Uri.tryParse((override ?? workstationUploadApiBase).trim());
    if (base == null ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        !{'', '/', '/api/operation', '/api/operation/'}.contains(base.path) ||
        !(base.scheme == 'https' ||
            (base.scheme == 'http' &&
                {'localhost', '127.0.0.1', '::1'}.contains(base.host)))) {
      throw StateError('打印服务地址无效');
    }
    return Uri.parse(base.origin);
  }

  static String _randomHex(int count) => List.generate(
    count,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  static String _uuid() {
    final hex = _randomHex(16);
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}'
        '-8${hex.substring(17, 20)}-${hex.substring(20)}';
  }

  Future<List<EnrollmentScenic>> loadScenics() =>
      WorkstationEnrollment(origin, const ProfileStore(), client).loadScenics();

  Future<Map<String, dynamic>> begin(
    EnrollmentScenic scenic,
    String location,
  ) async {
    const installationKey = 'printing.installation';
    var installation = await storage.read(key: installationKey);
    if (installation == null) {
      installation = _uuid();
      await storage.write(key: installationKey, value: installation);
    }
    final draft = <String, dynamic>{
      'id': _uuid(),
      'installationId': installation,
      'scenicId': scenic.id,
      'scenicName': scenic.name,
      'location': location,
      'deviceName': String.fromCharCodes(
        Platform.localHostname.runes.take(100),
      ),
      'requestToken': _randomHex(32),
      'status': 'UNSUBMITTED',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    await save(draft);
    return draft;
  }

  static Future<List<Map<String, dynamic>>> records() async {
    final values = await storage.readAll();
    return values.entries
        .where((entry) => entry.key.startsWith(prefix))
        .map(
          (entry) => Map<String, dynamic>.from(jsonDecode(entry.value) as Map),
        )
        .toList()
      ..sort(
        (a, b) =>
            (b['createdAt'] as String).compareTo(a['createdAt'] as String),
      );
  }

  static Future<Map<String, String>> credentials() async => {
    for (final row in await records())
      if (row['deviceToken'] is String)
        row['id'] as String: row['deviceToken'] as String,
  };

  static Future<void> save(Map<String, dynamic> row) =>
      storage.write(key: '$prefix${row['id']}', value: jsonEncode(row));

  Future<void> refresh(
    Map<String, dynamic> row,
    Future<void> Function(String id, String token, String scenicId) install,
  ) async {
    final id = row['id'] as String;
    final status = row['status'] == 'UNSUBMITTED'
        ? await _send(
            'POST',
            '/applications',
            row,
            body: {
              'requestId': id,
              for (final key in [
                'installationId',
                'scenicId',
                'location',
                'deviceName',
              ])
                key: row[key],
            },
          )
        : await _send('GET', '/applications/$id', row);
    row.addAll(status);
    await save(row);
    if (status['status'] == 'APPROVED' || status['status'] == 'ACTIVATED') {
      if (status['status'] == 'APPROVED' && row['deviceToken'] == null) {
        row['deviceToken'] = _randomHex(32);
        await save(row);
      }
      final token = row['deviceToken'] as String?;
      if (token == null) throw StateError('本机打印凭据缺失，请重新申请');
      final active = await _send(
        'POST',
        '/applications/$id/activate',
        row,
        deviceToken: token,
      );
      if (active['status'] != 'ACTIVATED') throw StateError('打印设备未完成激活');
      row.addAll(active);
      await save(row);
      await install(id, token, row['scenicId'] as String);
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic> row, {
    Map<String, dynamic>? body,
    String? deviceToken,
  }) async {
    final uri = origin.replace(
      path: '/api/operation/print-workstation-enrollment$path',
    );
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers['X-Print-Enrollment-Token'] = row['requestToken'] as String;
    if (deviceToken != null) {
      request.headers['X-Print-Agent-Token'] = deviceToken;
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    final response = await client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 15));
    final payload = jsonDecode(utf8.decode(response.bodyBytes));
    if (payload case {'code': 200, 'data': final Map<String, dynamic> data}
        when response.statusCode == 200 &&
            data['id'] == row['id'] &&
            data['status'] is String &&
            data['scenicId'] is String) {
      return data;
    }
    if (payload case {'message': final String message}) {
      throw StateError(message);
    }
    throw StateError('打印申请失败（HTTP ${response.statusCode}）');
  }
}
