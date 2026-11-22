import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_avif_platform_interface/flutter_avif_platform_interface.dart';
import 'package:image/image.dart' as img;
import 'package:rawkit/rawkit.dart';

import 'heif_capture_metadata.dart';

Future<Uint8List> developRawPhoto(
  Future<RawDocument> Function() open,
  String extension,
) async {
  try {
    final document = await open();
    final timestamp = document.metadata.timestamp;
    final RawImage pixels;
    try {
      pixels = await document.render(
        RawDevelopSettings.defaults,
        bitDepth: RawBitDepth.uint8,
      );
    } finally {
      await document.close();
    }
    return await Isolate.run(() {
      final rgb = pixels.pixels8;
      final photo = img.Image.fromBytes(
        width: pixels.width,
        height: pixels.height,
        bytes: rgb.buffer,
        bytesOffset: rgb.offsetInBytes,
        numChannels: 3,
      );
      // RawKit supplies the camera's wall-clock fields in a UTC DateTime.
      if (timestamp != null) {
        final dateTime = timestamp.toIso8601String();
        final exifDate = dateTime.substring(0, 10).replaceAll('-', ':');
        photo.exif.exifIfd[0x9003] = img.IfdValueAscii(
          '$exifDate ${dateTime.substring(11, 19)}',
        );
      }
      photo.exif.imageIfd.orientation = 1;
      return img.encodeJpg(photo, quality: 95);
    });
  } on RawException catch (error) {
    throw StateError('${extension.toUpperCase()} 无法解码：${error.message}');
  }
}

Future<Uint8List> transcodeRasterPhoto(
  Uint8List bytes,
  String extension,
) async {
  try {
    if (extension == 'avif') {
      final metadata = await Isolate.run(() => readAvifCaptureMetadata(bytes));
      final frame = await FlutterAvifPlatform.api
          .decodeSingleFrameImage(avifBytes: bytes)
          .timeout(const Duration(seconds: 20));
      final rgba = Uint8List.fromList(frame.data);
      final width = frame.width;
      final height = frame.height;
      if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
        throw StateError('AVIF 像素数据无效');
      }
      return await Isolate.run(() {
        // The native decoder supplies premultiplied RGBA.
        for (var offset = 0; offset < rgba.length; offset += 4) {
          final white = 255 - rgba[offset + 3];
          rgba[offset] += white;
          rgba[offset + 1] += white;
          rgba[offset + 2] += white;
          rgba[offset + 3] = 255;
        }
        var photo = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: rgba.buffer,
          numChannels: 4,
        );
        final crop = metadata.crop;
        if (crop != null) photo = _cropAvif(photo, crop);
        if (metadata.rotation != 0) {
          photo = img.copyRotate(photo, angle: -90 * metadata.rotation);
        }
        if (metadata.mirror != null) {
          photo = metadata.mirror == 0
              ? img.flipVertical(photo)
              : img.flipHorizontal(photo);
        }
        return _encodeJpeg(photo, metadata.exif);
      });
    }
    return await Isolate.run(() => _transcodeTiffOrWebp(bytes, extension));
  } on StateError {
    rethrow;
  } on TimeoutException {
    throw StateError('AVIF 解码超时，请检查文件是否损坏或已写入完成');
  } catch (_) {
    throw StateError('${extension.toUpperCase()} 无法解码，请检查照片和编码方式');
  }
}

img.Image _cropAvif(img.Image photo, AvifCrop crop) {
  final left = (photo.width - crop.width) / 2 + crop.xOffset;
  final top = (photo.height - crop.height) / 2 + crop.yOffset;
  if ([
        left,
        top,
        crop.width,
        crop.height,
      ].any((n) => n != n.truncateToDouble()) ||
      left < 0 ||
      top < 0 ||
      crop.width <= 0 ||
      crop.height <= 0 ||
      left + crop.width > photo.width ||
      top + crop.height > photo.height) {
    throw StateError('AVIF 内嵌裁切范围无效或落在非整数像素上');
  }
  return img.copyCrop(
    photo,
    x: left.toInt(),
    y: top.toInt(),
    width: crop.width.toInt(),
    height: crop.height.toInt(),
  );
}

Uint8List _transcodeTiffOrWebp(Uint8List bytes, String extension) {
  final img.Image? photo;
  img.ExifData? metadata;
  if (extension == 'webp') {
    final decoder = img.WebPDecoder();
    final info = decoder.startDecode(bytes);
    if (info == null) throw StateError('文件内容不是有效的 WebP 照片');
    if (info.hasAnimation) throw StateError('请选择静态 WebP 照片');
    photo = decoder.decodeFrame(0);
    final exif = info.exif;
    if (exif.isNotEmpty) {
      metadata = img.ExifData.fromInputBuffer(
        img.InputBuffer(
          exif.startsWith('Exif\u0000\u0000')
              ? exif.codeUnits.sublist(6)
              : exif.codeUnits,
        ),
      );
    }
  } else {
    _checkSingleTiffPage(bytes);
    final decoder = img.TiffDecoder();
    if (decoder.startDecode(bytes) == null) {
      throw StateError('文件内容不是有效的 TIFF 照片');
    }
    photo = decoder.decodeFrame(0);
    metadata = decoder.exif;
  }
  if (photo == null) throw StateError('${extension.toUpperCase()} 无法解码');
  final orientation = metadata?.imageIfd.orientation;
  photo.exif = img.ExifData();
  photo.exif.imageIfd.orientation = orientation ?? 1;
  return _encodeJpeg(
    orientation == null || orientation == 1
        ? photo
        : img.bakeOrientation(photo),
    metadata,
  );
}

void _checkSingleTiffPage(Uint8List bytes) {
  const invalid = '文件内容不是有效的 TIFF 照片';
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 8) throw StateError(invalid);
  final order = switch (data.getUint16(0)) {
    0x4949 => Endian.little,
    0x4d4d => Endian.big,
    _ => throw StateError(invalid),
  };
  final first = data.getUint32(4, order);
  if (data.getUint16(2, order) != 42 || first < 8 || first > bytes.length - 6) {
    throw StateError(invalid);
  }
  final end = first + 2 + data.getUint16(first, order) * 12;
  if (end > bytes.length - 4) throw StateError(invalid);
  if (data.getUint32(end, order) != 0) throw StateError('请选择单页 TIFF 照片');
}

Uint8List _encodeJpeg(img.Image photo, img.ExifData? metadata) {
  final rgb = photo.hasAlpha
      ? img.compositeImage(
          img.Image(width: photo.width, height: photo.height)
            ..clear(img.ColorRgb8(255, 255, 255)),
          photo,
        )
      : photo;
  rgb.exif = img.ExifData();
  rgb.exif.imageIfd.orientation = 1;
  if (metadata != null) {
    for (final tag in const [0x9003, 0x9011, 0x9291]) {
      final value = metadata.exifIfd[tag];
      if (value is img.IfdValueAscii) rgb.exif.exifIfd[tag] = value;
    }
  }
  return img.encodeJpg(rgb, quality: 95);
}
