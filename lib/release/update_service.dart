import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

const updateChannel = String.fromEnvironment(
  'LVPAI_UPDATE_ENV',
  defaultValue: 'prd',
);
const releaseOrigin = 'https://cdn.hilvpai.com';
const maxReleaseBytes = 512 * 1024 * 1024;

/// 清单必须匹配构建通道、当前平台和正式 CDN；链接不允许跳转到任意域名。
class ReleaseManifest {
  final int code;
  final String version, platform, channel, sha256Hex;
  final int size;
  final Uri url;
  ReleaseManifest._(
    this.code,
    this.version,
    this.platform,
    this.channel,
    this.url,
    this.sha256Hex,
    this.size,
  );

  factory ReleaseManifest.parse(
    Map<String, dynamic> data,
    String platform,
    String channel,
  ) {
    validateChannel(channel);
    final code = data['versionCode'];
    final version = data['versionName'];
    if (data['platform'] != platform ||
        data['channel'] != channel ||
        code is! int ||
        code < 1 ||
        code > 2000000000 ||
        version is! String ||
        !RegExp(r'^[0-9A-Za-z][0-9A-Za-z._-]{0,31}$').hasMatch(version)) {
      throw StateError('版本清单字段、平台或环境不匹配');
    }
    if (platform == 'ios') {
      final value = data['storeUrl'];
      if (value is! String || !validStoreUrl(value)) {
        throw StateError('苹果安装链接无效');
      }
      return ReleaseManifest._(
        code,
        version,
        platform,
        channel,
        Uri.parse(value),
        '',
        0,
      );
    }
    final extension = switch (platform) {
      'windows-x64' => '.zip',
      'macos-arm64' || 'macos-x64' => '.dmg',
      _ => throw StateError('当前平台暂无更新通道'),
    };
    final sha = data['sha256'];
    final size = data['sizeBytes'];
    final value = data['installerUrl'];
    final expected =
        '$releaseOrigin/ftp-client/$channel/$platform/'
        'lvpai-ftp-$version-$code-$platform$extension';
    if (sha is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ||
        size is! int ||
        size < 1 ||
        size > maxReleaseBytes ||
        value != expected) {
      throw StateError('安装包地址、大小或SHA-256不合法');
    }
    return ReleaseManifest._(
      code,
      version,
      platform,
      channel,
      Uri.parse(expected),
      sha,
      size,
    );
  }

  static void validateChannel(String channel) {
    if (!['local', 'test', 'prd'].contains(channel)) {
      throw StateError('更新通道配置无效');
    }
  }

  static bool validStoreUrl(String value) {
    if (!RegExp(
      r'^https://(?:testflight\.apple\.com/join/[A-Za-z0-9]{8}|apps\.apple\.com/(?:[a-z]{2}/)?app/(?:[A-Za-z0-9%._~-]+/)?id[0-9]+)$',
    ).hasMatch(value)) {
      return false;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    return (uri.host == 'testflight.apple.com' &&
            RegExp(r'^/join/[A-Za-z0-9]{8}$').hasMatch(uri.path)) ||
        (uri.host == 'apps.apple.com' &&
            RegExp(
              r'^/(?:[a-z]{2}/)?app/(?:[A-Za-z0-9%._~-]+/)?id[0-9]+$',
            ).hasMatch(uri.path));
  }
}

class UpdateService {
  final http.Client client;
  final String platform, channel;
  UpdateService({
    http.Client? client,
    String? platform,
    this.channel = updateChannel,
  }) : client = client ?? http.Client(),
       platform = platform ?? currentPlatform();

  static String currentPlatform() {
    if (Platform.isIOS) return 'ios';
    return switch (Abi.current()) {
      Abi.windowsX64 => 'windows-x64',
      Abi.macosArm64 => 'macos-arm64',
      Abi.macosX64 => 'macos-x64',
      _ => throw StateError('当前平台暂无更新通道'),
    };
  }

  Future<http.StreamedResponse> _get(Uri uri) => client
      .send(
        http.Request('GET', uri)
          ..followRedirects = false
          ..headers['Cache-Control'] = 'no-cache',
      )
      .timeout(const Duration(seconds: 15));

  Future<ReleaseManifest> check() async {
    ReleaseManifest.validateChannel(channel);
    final response = await _get(
      Uri.parse('$releaseOrigin/ftp-client/$channel/$platform/latest.json'),
    );
    if (response.statusCode == 404) throw StateError('当前平台尚未发布版本');
    if (response.statusCode != 200) throw StateError('版本清单读取失败，请稍后重试');
    final bytes = BytesBuilder();
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (bytes.length + chunk.length > 16384) throw StateError('版本清单过大，已拒绝');
      bytes.add(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (data is! Map<String, dynamic>) throw StateError('版本清单格式错误');
    return ReleaseManifest.parse(data, platform, channel);
  }

  /// 下载到应用私有缓存，大小及SHA-256均通过后才提供打开入口。
  Future<File> download(
    ReleaseManifest release,
    Directory cache,
    void Function(double) progress,
  ) async {
    if (release.platform == 'ios' ||
        release.platform != platform ||
        release.channel != channel) {
      throw StateError('安装包与当前平台或环境不匹配');
    }
    await cache.create(recursive: true);
    final directory = await cache.createTemp('ftp-update-');
    try {
      final response = await _get(release.url);
      if (response.statusCode != 200) throw StateError('下载失败，请稍后重试');
      if (response.contentLength != null &&
          response.contentLength != release.size) {
        throw StateError('下载文件大小与清单不一致');
      }
      final part = File(p.join(directory.path, 'package.part'));
      final writer = await part.open(mode: FileMode.write);
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (received > release.size) throw StateError('下载文件超出清单大小，已停止');
          await writer.writeFrom(chunk);
          progress(received / release.size);
        }
        await writer.flush();
      } finally {
        await writer.close();
      }
      if (received != release.size ||
          (await sha256.bind(part.openRead()).first).toString() !=
              release.sha256Hex) {
        throw StateError('安装包完整性校验失败，已删除下载文件');
      }
      return await part.rename(
        p.join(directory.path, p.posix.basename(release.url.path)),
      );
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  void close() => client.close();
}
