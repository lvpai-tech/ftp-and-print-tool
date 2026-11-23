import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lvpai_ftp_client/auto_upload/workstation_enrollment.dart';
import 'package:lvpai_ftp_client/profile_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const store = ProfileStore();
  final gateway = Uri.parse('https://upload.example');

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('提交响应丢失后，重启用同一编号、凭据和资料重试', () async {
    Map<String, dynamic>? original;
    String? secret;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final token = request.headers['x-workstation-enrollment-token'];
      expect(token, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(request.followRedirects, isFalse);
      if (original == null) {
        original = body;
        secret = token;
        throw http.ClientException('connection dropped');
      }
      expect(body, original);
      expect(token, secret);
      return result({'id': body['requestId'], 'status': 'PENDING'});
    });
    addTearDown(client.close);

    final first = WorkstationEnrollment(gateway, store, client);
    await expectLater(
      first.begin('测试景区', '观景台', null),
      throwsA(isA<http.ClientException>()),
    );
    final restarted = WorkstationEnrollment(gateway, store, client);
    expect((await restarted.refresh())?.status, 'PENDING');
    expect(await store.loadCos(), isNull);
  });

  test('保存待激活密钥后才切换，激活响应丢失后复用本机密钥', () async {
    var claims = 0;
    var activations = 0;
    var approved = false;
    late String id;
    final token = 'f' * 64;
    final binding = {
      'scenicId': '3',
      'scenicName': '测试景区',
      'stationId': '19',
      'stationName': '观景台',
      'stationCode': 'A01',
    };
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/applications')) {
        final draft = jsonDecode(request.body) as Map<String, dynamic>;
        id = draft['requestId'] as String;
        return result({'id': id, 'status': 'PENDING'});
      }
      if (request.url.path.endsWith('/claim')) {
        claims++;
        return result({'stationToken': token, 'binding': binding});
      }
      if (request.url.path.endsWith('/activate')) {
        expect(request.headers['x-workstation-token'], token);
        final local = await store.loadEnrollment();
        expect(local?['pending']['token'], token);
        expect(await store.loadCos(), isNull);
        if (++activations == 1) {
          throw http.ClientException('activation response dropped');
        }
        return result({'id': id, 'status': 'BOUND', 'binding': binding});
      }
      return result({
        'id': id,
        'status': activations == 1
            ? 'BOUND'
            : approved
            ? 'APPROVED'
            : 'PENDING',
        'binding': binding,
      });
    });
    addTearDown(client.close);

    final first = WorkstationEnrollment(gateway, store, client);
    await first.begin('测试景区', '观景台', 'A01');
    approved = true;
    await expectLater(first.refresh(), throwsA(isA<http.ClientException>()));
    final restarted = WorkstationEnrollment(gateway, store, client);
    expect((await restarted.refresh())?.status, 'BOUND');
    expect(claims, 1);
    expect(activations, 2);
    expect((await store.loadCos())?.scenicName, '测试景区');
    expect((await store.loadCos())?.stationId, '19');
    expect(await store.loadEnrollment(), isNull);
  });
}

http.Response result(Map<String, dynamic> data) => http.Response(
  jsonEncode({'code': 200, 'data': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
