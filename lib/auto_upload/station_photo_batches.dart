import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../workstation_result_error.dart';
import 'cos_upload.dart';

class StationPhotoBatches {
  const StationPhotoBatches(this.client, this.profile, this.personnelToken);

  final http.Client client;
  final CosUploadProfile profile;
  final String? Function()? personnelToken;

  Future<Map<String, dynamic>> call(String method, List<dynamic> args) async {
    final scope = args.first;
    final stationId = scope is Map ? scope['stationId'] : scope;
    if (stationId != profile.stationId) {
      throw StateError('照片批次不属于当前机位，请刷新');
    }
    final (verb, path, query, body) = switch (method) {
      'listPhotoBatches' => ('GET', '', _range(scope), null),
      'getBatchPhotoCapture' => (
        'GET',
        '${_photoPath(args[1])}/capture',
        null,
        null,
      ),
      'previewPhotoBatchSplit' => (
        'GET',
        '/split-preview',
        {
          ..._range(scope),
          'beforePhotoId': scope['beforePhotoId'] as String,
          'afterPhotoId': scope['afterPhotoId'] as String,
        },
        null,
      ),
      'savePhotoBatchSplit' => ('POST', '/splits', _range(scope), args[1]),
      'movePhotoBatchPhoto' => ('POST', '/moves', _range(scope), args[1]),
      'correctPhotoBatch' => ('POST', '/corrections', null, args[1]),
      'removePhotoBatch' => ('POST', '/removals', _range(scope), args[1]),
      'removeBatchPhoto' => (
        'POST',
        '${_photoPath(args[1])}/removals',
        null,
        args[2],
      ),
      _ => throw StateError('不支持此照片批次操作'),
    };
    final request = http.Request(
      verb,
      profile.api.replace(
        path:
            '/api/operation/workstation-upload/stations/'
            '${profile.stationId}/photo-batches$path',
        queryParameters: query,
      ),
    )..followRedirects = false;
    request.headers['X-Workstation-Token'] = profile.token;
    if (personnelToken != null) {
      final token = personnelToken!();
      if (token == null) throw StateError('请重新登录后查看或操作照片批次');
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(Duration(seconds: verb == 'POST' ? 120 : 30));
    } on TimeoutException {
      throw StateError('照片批次请求超时，请刷新核对结果');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw WorkstationResultError(
        '当前账号或机位的照片批次授权无法使用',
        response.statusCode == 401 ? 40101 : 40301,
      );
    }
    if (response.statusCode != 200) {
      throw StateError('照片批次请求失败（HTTP ${response.statusCode}）');
    }
    final Object? result;
    try {
      result = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw StateError('照片批次响应格式无效');
    }
    if (result is! Map) throw StateError('照片批次响应格式无效');
    final code = result['code'];
    if (code is! int) throw StateError('照片批次响应缺少业务状态');
    if (code != 200) {
      final message = result['message'];
      throw WorkstationResultError(
        message is String && message.isNotEmpty ? message : '照片批次请求失败',
        code,
      );
    }
    final data = result['data'];
    if (data is! Map<String, dynamic>) throw StateError('照片批次响应缺少结果');
    return data;
  }

  Map<String, String> _range(dynamic scope) => {
    'from': scope['from'] as String,
    'to': scope['to'] as String,
  };

  String _photoPath(dynamic photoId) {
    if (photoId is! String || !RegExp(r'^[1-9][0-9]*$').hasMatch(photoId)) {
      throw StateError('照片编号无效');
    }
    return '/photos/$photoId';
  }
}
