import 'dart:ffi';
import 'dart:io';

import 'package:flutter_avif_platform_interface/flutter_avif_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lvpai_ftp_client/photo_normalizer.dart';
import 'package:path/path.dart' as p;

void main() {
  test('单页 16 位 TIFF 可以转换为标准 JPEG', () async {
    final image = img.Image(width: 48, height: 32, format: img.Format.uint16);
    for (final pixel in image) {
      pixel.r = 65535;
    }
    final jpeg = await normalizedCameraPhoto(img.encodeTiff(image), 'test.TIF');
    final result = img.decodeJpg(jpeg)!;
    expect((result.width, result.height), (48, 32));
    expect(result.getPixel(10, 10).r, greaterThan(250));
  });

  test('损坏或伪装成新格式的文件显式失败', () async {
    final jpg = img.encodeJpg(img.Image(width: 2, height: 2));
    for (final extension in ['TIFF', 'WEBP', 'AVIF', 'DNG']) {
      await expectLater(
        normalizedCameraPhoto(jpg, 'broken.$extension'),
        throwsStateError,
      );
    }
  });

  final samples = Platform.environment['CAMERA_SAMPLE_DIR'];
  final avifLibrary = Platform.environment['AVIF_TEST_LIBRARY'];
  setUpAll(() {
    if (avifLibrary != null) {
      FlutterAvifPlatform.api = FlutterAvifImpl(
        DynamicLibrary.open(avifLibrary),
      );
    }
  });
  for (final extension in [
    'cr3',
    'cr2',
    'arw',
    'nef',
    'raf',
    'rw2',
    'orf',
    'pef',
    'dng',
    'tiff',
    'webp',
    'avif',
  ]) {
    test('真实 $extension 文件转换，保留取片所需的拍摄时间和方向', () async {
      final path = p.join(samples!, 'sample.$extension');
      final source = await File(path).readAsBytes();
      final jpeg = await normalizedCameraPhoto(source, path);
      final info = img.JpegDecoder().startDecode(jpeg)!;
      expect(info.width, greaterThan(100));
      expect(info.height, greaterThan(100));
      final metadata = img.decodeJpgExif(jpeg)!;
      expect(metadata.imageIfd.orientation, 1);
      expect(
        metadata.exifIfd[0x9003]?.toString(),
        matches(RegExp(r'^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$')),
      );
      if (['tiff', 'webp', 'avif'].contains(extension)) {
        expect((info.width, info.height), (240, 320));
        expect(metadata.exifIfd[0x9003]?.toString(), '2026:11:22 14:23:45');
        expect(metadata.exifIfd[0x9011]?.toString(), '+08:00');
        expect(metadata.exifIfd[0x9291]?.toString(), '32');
        final photo = img.decodeJpg(jpeg)!;
        expect(photo.getPixel(200, 25).g, greaterThan(140));
        expect(photo.getPixel(40, 25).g, lessThan(90));
      }
    }, skip: samples == null || (extension == 'avif' && avifLibrary == null));
  }

  final croppedAvif = Platform.environment['AVIF_CROP_FILE'];
  test('AVIF 应用容器裁切到指定位置', () async {
    final bytes = await File(croppedAvif!).readAsBytes();
    final jpeg = await normalizedCameraPhoto(bytes, croppedAvif);
    final photo = img.decodeJpg(jpeg)!;
    expect((photo.width, photo.height), (180, 100));
    final blue = photo.getPixel(0, 0);
    expect(blue.b, greaterThan(240));
    expect([blue.r, blue.g], everyElement(lessThan(15)));
  }, skip: croppedAvif == null || avifLibrary == null);
}
