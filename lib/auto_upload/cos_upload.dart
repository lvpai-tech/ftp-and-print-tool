import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../camera_metadata.dart';

const workstationUploadApiBase = String.fromEnvironment(
  'LVPAI_WORKSTATION_API_BASE',
  defaultValue: 'https://hilvpai.com',
);

/// The HTTPS endpoint and credential for one workstation camera station.
class CosUploadProfile {
  final Uri api;
  final String stationId;
  final String token;
  final String? stationName;
  final String? stationCode;
  final String? scenicName;
  final String? scenicId;

  CosUploadProfile(
    String apiBase,
    this.stationId,
    this.token, {
    this.stationName,
    this.stationCode,
    this.scenicName,
    this.scenicId,
  }) : api = tryParseApiBase(apiBase) ?? (throw StateError('上传服务地址无效')) {
    if (!RegExp(r'^[1-9][0-9]{0,17}$').hasMatch(stationId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw StateError('请填写机位 ID 和有效机位密钥');
    }
  }

  static Uri? tryParseApiBase(String value) {
    final api = Uri.tryParse(value.trim());
    if (api == null ||
        api.scheme != 'https' ||
        api.host.isEmpty ||
        api.userInfo.isNotEmpty ||
        !{'', '/'}.contains(api.path) ||
        api.hasQuery ||
        api.hasFragment) {
      return null;
    }
    return api;
  }

  String get queueTarget => '${api.origin}/$stationId';

  Map<String, String> toJson() => {
    'api': api.origin,
    'stationId': stationId,
    'token': token,
    'stationName': ?stationName,
    'stationCode': ?stationCode,
    'scenicName': ?scenicName,
    'scenicId': ?scenicId,
  };

  factory CosUploadProfile.fromJson(Map<String, dynamic> json) =>
      CosUploadProfile(
        json['api'] as String,
        json['stationId'] as String,
        json['token'] as String,
        stationName: json['stationName'] as String?,
        stationCode: json['stationCode'] as String?,
        scenicName: json['scenicName'] as String?,
        scenicId: json['scenicId'] as String?,
      );
}

class CosUploadAuthorizationError extends StateError {
  CosUploadAuthorizationError(super.message);
}

/// Streams queued originals to COS and confirms their upload with the backend.
class CosUpload {
  final CosUploadProfile profile;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 20);

  CosUpload(this.profile, {this.personnelToken});

  final String? Function()? personnelToken;

  Future<String> upload(
    File file,
    String requestId,
    String sha256,
    void Function(double) onProgress, {
    bool recover = false,
    CameraMetadata? captureMetadata,
  }) async {
    final size = await file.length();
    if (size < 1 || size > 60 * 1024 * 1024) {
      throw StateError('照片大小不合法，请使用 60 MiB 以内的照片');
    }
    final contentType = _contentType(file.path);
    final prepared = await _prepare(
      file.path,
      requestId,
      size,
      sha256,
      captureMetadata,
    );
    final preparedStatus = _status(prepared, allowFailed: true);
    if (preparedStatus == 'FAILED' &&
        prepared['errorCode'] == 'INGEST_FAILED') {
      return _confirm(requestId);
    }
    if (preparedStatus == 'FAILED') throw StateError(_error(prepared));
    if (preparedStatus != 'AWAITING_UPLOAD') {
      return preparedStatus;
    }
    if (recover) {
      final existing = await _confirm(requestId);
      if (existing != 'AWAITING_UPLOAD') return existing;
    }
    final url = Uri.tryParse(prepared['uploadUrl'] as String? ?? '');
    final headers = prepared['uploadHeaders'];
    if (url == null ||
        url.scheme != 'https' ||
        url.userInfo.isNotEmpty ||
        !url.host.endsWith('.myqcloud.com') ||
        headers is! Map ||
        headers['Content-Length'] != size.toString() ||
        headers['Content-Type'] != contentType ||
        headers['x-cos-forbid-overwrite'] != 'true' ||
        headers['x-cos-acl'] != 'private') {
      throw StateError('服务端返回的 COS 上传授权不合法');
    }
    final request = await _http.putUrl(url);
    request.followRedirects = false;
    request.contentLength = size;
    request.headers.set(HttpHeaders.contentTypeHeader, contentType);
    request.headers.set('x-cos-forbid-overwrite', 'true');
    request.headers.set('x-cos-acl', 'private');
    try {
      var sent = 0;
      await request
          .addStream(
            file.openRead().map((chunk) {
              sent += chunk.length;
              onProgress(sent / size);
              return chunk;
            }),
          )
          .timeout(const Duration(minutes: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      await response.drain<void>().timeout(const Duration(seconds: 15));
      // 409 表示同一会话的 PUT 已存在，由确认和后端摘要校验决定结果。
      if (response.statusCode != 200 && response.statusCode != 409) {
        throw StateError('COS 写入失败（HTTP ${response.statusCode}）');
      }
    } catch (_) {
      request.abort();
      rethrow;
    }
    final confirmed = await _confirm(requestId);
    if (confirmed == 'AWAITING_UPLOAD') {
      throw StateError('COS 尚未确认收到完整照片，等待重试');
    }
    return confirmed;
  }

  Future<void> reportEnding(String requestId, String cardSecret) async {
    final data = await _request('POST', '', {
      'requestId': requestId,
      'cardSecret': cardSecret,
    }, '/batch-notices');
    if (!const {
      'UPLOADING',
      'READY',
      'NEEDS_ATTENTION',
      'ALREADY_INGESTED',
    }.contains(data['status'])) {
      throw StateError('服务端返回的结束照上报状态无效');
    }
  }

  Future<Map<String, dynamic>> _prepare(
    String path,
    String requestId,
    int byteLength,
    String digest,
    CameraMetadata? captureMetadata, {
    String? cardTailHint,
  }) => _request('POST', '', {
    'requestId': requestId,
    'byteLength': byteLength,
    'sha256': digest,
    'contentType': _contentType(path),
    if (captureMetadata != null) 'captureMetadata': captureMetadata.toJson(),
    'cardTailHint': ?cardTailHint,
  });

  String _contentType(String path) =>
      p.extension(path).toLowerCase() == '.png' ? 'image/png' : 'image/jpeg';

  /// Attach the OCR candidate to the same upload session, even after ingest.
  Future<void> reportCardTail(
    String path,
    String requestId,
    int byteLength,
    String digest,
    CameraMetadata? captureMetadata,
    String tail,
  ) async {
    final data = await _prepare(
      path,
      requestId,
      byteLength,
      digest,
      captureMetadata,
      cardTailHint: tail,
    );
    _status(data, allowFailed: true);
    if (data['cardTailHint'] != tail) {
      throw StateError('服务端未确认收到 OCR 候选尾号');
    }
  }

  Future<({String status, String error})> status(String requestId) async {
    final data = await _request('GET', '/$requestId');
    return (status: _status(data, allowFailed: true), error: _error(data));
  }

  String _error(Map<String, dynamic> data) =>
      data['errorCode'] == 'INVALID_IMAGE_OR_DIGEST'
      ? '照片内容不合法或校验失败'
      : '服务端入库失败，请重试或联系运营';

  Future<String> _confirm(String requestId) async =>
      _status(await _request('POST', '/$requestId/confirm'));

  String _status(Map<String, dynamic> data, {bool allowFailed = false}) {
    final status = data['status'];
    switch (status) {
      case 'AWAITING_UPLOAD':
      case 'QUEUED':
      case 'PROCESSING':
      case 'INGESTED':
      case 'GROUPED':
        return status as String;
      case 'FAILED':
        if (allowFailed) return 'FAILED';
        throw StateError(_error(data));
      default:
        throw StateError('服务端返回的上传状态无效');
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String suffix, [
    Map<String, Object>? body,
    String route = '/sessions',
  ]) async {
    final uri = profile.api.replace(
      path:
          '/api/operation/workstation-upload/stations/'
          '${profile.stationId}$route$suffix',
    );
    final request = await _http.openUrl(method, uri);
    request.followRedirects = false;
    request.headers.set('X-Workstation-Token', profile.token);
    if (method == 'POST' && suffix.isEmpty && personnelToken != null) {
      final token = personnelToken!();
      if (token == null) {
        request.abort();
        throw CosUploadAuthorizationError('请重新登录后继续接收照片');
      }
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        request.abort();
        throw StateError('工作台上传服务请求超时');
      },
    );
    if (response.statusCode != 200) {
      await response.drain<void>().timeout(const Duration(seconds: 10));
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw CosUploadAuthorizationError(
          personnelToken == null
              ? '机位收图授权已失效或停用，请联系运营'
              : '当前账号或机位的收图授权无法使用，请返回工作台核对',
        );
      }
      throw StateError('工作台上传服务请求失败（HTTP ${response.statusCode}）');
    }
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 10));
    final result = jsonDecode(text);
    if (result is Map && const {40101, 40102, 40301}.contains(result['code'])) {
      throw CosUploadAuthorizationError(
        personnelToken == null
            ? '机位收图授权已失效或停用，请联系运营'
            : '当前账号或机位的收图授权无法使用，请返回工作台核对',
      );
    }
    if (result is! Map || result['code'] != 200 || result['data'] is! Map) {
      throw StateError('工作台上传服务拒绝请求，请检查机位权限和服务配置');
    }
    return Map<String, dynamic>.from(result['data'] as Map);
  }

  void close() => _http.close(force: true);
}
