import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:lvpai_ftp_client/auto_upload/folder_uploader.dart';
import 'package:lvpai_ftp_client/auto_upload/journal.dart';
import 'package:lvpai_ftp_client/transfer.dart';
import 'package:path/path.dart' as p;

Future<List<int>> png(ui.Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(16, 16);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待自动队列状态超时');
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('日志恢复末尾半行，完整行损坏明确失败，独占锁拒绝第二实例', () async {
    final temp = await Directory.systemTemp.createTemp('ftp-journal-');
    final file = File(p.join(temp.path, 'queue.jsonl'));
    final first = QueueJournal(file);
    await first.open();
    await first.append({'type': 'initialized'});
    final second = QueueJournal(file);
    await expectLater(second.open(), throwsA(isA<FileSystemException>()));
    await first.close();
    await file.writeAsString('{"type":', mode: FileMode.append, flush: true);
    final restored = QueueJournal(file);
    expect(await restored.open(), [
      {'type': 'initialized'},
    ]);
    await restored.append({
      'type': 'ignore',
      'source': '照片.png',
      'signature': '1:2',
    });
    await restored.close();
    expect(await file.readAsLines(), hasLength(2));
    await file.writeAsString('BROKEN\n', mode: FileMode.append, flush: true);
    await expectLater(QueueJournal(file).open(), throwsFormatException);
    await temp.delete(recursive: true);
  });

  final port = int.tryParse(Platform.environment['FTP_TEST_PORT'] ?? '');
  test(
    '真实目录慢写、递归同名、自动FTP、重启补扫和远端冲突保护',
    () async {
      final temp = await Directory.systemTemp.createTemp('ftp-auto-');
      final source = await Directory(p.join(temp.path, '相机收图')).create();
      final storage = Directory(p.join(temp.path, 'state'));
      final rootName = 'auto-${DateTime.now().microsecondsSinceEpoch}';
      final profile = ServerProfile(
        name: '测试',
        host: '127.0.0.1',
        port: port!,
        user: 'test-user',
        password: 'test-password',
        directory: '/$rootName',
      );
      final reader = FTPConnect(
        profile.host,
        port: port,
        user: profile.user,
        pass: profile.password,
        transferType: TransferType.binary,
      );
      await reader.connect();
      await reader.makeDirectory(rootName);
      final red = await png(const ui.Color(0xffff0000));
      final blue = await png(const ui.Color(0xff0000ff));
      final old = File(p.join(source.path, '历史.png'));
      await old.writeAsBytes(red);
      FolderUploader create() => FolderUploader(
        storage: storage,
        scanInterval: const Duration(milliseconds: 70),
        stableFor: const Duration(milliseconds: 160),
        retryDelay: const Duration(milliseconds: 80),
      );
      var uploader = create();
      try {
        await uploader.start(source, profile);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(uploader.jobs, isEmpty, reason: '默认不上传启动前历史照片');
        final partial = File(p.join(source.path, '新照片.png'));
        await partial.writeAsBytes(red.take(20).toList(), flush: true);
        await until(() => uploader.issues.isNotEmpty);
        expect(uploader.jobs, isEmpty, reason: '稳定但不可解码的半张照片不能上传');
        await partial.writeAsBytes(red, flush: true);
        await until(
          () => uploader.jobs.where((j) => j.state == 'done').length == 1,
        );
        final sub = await Directory(p.join(source.path, '日期子目录')).create();
        await File(p.join(sub.path, '新照片.png')).writeAsBytes(blue, flush: true);
        await until(
          () => uploader.jobs.where((j) => j.state == 'done').length == 2,
        );
        expect(await reader.downloadToBytes('/$rootName/新照片.png'), red);
        expect(await reader.downloadToBytes('/$rootName/日期子目录/新照片.png'), blue);
        expect(await old.readAsBytes(), red, reason: '保留本地原图');
        final ids = uploader.jobs.map((j) => j.id).toSet();
        final interrupted = uploader.jobs.firstWhere(
          (j) => j.relative == '新照片.png',
        );
        await uploader.stop();
        uploader.dispose();
        // 模拟远端已改名成功，但本机仍停留在uploading的掉电状态。
        await partial.copy(interrupted.snapshot);
        interrupted.state = 'uploading';
        final journalFile = File(
          p.join(File(interrupted.snapshot).parent.parent.path, 'queue.jsonl'),
        );
        final journal = QueueJournal(journalFile);
        await journal.open();
        await journal.append(interrupted.toJson());
        await journal.close();
        await File(
          p.join(source.path, '离线新增.png'),
        ).writeAsBytes(red, flush: true);
        uploader = create();
        await uploader.start(source, profile);
        await until(
          () => uploader.jobs.where((j) => j.state == 'done').length == 3,
        );
        expect(
          uploader.jobs
              .where((j) => ids.contains(j.id) && j.id != interrupted.id)
              .every((j) => j.attempts == 1),
          isTrue,
        );
        expect(
          uploader.jobs.firstWhere((j) => j.id == interrupted.id).attempts,
          2,
          reason: '中断任务通过远端内容核对恢复成功，无需覆盖正式文件',
        );
        expect(uploader.jobs.any((j) => j.relative == '历史.png'), isFalse);
        await partial.writeAsBytes(blue, flush: true);
        await until(() => uploader.jobs.any((j) => j.state == 'failed'));
        expect(
          uploader.jobs.firstWhere((j) => j.state == 'failed').attempts,
          1,
        );
        expect(
          await reader.downloadToBytes('/$rootName/新照片.png'),
          red,
          reason: '同名不同内容不能自动覆盖',
        );
        expect(uploader.fatalError, isNull);
      } catch (_) {
        // 失败时保留状态证据，不输出配置或认证内容。
        // ignore: avoid_print
        print(
          'AUTO DIAGNOSTICS: ${uploader.jobs.map((j) => {'relative': j.relative, 'state': j.state, 'attempts': j.attempts, 'error': j.error})}'
          ' fatal=${uploader.fatalError} issues=${uploader.issues.values}',
        );
        rethrow;
      } finally {
        await uploader.stop();
        uploader.dispose();
        await reader.disconnect();
        await temp.delete(recursive: true);
      }
    },
    skip: port == null ? '需要真实隔离FTP端口' : false,
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('无网络有限自动重试，停止及重启后保留任务', () async {
    final temp = await Directory.systemTemp.createTemp('ftp-auto-retry-');
    final source = await Directory(p.join(temp.path, 'source')).create();
    final storage = Directory(p.join(temp.path, 'state'));
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final unavailablePort = socket.port;
    await socket.close();
    final profile = ServerProfile(
      name: '离线',
      host: '127.0.0.1',
      port: unavailablePort,
      user: 'test',
      password: 'test',
      directory: '/',
    );
    final uploader = FolderUploader(
      storage: storage,
      scanInterval: const Duration(milliseconds: 30),
      stableFor: const Duration(milliseconds: 60),
      retryDelay: const Duration(milliseconds: 30),
    );
    try {
      await uploader.start(source, profile);
      await File(
        p.join(source.path, '照片.png'),
      ).writeAsBytes(await png(const ui.Color(0xff123456)));
      await until(() => uploader.jobs.any((j) => j.state == 'failed'));
      expect(uploader.jobs.single.attempts, 3);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(uploader.jobs.single.attempts, 3);
      await uploader.stop();
      await uploader.start(source, profile);
      expect(uploader.jobs.single.state, 'failed');
      expect(await File(uploader.jobs.single.snapshot).exists(), isTrue);
    } finally {
      await uploader.stop();
      uploader.dispose();
      await temp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
