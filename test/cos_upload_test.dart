import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/auto_upload/cos_upload.dart';
import 'package:lvpai_ftp_client/auto_upload/folder_uploader.dart';
import 'package:path/path.dart' as p;

void main() {
  final token = 'a' * 64;
  final requestId = 'b' * 64;
  const api = 'https://workstation.example';
  const stagingUrl = 'https://private.cos.ap-guangzhou.myqcloud.com/sample';

  test(
    'workstation profile validates origin and keeps queue identity across token rotation',
    () {
      final profile = CosUploadProfile(api, '19', token);
      expect(
        CosUploadProfile.fromJson(profile.toJson()).queueTarget,
        '$api/19',
      );
      expect(
        CosUploadProfile(api, '19', 'c' * 64).queueTarget,
        profile.queueTarget,
      );
      expect(
        () => CosUploadProfile('http://workstation.example', '19', token),
        throwsStateError,
      );
      expect(
        () => CosUploadProfile('$api/other', '19', token),
        throwsStateError,
      );
      expect(() => CosUploadProfile(api, '0', token), throwsStateError);
    },
  );

  test(
    'PUT streams the exact bytes without the workstation token and retry confirms existing upload',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transport = HttpClient();
      final local = _LocalTransport(transport, server.port);
      final scratch = await Directory.systemTemp.createTemp(
        'workstation-upload-test',
      );
      addTearDown(() async {
        transport.close(force: true);
        await server.close(force: true);
        await scratch.delete(recursive: true);
      });
      final file = File(p.join(scratch.path, 'raw.jpg'));
      final bytes = List<int>.generate(128 * 1024, (index) => index % 256);
      await file.writeAsBytes(bytes);
      var putCount = 0;
      var confirmCount = 0;
      final failures = <String>[];
      server.listen((request) async {
        final response = request.response;
        if (request.method == 'PUT') {
          putCount++;
          if (request.headers.value('X-Workstation-Token') != null) {
            failures.add('workstation token was sent to COS');
          }
          if (request.headers.value('x-cos-forbid-overwrite') != 'true' ||
              request.headers.value('x-cos-acl') != 'private' ||
              request.contentLength != bytes.length) {
            failures.add('required signed headers missing');
          }
          final received = await request.expand((c) => c).toList();
          if (received.length != bytes.length ||
              Iterable<int>.generate(
                bytes.length,
              ).any((i) => received[i] != bytes[i])) {
            failures.add('body differs');
          }
          response.statusCode = putCount == 1 ? 200 : 409;
          await response.close();
          return;
        }
        if (request.headers.value('X-Workstation-Token') != token) {
          failures.add('authorization missing from business request');
        }
        final Map<String, Object> data;
        if (request.uri.path.endsWith('/confirm')) {
          confirmCount++;
          if (confirmCount == 1) {
            // Simulate the upload succeeding while its first business confirmation fails.
            response.statusCode = 503;
            await response.close();
            return;
          }
          data = {'status': 'QUEUED'};
        } else if (request.method == 'GET') {
          data = {'status': 'GROUPED'};
        } else {
          final requestData =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          if (requestData['requestId'] != requestId) {
            failures.add('request identity changed');
          }
          data = {
            'status': 'AWAITING_UPLOAD',
            'uploadUrl': stagingUrl,
            'uploadHeaders': {
              'Content-Length': '${bytes.length}',
              'Content-Type': 'image/jpeg',
              'x-cos-forbid-overwrite': 'true',
              'x-cos-acl': 'private',
            },
          };
        }
        response.write(jsonEncode({'code': 200, 'data': data}));
        await response.close();
      });

      await HttpOverrides.runZoned(() async {
        final client = CosUpload(CosUploadProfile(api, '19', token));
        addTearDown(client.close);
        final progress = <double>[];
        await expectLater(
          client.upload(file, requestId, 'd' * 64, progress.add),
          throwsStateError,
        );
        expect(
          await client.upload(
            file,
            requestId,
            'd' * 64,
            progress.add,
            recover: true,
          ),
          'QUEUED',
        );
        expect((await client.status(requestId)).status, 'GROUPED');
        expect(progress.last, 1.0);
      }, createHttpClient: (_) => local);
      expect(failures, isEmpty);
      expect(putCount, 1);
      expect(confirmCount, 2);
      expect(
        local.hosts,
        containsAll(['workstation.example', Uri.parse(stagingUrl).host]),
      );
    },
  );

  test('慢写原片重启保序，重试和等待入库期间结束照不发送', () async {
    final fixture = await _QueueFixture.open();
    await fixture.run(() async {
      final uploader = fixture.uploader();
      final original = File(p.join(fixture.inbox.path, 'z-original.png'));
      final ending = File(p.join(fixture.inbox.path, 'a-ending.png'));
      await uploader.start(fixture.inbox, null, cosProfile: fixture.profile);
      await original.create();
      await _until(() => uploader.settling == 1, '发现原片');
      await ending.writeAsBytes(await _png());
      await _until(() => uploader.settling == 2, '发现结束照');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(fixture.prepared, isEmpty);
      expect(uploader.orderWaitMessage, contains('z-original.png'));

      await uploader.stop();
      await uploader.start(fixture.inbox, null, cosProfile: fixture.profile);
      await original.delete();
      await _until(
        () => uploader.orderWaitMessage?.contains('请将原片放回') == true,
        '提示队首原片移走',
      );
      expect(fixture.prepared, isEmpty);
      fixture.failNextUpload = true;
      await original.writeAsBytes(await _png());
      await _until(
        () => uploader.jobs.any((job) => job.error.isNotEmpty),
        '首次传输失败并准备重试',
        describe: () =>
            '${uploader.issues} ${uploader.fatalError} ${fixture.prepared}',
      );
      final originalJob = uploader.jobs.singleWhere(
        (job) => job.source == original.path,
      );
      expect(fixture.prepared.toSet(), {originalJob.id});
      expect(uploader.orderWaitMessage, contains('等待重试'));

      await _until(
        () => originalJob.state == 'accepted',
        '原片 COS 受理',
        describe: () => '${originalJob.state} ${originalJob.error}',
      );
      await _until(
        () => fixture.statusQueries.contains(originalJob.id),
        '开始查询入库',
      );
      expect(fixture.prepared.toSet(), {originalJob.id});
      expect(uploader.orderWaitMessage, contains('等待服务端入库'));

      fixture.ingested.add(originalJob.id);
      await _until(() => fixture.prepared.toSet().length == 2, '放行结束照');
      expect(originalJob.state, 'ingested');
      expect(
        fixture.prepared.last,
        uploader.jobs.singleWhere((job) => job.source == ending.path).id,
      );
      await _until(() => fixture.uploaded.length == 2, '结束照上传成功');
    });
  });

  test('同次补扫没有发现顺序时须确认，确认结果重启后保留', () async {
    final fixture = await _QueueFixture.open();
    await fixture.run(() async {
      final uploader = fixture.uploader();
      final original = File(p.join(fixture.inbox.path, 'z-original.png'));
      final ending = File(p.join(fixture.inbox.path, 'a-ending.png'));
      await original.create();
      await ending.writeAsBytes(await _png());
      await uploader.start(
        fixture.inbox,
        null,
        cosProfile: fixture.profile,
        includeExisting: true,
      );
      expect(uploader.sourcesNeedingOrder.toSet(), {
        original.path,
        ending.path,
      });
      expect(fixture.prepared, isEmpty);
      uploader.confirmNextSource(original.path);
      await _until(
        () => uploader.orderWaitMessage?.contains('z-original.png') == true,
        '确认原片优先',
      );
      await uploader.stop();
      await uploader.start(
        fixture.inbox,
        null,
        cosProfile: fixture.profile,
        includeExisting: true,
      );
      expect(uploader.sourcesNeedingOrder, isEmpty);
      expect(uploader.orderWaitMessage, contains('z-original.png'));
      expect(fixture.prepared, isEmpty);
    });
  });
}

Future<void> _until(
  bool Function() condition,
  String description, {
  String Function()? describe,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待$description超时 ${describe?.call() ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<List<int>> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(12, 12);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

class _QueueFixture {
  final HttpServer server;
  final Directory scratch, inbox;
  final transport = HttpClient();
  final prepared = <String>[];
  final uploaded = <String>{};
  final ingested = <String>{};
  final statusQueries = <String>{};
  final profile = CosUploadProfile(
    'https://workstation.example',
    '19',
    'a' * 64,
  );
  bool failNextUpload = false;

  _QueueFixture(this.server, this.scratch, this.inbox);

  static Future<_QueueFixture> open() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final scratch = await Directory.systemTemp.createTemp('workstation-queue-');
    final inbox = await Directory(p.join(scratch.path, 'inbox')).create();
    final fixture = _QueueFixture(server, scratch, inbox);
    server.listen(fixture._handle);
    addTearDown(() async {
      fixture.transport.close(force: true);
      await server.close(force: true);
      await scratch.delete(recursive: true);
    });
    return fixture;
  }

  Future<void> run(Future<void> Function() body) => HttpOverrides.runZoned(
    body,
    createHttpClient: (_) =>
        _LocalTransport(transport, server.port, closeTransport: false),
  );

  FolderUploader uploader() {
    final uploader = FolderUploader(
      storage: Directory(p.join(scratch.path, 'state')),
      stableFor: const Duration(milliseconds: 80),
      scanInterval: const Duration(milliseconds: 30),
      retryDelay: const Duration(milliseconds: 300),
    );
    addTearDown(() async {
      await uploader.stop();
      uploader.dispose();
    });
    return uploader;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.method == 'PUT') {
      await request.drain<void>();
      if (failNextUpload) {
        failNextUpload = false;
        response.statusCode = 503;
      } else {
        uploaded.add(request.uri.pathSegments.last);
      }
      await response.close();
      return;
    }

    final path = request.uri.path;
    final Map<String, Object> data;
    if (path.endsWith('/sessions')) {
      final payload =
          jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final id = payload['requestId'] as String;
      prepared.add(id);
      data = {
        'status': 'AWAITING_UPLOAD',
        'uploadUrl': 'https://private.cos.ap-guangzhou.myqcloud.com/$id',
        'uploadHeaders': {
          'Content-Length': '${payload['byteLength']}',
          'Content-Type': payload['contentType'],
          'x-cos-forbid-overwrite': 'true',
          'x-cos-acl': 'private',
        },
      };
    } else if (request.method == 'GET') {
      final id = request.uri.pathSegments.last;
      statusQueries.add(id);
      data = {'status': ingested.contains(id) ? 'INGESTED' : 'PROCESSING'};
    } else {
      final id = request.uri.pathSegments[request.uri.pathSegments.length - 2];
      data = {'status': uploaded.contains(id) ? 'QUEUED' : 'AWAITING_UPLOAD'};
    }
    response.write(jsonEncode({'code': 200, 'data': data}));
    await response.close();
  }
}

// Keeps the real Dart HTTP stream behavior and maps the two endpoints to a local fixture.
class _LocalTransport implements HttpClient {
  final HttpClient transport;
  final int port;
  final bool closeTransport;
  final hosts = <String>[];

  _LocalTransport(this.transport, this.port, {this.closeTransport = true});

  @override
  set connectionTimeout(Duration? timeout) =>
      transport.connectionTimeout = timeout;

  @override
  set idleTimeout(Duration timeout) => transport.idleTimeout = timeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    hosts.add(uri.host);
    return transport.openUrl(
      method,
      uri.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  void close({bool force = false}) {
    if (closeTransport) transport.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
