import 'dart:io';
import 'dart:convert';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 一次连接的配置；密码仅由系统安全存储持久化。
class ServerProfile {
  final String name, host, user, password, directory;
  final int port;
  const ServerProfile({
    required this.name,
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.directory,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'host': host,
    'port': port,
    'user': user,
    'password': password,
    'directory': directory,
  };
  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
    name: json['name'] as String,
    host: json['host'] as String,
    port: json['port'] as int,
    user: json['user'] as String,
    password: json['password'] as String,
    directory: json['directory'] as String,
  );
}

/// 使用真实被动 FTP 连接，二进制传输，不记录认证命令。
class PhotoTransfer {
  final FTPConnect _client;
  PhotoTransfer(ServerProfile profile)
    : _client = FTPConnect(
        profile.host,
        port: profile.port,
        user: profile.user,
        pass: profile.password,
        timeout: 30,
        showLog: false,
        transferType: TransferType.binary,
      );

  Future<void> open(String directory) async {
    if (!await _client.connect()) throw StateError('FTP 登录失败');
    // ftpconnect.connect() 会把传输模式重置为 auto/ASCII；JPEG 等二进制必须再发 TYPE I。
    await _client.setTransferType(TransferType.binary);
    if (!await _client.changeDirectory(directory)) {
      throw StateError('目标目录不存在或无访问权限');
    }
  }

  Future<void> upload(File file, void Function(double) progress) async {
    final name = p.basename(file.path);
    if (name.contains('\r') || name.contains('\n')) {
      throw ArgumentError('文件名包含非法控制字符');
    }
    // 查询失败必须报错，不把网络异常或无权限当成文件不存在。
    final entries = await _client.listDirectoryContent();
    if (entries.any((entry) => entry.name == name)) {
      throw StateError('远程已有同名文件，请重命名后重试');
    }
    if (!await _client.uploadFile(
      file,
      onProgress: (percent, sent, total) {
        progress((percent / 100).clamp(0, 1));
      },
    )) {
      throw StateError('服务器未确认上传成功');
    }
    if (await _client.sizeFile(name) != await file.length()) {
      throw StateError('远程文件大小校验失败，请检查目标文件');
    }
  }

  Future<void> close() async {
    await _client.disconnect();
  }

  /// 未出回执返回空，不把FTP传输完成当作业务归卡成功。
  Future<Map<String, dynamic>?> batchReceipt(String id) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) throw StateError('批次编号不合法');
    final entries = await _client.listDirectoryContent();
    if (!entries.any((e) => e.name == 'manual-batch-receipts')) return null;
    if (!await _client.changeDirectory('manual-batch-receipts')) {
      throw StateError('无法访问批次回执');
    }
    if (!(await _client.listDirectoryContent()).any(
      (e) => e.name == '$id.json',
    )) {
      return null;
    }
    final size = await _client.sizeFile('$id.json');
    if (size < 1 || size > 8192) throw StateError('批次回执格式不合法');
    final bytes = await _client.downloadToBytes('$id.json');
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  /// 自动队列按相对目录保存；重试时校验内容，禁止仅按文件大小猜测成功。
  Future<void> uploadQueued(
    File file,
    String relativePath,
    String taskId,
    String digest,
    void Function(double) progress,
  ) async {
    final parts = p.posix.split(relativePath.replaceAll('\\', '/'));
    if (parts.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              part.contains('\r') ||
              part.contains('\n'),
        ) ||
        p.posix.isAbsolute(relativePath)) {
      throw StateError('图片相对路径不合法');
    }
    for (final folder in parts.take(parts.length - 1)) {
      final entries = await _client.listDirectoryContent();
      if (!entries.any((entry) => entry.name == folder)) {
        if (!await _client.makeDirectory(folder)) throw StateError('无法创建远程子目录');
      }
      if (!await _client.changeDirectory(folder)) throw StateError('无法访问远程子目录');
    }
    final name = parts.last;
    Future<bool> exists(String name) async =>
        (await _client.listDirectoryContent()).any(
          (entry) => entry.name == name,
        );
    Future<bool> matches(String name) async {
      if (await _client.sizeFile(name) != await file.length()) return false;
      final checkDir = await Directory.systemTemp.createTemp(
        'lvpai-ftp-verify-',
      );
      try {
        final downloaded = File(p.join(checkDir.path, 'verify.bin'));
        if (!await _client.downloadFile(name, downloaded)) {
          throw StateError('无法校验远端文件内容');
        }
        return (await sha256.bind(downloaded.openRead()).first).toString() ==
            digest;
      } finally {
        await checkDir.delete(recursive: true);
      }
    }

    if (await exists(name)) {
      if (!await matches(name)) throw StateError('远程同名文件内容不同，已停止覆盖');
      progress(1);
      return;
    }
    final temporary = '.lvpai-$taskId.part';
    if (!await _client.uploadFile(
      file,
      sRemoteName: temporary,
      onProgress: (percent, sent, total) =>
          progress((percent / 100).clamp(0, 1)),
    )) {
      throw StateError('服务器未确认临时文件上传成功');
    }
    if (!await matches(temporary)) throw StateError('临时文件内容校验失败');
    if (await exists(name)) {
      if (!await matches(name)) throw StateError('远程同名文件内容不同，已停止覆盖');
      return;
    }
    if (!await _client.rename(temporary, name)) throw StateError('远程文件确认改名失败');
    if (!await matches(name)) throw StateError('正式文件内容校验失败');
  }
}
