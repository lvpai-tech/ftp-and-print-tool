import 'dart:io';
import 'dart:isolate';

import 'package:exif/exif.dart' as exif;
import 'package:path/path.dart' as p;
import 'package:rawkit/rawkit.dart';

import 'heif_capture_metadata.dart';

class CameraMetadata {
  const CameraMetadata(
    this.readStatus, {
    this.artist,
    this.cameraMake,
    this.cameraModel,
  });

  final String readStatus;
  final String? artist;
  final String? cameraMake;
  final String? cameraModel;

  factory CameraMetadata.fromJson(Map<String, dynamic> json) => CameraMetadata(
    json['readStatus'] as String,
    artist: json['artist'] as String?,
    cameraMake: json['cameraMake'] as String?,
    cameraModel: json['cameraModel'] as String?,
  );

  Map<String, String> toJson() => {
    'readStatus': readStatus,
    'artist': ?artist,
    'cameraMake': ?cameraMake,
    'cameraModel': ?cameraModel,
  };

  String get description {
    final camera = [cameraMake, cameraModel].nonNulls.join(' ');
    final creator =
        artist ??
        switch (readStatus) {
          'PARSE_ERROR' => 'EXIF 读取失败',
          'UNSUPPORTED' => '此格式的作者读取暂不支持',
          _ => '未读到作者',
        };
    return '作者：$creator${camera.isEmpty ? '' : ' · $camera'}';
  }
}

const _bmff = {'heif', 'heic', 'hif', 'avif'};
const _tiff = {'tif', 'tiff', 'cr2', 'arw', 'nef', 'pef', 'dng'};

Future<CameraMetadata> readCameraMetadata(
  File snapshot,
  String sourcePath, {
  required bool raw,
}) async {
  final path = snapshot.path;
  final kind = p.extension(sourcePath).toLowerCase().replaceFirst('.', '');
  final extracted = await Isolate.run(() async {
    final file = File(path);
    try {
      if (_bmff.contains(kind)) {
        final values = readBmffCameraTags(await file.readAsBytes(), kind);
        return _metadata(values.artist, values.make, values.model);
      }
      if (_tiff.contains(kind) ||
          {'jpg', 'jpeg', 'mpo', 'png', 'webp'}.contains(kind)) {
        final tags = await exif.readExifFromFile(file, details: false);
        return _metadata(
          tags['Image Artist']?.printable,
          tags['Image Make']?.printable,
          tags['Image Model']?.printable,
        );
      }
      return const CameraMetadata('UNSUPPORTED');
    } catch (_) {
      return const CameraMetadata('PARSE_ERROR');
    }
  });
  if (!raw || (extracted.cameraMake != null && extracted.cameraModel != null)) {
    return extracted;
  }
  try {
    final document = await RawDocument.openFile(path);
    try {
      return _metadata(
        extracted.artist,
        extracted.cameraMake ?? document.metadata.cameraMake,
        extracted.cameraModel ?? document.metadata.cameraModel,
        empty: extracted.readStatus,
      );
    } finally {
      await document.close();
    }
  } catch (_) {
    // Metadata extraction is independent of the existing image validation.
    return extracted;
  }
}

CameraMetadata _metadata(
  String? artist,
  String? make,
  String? model, {
  String empty = 'NO_FIELDS',
}) {
  final values = [artist, make, model].map(_clean).toList();
  return CameraMetadata(
    empty == 'PARSE_ERROR' || empty == 'UNSUPPORTED'
        ? empty
        : (values.any((value) => value != null) ? 'READ' : 'NO_FIELDS'),
    artist: values[0],
    cameraMake: values[1],
    cameraModel: values[2],
  );
}

String? _clean(String? value) {
  final clean = value?.trim().replaceFirst(RegExp(r'\x00+$'), '').trim();
  if (clean == null ||
      clean.isEmpty ||
      clean.runes.length > 128 ||
      clean.runes.any((rune) => rune < 32 || (rune >= 127 && rune <= 159))) {
    return null;
  }
  return clean;
}
