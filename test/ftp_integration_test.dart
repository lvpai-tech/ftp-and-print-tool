import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/transfer.dart';

void main() {
  final port = int.tryParse(Platform.environment['FTP_TEST_PORT'] ?? '');
  test('真实隔离 FTP 上传、重复拒绝、登录及目录错误', () async {
    ServerProfile profile({String password = 'test-password'}) => ServerProfile(
      name: '隔离测试',
      host: '127.0.0.1',
      port: port!,
      user: 'test-user',
      password: password,
      directory: '/',
    );
    final temp = await Directory.systemTemp.createTemp('photo-ftp-test-');
    final file = File(
      '${temp.path}/照片-${DateTime.now().microsecondsSinceEpoch}.png',
    );
    // 传输层验证任意二进制无损；界面只允许用户选择 JPEG/PNG。
    await file.writeAsBytes(List.generate(131071, (i) => i % 251));
    final transfer = PhotoTransfer(profile());
    try {
      await transfer.open('/');
      double progress = 0;
      await transfer.upload(file, (value) => progress = value);
      expect(progress, 1);
      final reader = FTPConnect(
        '127.0.0.1',
        port: port,
        user: 'test-user',
        pass: 'test-password',
        transferType: TransferType.binary,
      );
      try {
        expect(await reader.connect(), isTrue);
        final downloaded = await reader.downloadToBytes(
          file.uri.pathSegments.last,
        );
        expect(downloaded, await file.readAsBytes());
      } finally {
        await reader.disconnect();
      }
      await expectLater(transfer.upload(file, (_) {}), throwsStateError);
    } finally {
      await transfer.close();
    }
    final badLogin = PhotoTransfer(profile(password: 'wrong-password'));
    try {
      await expectLater(badLogin.open('/'), throwsA(anything));
    } finally {
      try {
        await badLogin.close();
      } catch (_) {}
    }
    final badDirectory = PhotoTransfer(profile());
    try {
      await expectLater(
        badDirectory.open('/missing-directory'),
        throwsStateError,
      );
    } finally {
      await badDirectory.close();
      await temp.delete(recursive: true);
    }
  }, skip: port == null ? '需设置 FTP_TEST_PORT 启动真实隔离 FTP 测试' : false);
}
