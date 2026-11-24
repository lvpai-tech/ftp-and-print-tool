import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lvpai_ftp_client/auto_upload/workstation_enrollment.dart';
import 'package:lvpai_ftp_client/printing/print_enrollment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('激活响应中断后从安全存储恢复并沿用设备凭据', () async {
    const scenic = EnrollmentScenic('5', '测试景区');
    const route = '/api/operation/print-workstation-enrollment/applications';
    late Map<String, dynamic> draft;
    var status = 'PENDING';
    final activationTokens = <String>[];
    final client = MockClient((request) async {
      expect(
        request.headers['x-print-enrollment-token'],
        draft['requestToken'],
      );
      final path = request.url.path;
      if (path == route) {
        expect(request.method, 'POST');
        expect(
          jsonDecode(request.body),
          containsPair('requestId', draft['id']),
        );
        expect(request.headers['x-print-agent-token'], isNull);
      } else if (path == '$route/${draft['id']}') {
        expect(request.method, 'GET');
        expect(request.headers['x-print-agent-token'], isNull);
      } else {
        expect(path, '$route/${draft['id']}/activate');
        final token = request.headers['x-print-agent-token']!;
        expect((await PrintEnrollment.credentials())[draft['id']], token);
        expect(token, isNot(draft['requestToken']));
        activationTokens.add(token);
        status = 'ACTIVATED';
        if (activationTokens.length == 1) throw http.ClientException('断线');
      }
      return http.Response(
        jsonEncode({
          'code': 200,
          'data': {'id': draft['id'], 'status': status, 'scenicId': scenic.id},
        }),
        200,
      );
    });
    addTearDown(client.close);
    final enrollment = PrintEnrollment(client);
    draft = await enrollment.begin(scenic, '前台');
    var installations = 0;
    Future<void> install(String id, String token, String scenicId) async {
      expect(id, draft['id']);
      expect(scenicId, scenic.id);
      expect(token, activationTokens.singleOrNull ?? activationTokens.first);
      installations++;
    }

    await enrollment.refresh(draft, install);
    expect(draft['status'], 'PENDING');
    status = 'APPROVED';
    await expectLater(
      enrollment.refresh(draft, install),
      throwsA(isA<http.ClientException>()),
    );
    expect(installations, 0);
    final restored = (await PrintEnrollment.records()).single;
    expect(restored['status'], 'APPROVED');
    await enrollment.refresh(restored, install);
    expect(activationTokens, hasLength(2));
    expect(activationTokens.toSet(), hasLength(1));
    expect(installations, 1);
    expect((await PrintEnrollment.records()).single['status'], 'ACTIVATED');
  });
}
