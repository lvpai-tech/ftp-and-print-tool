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

Uint8List primary() =>
    Uint8List.fromList(img.encodeJpg(img.Image(width: 32, height: 24)));
Uint8List mpo(Uint8List jpg) => Uint8List.fromList([
  ...jpg.take(2),
  // APP1原样保留（包含EXIF/拍摄时间的段不参与修改）。
  255, 225, 0, 8, 69, 120, 105, 102, 0, 0,
  255, 226, 0, 8, 77, 80, 70, 0, 0, 0,
  ...jpg.skip(2), ...jpg,
]);
void main() {
  test('JPEG/PNG不改字节，正常JPEG不二次压缩', () {
    final jpg = primary();
    expect(identical(normalizeJpegPrimary(jpg), jpg), isTrue);
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 2, height: 2)),
    );
    expect(identical(normalizeJpegPrimary(png), png), isTrue);
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
  test('截断主图和损坏段明确失败，不会用附图冒充主图', () {
    final source = mpo(primary());
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
    final copy = await source.copy('$input.normalized.jpg');
    await normalizePhotoSnapshot(copy);
    expect(await copy.length(), lessThan(await source.length()));
    expect(img.decodeJpg(await copy.readAsBytes())!.width, 6000);
  }, skip: Platform.environment['MPO_SAMPLE'] == null);
}
