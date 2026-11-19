import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lvpai_ftp_client/release/update_service.dart';

Map<String, dynamic> manifest(List<int> bytes) => {
  'versionCode': 3,
  'versionName': '0.3.0',
  'platform': 'windows-x64',
  'channel': 'prd',
  'installerUrl':
      '$releaseOrigin/ftp-client/prd/windows-x64/lvpai-ftp-0.3.0-3-windows-x64.zip',
  'sha256': sha256.convert(bytes).toString(),
  'sizeBytes': bytes.length,
};

void main() {
  test('版本清单拒绝跨环境/平台、缺失校验、任意网址及路径绕过', () {
    final valid = manifest([1, 2, 3]);
    expect(ReleaseManifest.parse(valid, 'windows-x64', 'prd').code, 3);
    for (final patch in [
      {'channel': 'test'},
      {'platform': 'macos-arm64'},
      {'sha256': ''},
      {'sizeBytes': 0},
      {'versionCode': 3.0},
      {'versionName': '<script>'},
      {'installerUrl': '${valid['installerUrl']}?url=https://evil.example'},
      {
        'installerUrl':
            '$releaseOrigin/ftp-client/prd/windows-x64/../malware.zip',
      },
      {
        'installerUrl':
            'https://evil.example/ftp-client/prd/windows-x64/lvpai-ftp-0.3.0-3-windows-x64.zip',
      },
    ]) {
      expect(
        () => ReleaseManifest.parse({...valid, ...patch}, 'windows-x64', 'prd'),
        throwsStateError,
      );
    }
  });

  test('iOS 只接受官方商店应用或邀请入口，不允许伪造域名、查询或跳转', () {
    for (final url in [
      'https://apps.apple.com/cn/app/name/id123456',
      'https://testflight.apple.com/join/Ab12Cd34',
    ]) {
      expect(ReleaseManifest.validStoreUrl(url), isTrue);
    }
    for (final url in [
      'https://apps.apple.com.evil.example/cn/app/id123',
      'https://apps.apple.com@evil.example/app/id123',
      'http://testflight.apple.com/join/Ab12Cd34',
      'https://testflight.apple.com/join/Ab12Cd34?next=evil',
      'https://apps.apple.com/app/id123#x',
      'https://apps.apple.com:443/app/id123',
      'file:///package.ipa',
    ]) {
      expect(ReleaseManifest.validStoreUrl(url), isFalse, reason: url);
    }
    final release = ReleaseManifest.parse(
      {
        'platform': 'ios',
        'channel': 'prd',
        'versionCode': 3,
        'versionName': '0.3.0',
        'storeUrl': 'https://apps.apple.com/app/id123',
      },
      'ios',
      'prd',
    );
    expect(release.url.host, 'apps.apple.com');
  });

  test('读取真实协议URL，禁跟随重定向，404明确未发布', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        '$releaseOrigin/ftp-client/test/windows-x64/latest.json',
      );
      expect(request.followRedirects, isFalse);
      return http.Response('', 404);
    });
    final service = UpdateService(
      client: client,
      platform: 'windows-x64',
      channel: 'test',
    );
    addTearDown(service.close);
    await expectLater(
      service.check(),
      throwsA(
        isA<StateError>().having((e) => e.message, '原因', contains('尚未发布')),
      ),
    );
  });

  test('受控HTTPS适配器：下载完整字节校验后才生成正式更新文件', () async {
    final bytes = utf8.encode('controlled release package');
    final data = manifest(bytes);
    final temp = await Directory.systemTemp.createTemp('ftp-update-test-');
    addTearDown(() => temp.delete(recursive: true));
    final service = UpdateService(
      platform: 'windows-x64',
      client: MockClient(
        (request) async => request.url.path.endsWith('latest.json')
            ? http.Response(jsonEncode(data), 200)
            : http.Response.bytes(bytes, 200),
      ),
    );
    addTearDown(service.close);
    final release = await service.check();
    final file = await service.download(release, temp, (_) {});
    expect(await file.readAsBytes(), bytes);
    expect(file.path, endsWith('.zip'));
  });

  test('摘要错误/截断/超长/重定向全部拒绝并清理下载，不留可打开文件', () async {
    final temp = await Directory.systemTemp.createTemp('ftp-update-reject-');
    addTearDown(() => temp.delete(recursive: true));
    final release = ReleaseManifest.parse(
      manifest([1, 2, 3]),
      'windows-x64',
      'prd',
    );
    for (final response in [
      http.Response.bytes([3, 2, 1], 200),
      http.Response.bytes([1], 200),
      http.Response.bytes([1, 2, 3, 4], 200),
      http.Response('', 302, headers: {'location': 'https://evil.example'}),
    ]) {
      final service = UpdateService(
        platform: 'windows-x64',
        client: MockClient((_) async => response),
      );
      await expectLater(
        service.download(release, temp, (_) {}),
        throwsStateError,
      );
      expect(await temp.list().toList(), isEmpty);
      service.close();
    }
  });

  test('损坏和过大的清单不显示可用更新', () async {
    for (final body in ['not json', '[]', 'x' * 17000]) {
      final service = UpdateService(
        platform: 'windows-x64',
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        service.check(),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      service.close();
    }
  });
}
