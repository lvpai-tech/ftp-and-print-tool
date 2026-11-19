import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:image/image.dart' as img;
import 'package:lvpai_ftp_client/manual_batch/batch_workspace.dart';
import 'package:lvpai_ftp_client/manual_batch/card_decoder.dart';
import 'package:lvpai_ftp_client/transfer.dart';
import 'package:zxing_lib/zxing.dart';
import 'package:zxing_lib/oned.dart';

Future<File> photo(
  Directory root,
  String name, {
  String? secret,
  int color = 130,
}) async {
  final image = img.Image(width: 800, height: 300);
  img.fill(image, color: img.ColorRgb8(color, color, color));
  if (secret != null) {
    final matrix = Code128Writer().encode(
      secret,
      BarcodeFormat.code128,
      760,
      160,
    );
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        if (matrix.get(x, y)) image.setPixelRgb(x + 20, y + 110, 0, 0, 0);
      }
    }
  }
  return File('${root.path}/$name.png').writeAsBytes(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late BatchWorkspace work;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lvpai-manual-test-');
    work = BatchWorkspace(storage: Directory('${root.path}/state'));
    await work.open();
  });
  tearDown(() async {
    await work.close();
    work.dispose();
    await root.delete(recursive: true);
  });

  test('真实Code128识别，普通游客照无条码仍保留', () async {
    final end = await photo(root, 'end', secret: 'TEST00002522');
    expect(await decodeCard(end), 'TEST00002522');
    expect(await decodeCard(await photo(root, 'visitor')), isNull);
    expect(cardSecret('2522'), isNull);
    expect(
      cardSecret('https://test.invalid/?qrSecret=TEST00002522'),
      'TEST00002522',
    );
  });

  test('建议闭批、加减移动及重启恢复均不会上传或自动变更成员', () async {
    final a = await photo(root, 'a');
    final end = await photo(root, 'end', secret: 'TEST00002522');
    final b = await photo(root, 'b', color: 160);
    await work.addFiles([a, end, b]);
    expect(work.batches.length, 2);
    final first = work.batches.first;
    final second = work.batches.last;
    expect(first.secret, 'TEST00002522');
    expect(first.state, 'draft');
    final tourist = first.photoIds.first;
    await work.removePhoto(first.id, tourist);
    expect(work.unassigned.single.id, tourist);
    expect(await a.exists(), isTrue);
    await work.movePhoto(tourist, second.id);
    expect(second.photoIds.length, 2);
    await work.movePhoto(tourist, first.id);
    expect(work.unassigned, isEmpty);
    await work.close();
    work.dispose();
    work = BatchWorkspace(storage: Directory('${root.path}/state'));
    await work.open();
    expect(work.batches.first.state, 'draft');
    expect(work.batches.first.photoIds.length, 2);
    expect(work.watching, isFalse);
    expect(work.uploading, isFalse);
    expect(
      await File('${root.path}/state/${first.id}.ready.json').exists(),
      isFalse,
    );
  });

  test('重复导入去重，移出结束照后必须重新选择', () async {
    final a = await photo(root, 'a');
    final end = await photo(root, 'end', secret: 'TEST00002522');
    await work.addFiles([a, end, a]);
    expect(work.photos.length, 2);
    final batch = work.batches.single;
    final id = batch.endPhotoId!;
    await work.removePhoto(batch.id, id);
    expect(batch.secret, isNull);
    expect(batch.endPhotoId, isNull);
    await work.movePhoto(id, batch.id);
    await work.setEnding(batch.id, id);
    expect(batch.secret, 'TEST00002522');
  });

  test('监听只稳定收图与分组，修改未稳定文件不会提前加入批次', () async {
    final inbox = await Directory('${root.path}/inbox').create();
    await work.startWatching(inbox);
    final a = await photo(inbox, 'a');
    await work.scanNow();
    expect(work.photos, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    await work.scanNow();
    expect(work.photos.length, 1);
    expect(work.batches.single.state, 'draft');
    expect(await a.exists(), isTrue);
    await work.stopWatching();
    await photo(inbox, 'later', color: 180);
    await work.scanNow();
    expect(work.photos.length, 1);
  });

  final port = int.tryParse(Platform.environment['FTP_TEST_PORT'] ?? '');
  test(
    '真实FTP：仅点击上传后发送固定成员，清单提交与后台回执分开',
    () async {
      final profile = ServerProfile(
        name: '隔离FTP',
        host: '127.0.0.1',
        port: port!,
        user: 'test-user',
        password: 'test-password',
        directory: '/',
      );
      await work.addFiles([
        await photo(root, 'a'),
        await photo(root, 'end', secret: 'TEST00002522'),
        await photo(root, 'other', color: 180),
      ]);
      final batch = work.batches.first;
      final client = FTPConnect(
        profile.host,
        port: port,
        user: profile.user,
        pass: profile.password,
        transferType: TransferType.binary,
      );
      try {
        expect(await client.connect(), isTrue);
        final before = await client.listDirectoryContent();
        expect(before.any((e) => e.name == batch.id), isFalse);
        await work.uploadBatch(batch.id, profile);
        expect(batch.state, 'submitted');
        expect(work.batches.last.state, 'draft');
        final path = 'manual-batch-commits/${batch.id}.ready.json';
        final bytes = await client.downloadToBytes(path);
        final manifest = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        expect((manifest['photos'] as List).length, 2);
        expect(manifest['cardSecret'], 'TEST00002522');
        for (final p in manifest['photos']) {
          final remote = await client.downloadToBytes(
            'manual-batches/${batch.id}/${p['name']}',
          );
          expect(sha256.convert(remote).toString(), p['sha256']);
        }
        await expectLater(
          work.removePhoto(batch.id, batch.photoIds.first),
          throwsStateError,
        );
        await work.checkReceipt(batch.id, profile);
        expect(batch.state, 'submitted');
        await client.makeDirectory('manual-batch-receipts');
        final receipt = File('${root.path}/${batch.id}.json');
        await receipt.writeAsString(
          jsonEncode({'version': 1, 'batchId': batch.id, 'state': 'ACCEPTED'}),
        );
        expect(
          await client.uploadFile(
            receipt,
            sRemoteName: 'manual-batch-receipts/${batch.id}.json',
          ),
          isTrue,
        );
        await work.checkReceipt(batch.id, profile);
        expect(batch.state, 'accepted');
      } finally {
        await client.disconnect();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: port == null ? '需启动真实回环FTP并设置FTP_TEST_PORT' : false,
  );
}
