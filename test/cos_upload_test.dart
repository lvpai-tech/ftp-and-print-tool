import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/auto_upload/cos_upload.dart';
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
}

// Keeps the real Dart HTTP stream behavior and maps the two endpoints to a local fixture.
class _LocalTransport implements HttpClient {
  final HttpClient transport;
  final int port;
  final hosts = <String>[];

  _LocalTransport(this.transport, this.port);

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
  void close({bool force = false}) => transport.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
