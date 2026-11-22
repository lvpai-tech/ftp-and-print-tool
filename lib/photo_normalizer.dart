import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:platform_image_converter/platform_image_converter.dart';
import 'package:rawkit/rawkit.dart';

import 'heif_capture_metadata.dart';
import 'photo_transcoder.dart';

const _heifExtensions = {'heic', 'heif', 'hif'};
const _rasterExtensions = {'tif', 'tiff', 'webp', 'avif'};
const _rawExtensions = {
  'cr3',
  'cr2',
  'arw',
  'nef',
  'raf',
  'rw2',
  'orf',
  'pef',
  'dng',
};
const cameraPhotoExtensions = [
  'jpg',
  'jpeg',
  'png',
  'mpo',
  ..._heifExtensions,
  ..._rasterExtensions,
  ..._rawExtensions,
];

String _extension(String path) =>
    p.extension(path).toLowerCase().replaceFirst('.', '');

bool isRawCameraPhoto(String path) => _rawExtensions.contains(_extension(path));

bool isJpegCameraPhoto(String path) =>
    const {'jpg', 'jpeg'}.contains(_extension(path));

bool needsPhotoTranscode(String path) {
  final extension = _extension(path);
  return _heifExtensions.contains(extension) ||
      _rasterExtensions.contains(extension) ||
      _rawExtensions.contains(extension);
}

/// 只处理私有待传副本，保留相机源文件。
Future<bool> normalizePhotoSnapshot(File snapshot, {String? sourcePath}) async {
  final originalPath = sourcePath ?? snapshot.path;
  if (!needsPhotoTranscode(originalPath)) {
    final path = snapshot.path;
    return Isolate.run(() {
      final file = File(path);
      final source = file.readAsBytesSync();
      final jpeg = normalizeJpegPrimary(source, sourcePath: originalPath);
      if (identical(source, jpeg)) return false;
      file.writeAsBytesSync(jpeg, flush: true);
      return true;
    });
  }
  final extension = _extension(originalPath);
  final result = _rawExtensions.contains(extension)
      ? await developRawPhoto(
          () => RawDocument.openFile(snapshot.path),
          extension,
        )
      : await normalizedCameraPhoto(await snapshot.readAsBytes(), originalPath);
  await snapshot.writeAsBytes(result, flush: true);
  return true;
}

Future<Uint8List> normalizedCameraPhoto(Uint8List bytes, String path) async {
  final extension = _extension(path);
  if (_rawExtensions.contains(extension)) {
    return developRawPhoto(() => RawDocument.openMemory(bytes), extension);
  }
  if (_rasterExtensions.contains(extension)) {
    return transcodeRasterPhoto(bytes, extension);
  }
  if (!_heifExtensions.contains(extension)) {
    final changed = await Isolate.run(() {
      final photo = normalizeJpegPrimary(bytes, sourcePath: path);
      return identical(photo, bytes) ? null : photo;
    });
    return changed ?? bytes;
  }

  final metadata = await Isolate.run(() => readHeifCaptureMetadata(bytes));
  final Uint8List jpeg;
  try {
    jpeg = await ImageConverter.convert(inputData: bytes, quality: 95);
  } on ImageConversionException {
    throw StateError('HEIF 无法解码，请检查系统 HEIF/HEVC 解码器和相机文件');
  }
  if (metadata == null) return jpeg;
  final result = await Isolate.run(() => img.injectJpgExif(jpeg, metadata));
  if (result == null) throw StateError('HEIF 拍摄时间无法写入 JPEG');
  return result;
}

Future<String?> readJpegCaptureTime(File file) {
  final path = file.path;
  return Isolate.run(() {
    final jpeg = File(path).readAsBytesSync();
    try {
      final value = img.decodeJpgExif(jpeg)?.exifIfd[0x9003]?.toString().trim();
      if (value != null &&
          RegExp(r'^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$').hasMatch(value) &&
          !value.startsWith('0000:')) {
        return value;
      }
    } catch (_) {
      // Without a capture time there is no evidence for pairing two files.
    }
    return null;
  });
}

/// 非JPEG由现有解码校验决定；JPEG标记损坏或主图截断时明确失败。
Uint8List normalizeJpegPrimary(
  Uint8List bytes, {
  String? sourcePath,
  bool legacyFirstImage = false,
}) {
  if (bytes.length < 2 || bytes[0] != 0xff || bytes[1] != 0xd8) return bytes;
  return _jpegFrame(
    bytes,
    inspectIndex: !legacyFirstImage,
    allowStalePrimarySize: sourcePath != null && isJpegCameraPhoto(sourcePath),
  ).bytes;
}

({Uint8List bytes, int end}) _jpegFrame(
  Uint8List bytes, {
  required bool inspectIndex,
  bool allowStalePrimarySize = false,
}) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
    throw StateError('MPO 索引指向的画面不是 JPEG');
  }
  final output = BytesBuilder(copy: false)..add(bytes.sublist(0, 2));
  var offset = 2;
  var mpf = false;
  int? indexStart;
  int? indexEnd;
  var entropy = false;
  while (offset < bytes.length) {
    final start = offset;
    if (entropy) {
      while (offset < bytes.length && bytes[offset] != 0xff) {
        offset++;
      }
      output.add(bytes.sublist(start, offset));
      if (offset >= bytes.length) break;
    }
    final markerStart = offset;
    if (bytes[offset++] != 0xff) throw StateError('JPEG标记损坏，请检查照片');
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (entropy && (marker == 0 || (marker >= 0xd0 && marker <= 0xd7))) {
      output.add(bytes.sublist(markerStart, offset));
      continue;
    }
    entropy = false;
    if (marker == 0xd9) {
      output.add(bytes.sublist(markerStart, offset));
      if (indexStart != null) {
        final selected = _representativeImage(
          bytes,
          indexStart,
          indexEnd!,
          offset,
          allowStalePrimarySize: allowStalePrimarySize,
        );
        if (selected.start != 0) {
          final frame = _jpegFrame(
            Uint8List.sublistView(bytes, selected.start, selected.end),
            inspectIndex: false,
          );
          if (frame.end != selected.end - selected.start) {
            throw StateError('MPO 代表图长度与索引不一致');
          }
          return frame;
        }
      }
      return (bytes: mpf ? output.takeBytes() : bytes, end: offset);
    }
    if (marker == 0xd8 ||
        marker == 0 ||
        marker == 1 ||
        (marker >= 0xd0 && marker <= 0xd7)) {
      throw StateError('JPEG标记不合法，请检查照片');
    }
    if (offset + 2 > bytes.length) break;
    final length = bytes[offset] * 256 + bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) break;
    final isMpf =
        marker == 0xe2 &&
        length >= 6 &&
        bytes[offset + 2] == 77 &&
        bytes[offset + 3] == 80 &&
        bytes[offset + 4] == 70 &&
        bytes[offset + 5] == 0;
    if (isMpf) {
      mpf = true;
      if (inspectIndex) {
        if (indexStart != null) throw StateError('MPO 存在多个主索引');
        indexStart = offset + 6;
        indexEnd = offset + length;
      }
    } else {
      output.add(bytes.sublist(markerStart, offset + length));
    }
    offset += length;
    entropy = marker == 0xda;
  }
  throw StateError('JPEG主图不完整，请等待照片写入完成');
}

({int start, int end}) _representativeImage(
  Uint8List bytes,
  int start,
  int end,
  int firstEnd, {
  required bool allowStalePrimarySize,
}) {
  const badIndex = 'MPO 图像索引损坏，请检查相机文件';
  final tiff = ByteData.sublistView(bytes, start, end);
  if (tiff.lengthInBytes < 8) throw StateError(badIndex);
  final order = switch (tiff.getUint16(0)) {
    0x4949 => Endian.little,
    0x4d4d => Endian.big,
    _ => throw StateError(badIndex),
  };
  final directory = tiff.getUint32(4, order);
  if (tiff.getUint16(2, order) != 42 ||
      directory < 8 ||
      directory + 2 > tiff.lengthInBytes) {
    throw StateError(badIndex);
  }
  final count = tiff.getUint16(directory, order);
  if (directory + 2 + count * 12 + 4 > tiff.lengthInBytes) {
    throw StateError(badIndex);
  }

  int? imageCount;
  int? entries;
  int? entriesSize;
  for (var index = 0; index < count; index++) {
    final field = directory + 2 + index * 12;
    final tag = tiff.getUint16(field, order);
    if (tag == 0xb001 &&
        tiff.getUint16(field + 2, order) == 4 &&
        tiff.getUint32(field + 4, order) == 1) {
      imageCount = tiff.getUint32(field + 8, order);
    } else if (tag == 0xb002 && tiff.getUint16(field + 2, order) == 7) {
      entriesSize = tiff.getUint32(field + 4, order);
      entries = tiff.getUint32(field + 8, order);
    }
  }
  if (imageCount == null ||
      imageCount == 0 ||
      entries == null ||
      entries < 8 ||
      entriesSize != imageCount * 16 ||
      entries + entriesSize! > tiff.lengthInBytes) {
    throw StateError(badIndex);
  }

  ({int start, int end})? representative;
  ({int start, int end})? primary;
  for (var index = 0; index < imageCount; index++) {
    final entry = entries + index * 16;
    final flags = tiff.getUint32(entry, order);
    final size = tiff.getUint32(entry + 4, order);
    final offset = tiff.getUint32(entry + 8, order);
    final imageStart = index == 0 ? 0 : start + offset;
    final imageEnd = imageStart + size;
    final type = flags & 0x00ffffff;
    final jpeg = (flags & 0x07000000) == 0;
    // Saved JPEGs may keep an older main-image size after metadata changes.
    // The JPEG marker walk supplies the actual end of the baseline image.
    final stalePrimarySize =
        allowStalePrimarySize && jpeg && type == 0x030000 && size < firstEnd;
    if (size < 4 ||
        imageEnd > bytes.length ||
        (index == 0
            ? (offset != 0 || (imageEnd != firstEnd && !stalePrimarySize))
            : imageStart < firstEnd)) {
      throw StateError(badIndex);
    }
    final thumbnail = (type & 0xff0000) == 0x010000;
    final frame = (start: imageStart, end: index == 0 ? firstEnd : imageEnd);
    if ((flags & 0x20000000) != 0) {
      if (!jpeg || thumbnail || representative != null) {
        throw StateError(badIndex);
      }
      representative = frame;
    }
    if (jpeg && type == 0x030000) {
      if (primary != null) throw StateError(badIndex);
      primary = frame;
    }
  }
  return representative ?? primary ?? (throw StateError('MPO 未标记可用于二维取片的代表图'));
}

/// MPO 和需要转码的照片使用标准 JPEG 扩展名。
String photoUploadExtension(String path) =>
    _extension(path) == 'mpo' || needsPhotoTranscode(path)
    ? '.jpg'
    : p.extension(path);
