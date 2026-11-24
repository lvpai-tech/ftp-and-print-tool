import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:lvpai_ftp_client/auto_upload/folder_uploader.dart';
import 'package:lvpai_ftp_client/transfer.dart';

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lvpai_ftp_client/photo_normalizer.dart';
import 'package:lvpai_ftp_client/manual_batch/batch_workspace.dart';
import 'package:lvpai_ftp_client/manual_batch/card_tail_recognizer.dart';

Uint8List primary() =>
    Uint8List.fromList(img.encodeJpg(img.Image(width: 32, height: 24)));
Uint8List mpo(
  Uint8List jpg, {
  Uint8List? second,
  bool secondIsRepresentative = false,
  int firstSizeAdjustment = 0,
}) {
  final attached = second ?? jpg;
  final tiff = ByteData(70)
    ..setUint16(0, 0x4d4d)
    ..setUint16(2, 42)
    ..setUint32(4, 8)
    ..setUint16(8, 2)
    ..setUint16(10, 0xb001)
    ..setUint16(12, 4)
    ..setUint32(14, 1)
    ..setUint32(18, 2)
    ..setUint16(22, 0xb002)
    ..setUint16(24, 7)
    ..setUint32(26, 32)
    ..setUint32(30, 38);
  const app1 = [255, 225, 0, 8, 69, 120, 105, 102, 0, 0];
  final segmentLength = 6 + tiff.lengthInBytes;
  final firstLength = jpg.length + app1.length + segmentLength + 2;
  final tiffStart = 2 + app1.length + 8;
  tiff
    ..setUint32(38, secondIsRepresentative ? 0x020003 : 0xa0030000)
    ..setUint32(42, firstLength + firstSizeAdjustment)
    ..setUint32(54, secondIsRepresentative ? 0x20020003 : 0x40010002)
    ..setUint32(58, attached.length)
    ..setUint32(62, firstLength - tiffStart);
  return Uint8List.fromList([
    ...jpg.take(2),
    ...app1,
    255,
    226,
    0,
    segmentLength,
    77,
    80,
    70,
    0,
    ...tiff.buffer.asUint8List(),
    ...jpg.skip(2),
    ...attached,
  ]);
}

void main() {
  test('JPEG/PNG不改字节，正常JPEG不二次压缩', () {
    final jpg = primary();
    expect(identical(normalizeJpegPrimary(jpg), jpg), isTrue);
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 2, height: 2)),
    );
    expect(identical(normalizeJpegPrimary(png), png), isTrue);
  });
  test('普通 JPEG 和 PNG 不生成派生图', () async {
    final jpeg = primary();
    final png = img.encodePng(img.Image(width: 2, height: 2));
    expect(
      identical(await normalizedCameraPhoto(jpeg, 'camera.JPG'), jpeg),
      isTrue,
    );
    expect(
      identical(await normalizedCameraPhoto(png, 'camera.PNG'), png),
      isTrue,
    );
  });
  test('MPO只保留主图，EXIF段和原压缩像素不变，转换可重复', () {
    final jpg = primary();
    final result = normalizeJpegPrimary(mpo(jpg));
    expect(result, [
      ...jpg.take(2),
      255,
      225,
      0,
      8,
      69,
      120,
      105,
      102,
      0,
      0,
      ...jpg.skip(2),
    ]);
    expect(img.decodeJpg(result)!.width, 32);
    expect(normalizeJpegPrimary(result), result);
    expect(photoUploadExtension('相机.MPO'), '.jpg');
  });
  test('JPG 不因 MPF 里过时的主图长度拒收完整画面', () async {
    final jpg = primary();
    final original = mpo(jpg, firstSizeAdjustment: -23);
    expect(
      await normalizedCameraPhoto(original, 'saved.JPG'),
      normalizeJpegPrimary(mpo(jpg)),
    );
    await expectLater(
      normalizedCameraPhoto(original, 'camera.MPO'),
      throwsStateError,
    );
    await expectLater(
      normalizedCameraPhoto(
        Uint8List.sublistView(original, 0, original.length - 1),
        'saved.JPG',
      ),
      throwsStateError,
    );
  });
  test('截断主图和损坏段明确失败，不会用附图冒充主图', () {
    final source = mpo(primary());
    expect(
      () => normalizeJpegPrimary(
        Uint8List.sublistView(source, 0, source.length - 1),
      ),
      throwsStateError,
    );
    expect(
      () => normalizeJpegPrimary(Uint8List.fromList(source.take(13).toList())),
      throwsStateError,
    );
    expect(
      () => normalizeJpegPrimary(
        Uint8List.fromList([255, 216, 255, 226, 255, 255]),
      ),
      throwsStateError,
    );
  });
  test('OCR 预览使用 JPG 来源路径兼容过时 MPF 长度', () {
    final original = mpo(primary(), firstSizeAdjustment: -23);
    final (preview, size) = cardTailPreview(original, sourcePath: 'camera.JPG');
    expect((size.width, size.height), (32, 24));
    expect(img.decodeJpg(preview)!.width, 32);
    expect(
      () => cardTailPreview(original, sourcePath: 'camera.MPO'),
      throwsStateError,
    );
    expect(
      () => cardTailPreview(
        Uint8List.sublistView(original, 0, original.length - 1),
        sourcePath: 'camera.JPG',
      ),
      throwsStateError,
    );
  });
  test('代表图可位于第二项，旧队列仍可用旧摘要读回第一项', () async {
    final second = img.encodeJpg(img.Image(width: 64, height: 24));
    final bytes = mpo(primary(), second: second, secondIsRepresentative: true);
    expect(normalizeJpegPrimary(bytes), second);
    final legacy = normalizeJpegPrimary(bytes, legacyFirstImage: true);
    expect(img.decodeJpg(legacy)!.width, 32);
    final dir = await Directory.systemTemp.createTemp('mpo-legacy-review-');
    try {
      final source = await File('${dir.path}/source.jpg').writeAsBytes(bytes);
      final job = AutoJob(
        id: 'legacy',
        source: source.path,
        relative: 'source.jpg',
        signature: '',
        digest: sha256.convert(legacy).toString(),
        snapshot: '${dir.path}/removed.jpg',
      );
      expect(await job.readPhotoForReview(), legacy);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('更名为 HEIC 的 JPEG 明确拒绝', () async {
    await expectLater(
      normalizedCameraPhoto(primary(), 'fake.HEIC'),
      throwsStateError,
    );
  });
  test('手动队列对实际待传副本标准化，大小/摘要匹配，源文件保留', () async {
    final root = await Directory.systemTemp.createTemp('photo-normalize-test-');
    final source = File('${root.path}/camera.MPO');
    final bytes = mpo(primary());
    await source.writeAsBytes(bytes);
    final workspace = BatchWorkspace(
      storage: Directory('${root.path}/queue'),
      recognize: (file) async {
        expect(await file.readAsBytes(), normalizeJpegPrimary(bytes));
        return null;
      },
    );
    try {
      await workspace.open();
      await workspace.addFiles([source]);
      final photo = workspace.photos.values.single;
      expect(photo.snapshot.endsWith('.jpg'), isTrue);
      expect(photo.size, await File(photo.snapshot).length());
      expect(await source.readAsBytes(), bytes);
    } finally {
      await workspace.close();
      workspace.dispose();
      await root.delete(recursive: true);
    }
  });
  test('真实FTP：自动队列MPO主图标准化后上传、源文件不变及重启恢复', () async {
    final root = await Directory.systemTemp.createTemp('mpo-auto-');
    final source = await Directory('${root.path}/source').create();
    final profile = ServerProfile(
      name: '隔离',
      host: '127.0.0.1',
      port: int.parse(Platform.environment['FTP_TEST_PORT']!),
      user: 'test-user',
      password: 'test-password',
      directory: '/',
    );
    final bytes = mpo(primary());
    final name = 'camera-${DateTime.now().microsecondsSinceEpoch}.MPO';
    final original = await File('${source.path}/$name').writeAsBytes(bytes);
    FolderUploader create() => FolderUploader(
      storage: Directory('${root.path}/queue'),
      scanInterval: const Duration(milliseconds: 50),
      stableFor: const Duration(milliseconds: 100),
    );
    var uploader = create();
    final reader = FTPConnect(
      profile.host,
      port: profile.port,
      user: profile.user,
      pass: profile.password,
      transferType: TransferType.binary,
    );
    try {
      await uploader.start(source, profile, includeExisting: true);
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!uploader.jobs.any((j) => j.state == 'done') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        uploader.jobs.single.state,
        'done',
        reason: uploader.issues.toString(),
      );
      final job = uploader.jobs.single;
      expect(job.relative.endsWith('.jpg'), isTrue);
      final expected = normalizeJpegPrimary(bytes);
      expect(job.digest, sha256.convert(expected).toString());
      await reader.connect();
      expect(await reader.downloadToBytes(job.relative), expected);
      expect(await original.readAsBytes(), bytes);
      await uploader.stop();
      uploader.dispose();
      uploader = create();
      await uploader.start(source, profile, includeExisting: true);
      expect(uploader.jobs.single.digest, job.digest);
      expect(uploader.jobs.single.state, 'done');
      expect(await reader.downloadToBytes(job.relative), expected);
    } finally {
      await uploader.stop();
      uploader.dispose();
      await reader.disconnect();
      await root.delete(recursive: true);
    }
  }, skip: Platform.environment['FTP_TEST_PORT'] == null);
  test('生产4931真实MPO的本地副本转换（显式提供样本时运行）', () async {
    final input = Platform.environment['MPO_SAMPLE'];
    if (input == null) return;
    final source = File(input);
    final dir = await Directory.systemTemp.createTemp('camera-mpo-sample-');
    try {
      final copy = await source.copy('${dir.path}/normalized.jpg');
      await normalizePhotoSnapshot(copy);
      expect(await copy.length(), lessThan(await source.length()));
      expect(img.decodeJpg(await copy.readAsBytes())!.width, 6000);
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: Platform.environment['MPO_SAMPLE'] == null);
}
