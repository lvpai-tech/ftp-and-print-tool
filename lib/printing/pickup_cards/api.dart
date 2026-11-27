import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../workstation_account.dart';

enum PickupFormat {
  pdf('PDF', 'pdf'),
  excel('EXCEL', 'xlsx');

  const PickupFormat(this.code, this.extension);
  final String code, extension;
}

class PickupExportRequest {
  PickupExportRequest(this.quantity, this.codesOnly, this.format)
    : id = List.generate(
        16,
        (_) => _random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  PickupExportRequest.restore(String saved)
    : this._fromJson(jsonDecode(saved) as Map<String, dynamic>);

  PickupExportRequest._fromJson(Map<String, dynamic> json)
    : quantity = json['quantity'] as int,
      codesOnly = json['codesOnly'] as bool,
      format = _format(json['format']),
      id = json['requestId'] as String;

  static final _random = Random.secure();
  final int quantity;
  final bool codesOnly;
  final PickupFormat format;
  final String id;

  Map<String, Object> get fields => {
    'quantity': quantity,
    'codesOnly': codesOnly,
    'format': format.code,
    'requestId': id,
  };
}

PickupFormat _format(Object? value) =>
    PickupFormat.values.firstWhere((format) => format.code == value);

class PickupExport {
  PickupExport.fromJson(Map<String, dynamic> json)
    : this._fromSummary(json, json['export'] as Map<String, dynamic>);

  PickupExport._fromSummary(
    Map<String, dynamic> batch,
    Map<String, dynamic> summary,
  ) : batchNo = batch['batchNo'] as String,
      quantity = batch['quantity'] as int,
      format = _format(summary['format']),
      status = summary['status'] as String,
      prepared = summary['prepared'] as int,
      completedParts = summary['completedParts'] as int,
      partCount = summary['partCount'] as int,
      error = summary['errorMessage'] as String?;

  final String batchNo, status;
  final PickupFormat format;
  final int quantity, prepared, completedParts, partCount;
  final String? error;

  String get route => '/${Uri.encodeComponent(batchNo)}/${format.code}';
  bool get ready => status == 'READY';
  bool get retryable => status == 'FAILED' || status == 'EXPIRED';
  bool get active => const {'QUEUED', 'RUNNING', 'RETRY_WAIT'}.contains(status);

  String get statusLabel => switch (status) {
    'QUEUED' => '排队中',
    'RUNNING' => '处理中 · $prepared/$quantity 张 · $completedParts/$partCount 卷',
    'RETRY_WAIT' => '后台等待重试',
    'READY' => '可下载',
    'FAILED' => '生成失败',
    'EXPIRED' => '文件已过期',
    _ => '无法识别导出状态',
  };
}

class PickupFile {
  PickupFile.fromJson(Map<String, dynamic> json)
    : part = json['partNo'] as int,
      name = json['fileName'] as String,
      size = json['sizeBytes'] as int {
    if (part < 0 ||
        size <= 0 ||
        name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains(RegExp(r'[\\/:*?"<>|\x00-\x1f]'))) {
      throw const FormatException('后台返回了无效的取片卡文件信息');
    }
  }

  final int part, size;
  final String name;
}

class PickupCardsApi {
  PickupCardsApi(this.account, this.userId, this.scenicId);

  final WorkstationAccount account;
  final String userId, scenicId;

  Future<PickupExportRequest?> restorePending() async {
    final saved = await account.pendingPickupExport(userId, scenicId);
    return saved == null ? null : PickupExportRequest.restore(saved);
  }

  Future<void> remember(PickupExportRequest? request) =>
      account.rememberPickupExport(
        userId,
        scenicId,
        request == null ? null : jsonEncode(request.fields),
      );

  Future<List<PickupExport>> recent() async {
    final result = await account.requestPickupCards(scenicId, '');
    return (result['exports'] as List)
        .cast<Map<String, dynamic>>()
        .map(PickupExport.fromJson)
        .toList();
  }

  Future<PickupExport> submit(PickupExportRequest request) async =>
      PickupExport.fromJson(
        await account.requestPickupCards(
          scenicId,
          '',
          body: {'scenicId': scenicId, ...request.fields},
          post: true,
        ),
      );

  Future<PickupExport> retry(PickupExport batch) async => PickupExport.fromJson(
    await account.requestPickupCards(scenicId, batch.route, post: true),
  );

  Future<List<PickupFile>> files(PickupExport batch) async {
    final result = await account.requestPickupCards(scenicId, batch.route);
    if (!PickupExport.fromJson(result).ready) {
      throw StateError('文件仍在生成或已过期，请刷新导出记录');
    }
    final files = (result['files'] as List)
        .cast<Map<String, dynamic>>()
        .map(PickupFile.fromJson)
        .toList();
    if (files.isEmpty) throw StateError('后台未返回取片卡文件');
    return files;
  }

  Future<void> download(
    PickupExport batch,
    PickupFile file,
    File target,
  ) async {
    final signed = await account.requestPickupCards(
      scenicId,
      '${batch.route}/files/${file.part}',
    );
    final uri = Uri.tryParse(signed['url'] as String? ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw StateError('后台未返回有效的取片卡下载地址');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('文件下载失败（HTTP ${response.statusCode}），请重试');
      }
      final sink = target.openWrite();
      var received = 0;
      try {
        await sink.addStream(
          response.timeout(const Duration(seconds: 30)).map((chunk) {
            received += chunk.length;
            if (received > file.size) throw StateError('下载的文件超过预期大小');
            return chunk;
          }),
        );
      } finally {
        await sink.close();
      }
      if (received != file.size) throw StateError('文件下载不完整，请重试');
    } on IOException {
      throw StateError('无法下载或保存取片卡文件，请检查网络和保存位置');
    } on TimeoutException {
      throw StateError('下载取片卡文件超时，请重试');
    } finally {
      client.close(force: true);
    }
  }
}
