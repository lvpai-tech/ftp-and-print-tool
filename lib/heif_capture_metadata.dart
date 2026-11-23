import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'camera_exif_tags.dart';

typedef _Box = ({String type, int data, int end});
typedef AvifCrop = ({
  double width,
  double height,
  double xOffset,
  double yOffset,
});
typedef AvifCaptureMetadata = ({
  img.ExifData? exif,
  int rotation,
  int? mirror,
  AvifCrop? crop,
  ByteData? originalExif,
});
const _invalid = 'HEIF / AVIF 拍摄信息损坏或使用了不支持的布局';

/// Read capture time from the HEIF Exif item before converting pixels to JPEG.
/// A valid photo without an Exif item has no capture time to copy.
img.ExifData? readHeifCaptureMetadata(Uint8List bytes) =>
    _readCaptureMetadata(bytes).exif;

AvifCaptureMetadata readAvifCaptureMetadata(Uint8List bytes) =>
    _readCaptureMetadata(bytes, avif: true);

({String? artist, String? make, String? model}) readBmffCameraTags(
  Uint8List bytes,
  String kind,
) {
  final tiff = _readCaptureMetadata(
    bytes,
    avif: kind == 'avif',
    cameraTagsOnly: true,
  ).originalExif;
  return tiff == null
      ? (artist: null, make: null, model: null)
      : cameraTagsFromTiff(tiff);
}

AvifCaptureMetadata _readCaptureMetadata(
  Uint8List bytes, {
  bool avif = false,
  bool cameraTagsOnly = false,
}) {
  final format = avif ? 'AVIF' : 'HEIF';
  final data = ByteData.sublistView(bytes);
  final boxes = _boxes(data, 0, data.lengthInBytes).iterator;
  if (!boxes.moveNext() || boxes.current.type != 'ftyp') {
    throw StateError('文件内容不是 $format');
  }
  final ftyp = boxes.current;
  final length = ftyp.end - ftyp.data;
  if (length < 8 || length % 4 != 0) throw StateError(_invalid);
  final brands = {
    _fourcc(data, ftyp.data),
    for (var offset = ftyp.data + 8; offset < ftyp.end; offset += 4)
      _fourcc(data, offset),
  };
  if (avif) {
    if (brands.contains('avis')) throw StateError('请选择静态 AVIF 照片');
    if (!brands.contains('avif')) throw StateError('文件内容不是 AVIF');
  } else if (brands.contains('avif') ||
      brands.contains('avis') ||
      !brands.any({'mif1', 'heic', 'heix', 'heim', 'heis'}.contains)) {
    throw StateError('文件内容不是受支持的 HEIF 照片');
  }

  while (boxes.moveNext()) {
    final meta = boxes.current;
    if (meta.type != 'meta') continue;
    final children = {
      for (final box in _boxes(data, meta.data + 4, meta.end)) box.type: box,
    };
    final (rotation, mirror, crop) = avif && !cameraTagsOnly
        ? _avifTransform(data, children)
        : (0, null, null);
    final info = children['iinf'];
    if (info == null || info.end - info.data < 6) throw StateError(_invalid);
    final version = data.getUint8(info.data);
    int? exifId;
    for (final entry in _boxes(
      data,
      info.data + (version == 0 ? 6 : 8),
      info.end,
    )) {
      if (entry.type != 'infe') continue;
      final fields = _Fields(data, entry);
      final entryVersion = fields.read(1);
      if (entryVersion != 2 && entryVersion != 3) continue;
      fields.read(3); // FullBox flags.
      final id = fields.read(entryVersion == 2 ? 2 : 4);
      fields.read(2); // Item protection index.
      if (fields.read(4) != 0x45786966) continue; // Exif item type.
      if (exifId != null) throw StateError('$format 含多份 EXIF，无法确定拍摄时间');
      exifId = id;
    }
    if (exifId == null) {
      return (
        exif: null,
        rotation: rotation,
        mirror: mirror,
        crop: crop,
        originalExif: null,
      );
    }
    final locations = children['iloc'];
    if (locations == null) throw StateError(_invalid);
    final tiff = _exifTiff(data, locations, children['idat'], exifId);
    return (
      exif: cameraTagsOnly ? null : _captureTags(tiff),
      rotation: rotation,
      mirror: mirror,
      crop: crop,
      originalExif: cameraTagsOnly ? tiff : null,
    );
  }
  throw StateError(_invalid);
}

(int, int?, AvifCrop?) _avifTransform(
  ByteData data,
  Map<String, _Box> children,
) {
  final primary = children['pitm'];
  final properties = children['iprp'];
  if (primary == null || properties == null) throw StateError(_invalid);
  final item = _Fields(data, primary);
  final version = item.read(1);
  if (version > 1) throw StateError(_invalid);
  item.skip(3);
  final primaryId = item.read(version == 0 ? 2 : 4);
  final boxes = _boxes(data, properties.data, properties.end).toList();
  final container = boxes.where((box) => box.type == 'ipco').singleOrNull;
  if (container == null) throw StateError(_invalid);
  final entries = _boxes(data, container.data, container.end).toList();
  var rotation = 0;
  int? mirror;
  AvifCrop? crop;
  for (final box in boxes.where((box) => box.type == 'ipma')) {
    final fields = _Fields(data, box);
    final version = fields.read(1);
    if (version > 1) throw StateError(_invalid);
    final indexWidth = (fields.read(3) & 1) == 0 ? 1 : 2;
    final indexMask = indexWidth == 1 ? 0x7f : 0x7fff;
    final count = fields.read(4);
    for (var index = 0; index < count; index++) {
      final id = fields.read(version == 0 ? 2 : 4);
      final associations = fields.read(1);
      if (id != primaryId) {
        fields.skip(associations * indexWidth);
        continue;
      }
      for (var association = 0; association < associations; association++) {
        final property = fields.read(indexWidth) & indexMask;
        if (property == 0) continue;
        if (property > entries.length) throw StateError(_invalid);
        final entry = entries[property - 1];
        switch (entry.type) {
          case 'irot':
            rotation = _Fields(data, entry).read(1) & 3;
          case 'imir':
            mirror = _Fields(data, entry).read(1) & 1;
          case 'clap':
            final aperture = _Fields(data, entry);
            crop = (
              width: aperture.fraction(),
              height: aperture.fraction(),
              xOffset: aperture.fraction(signed: true),
              yOffset: aperture.fraction(signed: true),
            );
        }
      }
    }
  }
  return (rotation, mirror, crop);
}

Iterable<_Box> _boxes(ByteData data, int start, int end) sync* {
  if (start > end) throw StateError(_invalid);
  for (var offset = start; offset < end;) {
    if (end - offset < 8) throw StateError(_invalid);
    var size = data.getUint32(offset);
    final header = size == 1 ? 16 : 8;
    if (end - offset < header) throw StateError(_invalid);
    if (size == 1) size = data.getUint64(offset + 8);
    if (size == 0 && header == 8) size = end - offset;
    if (size < header || size > end - offset) throw StateError(_invalid);
    yield (
      type: _fourcc(data, offset + 4),
      data: offset + header,
      end: offset + size,
    );
    offset += size;
  }
}

String _fourcc(ByteData data, int offset) => String.fromCharCodes(
  Uint8List.view(data.buffer, data.offsetInBytes + offset, 4),
);

ByteData _exifTiff(ByteData data, _Box locations, _Box? itemData, int exifId) {
  final fields = _Fields(data, locations);
  final version = fields.read(1);
  if (version > 2) throw StateError(_invalid);
  fields.read(3);
  final sizes = fields.read(2);
  final offsetWidth = sizes >> 12;
  final lengthWidth = (sizes >> 8) & 15;
  final baseWidth = (sizes >> 4) & 15;
  final indexWidth = version == 0 ? 0 : sizes & 15;
  final idWidth = version == 2 ? 4 : 2;
  final itemCount = fields.read(idWidth);
  for (var item = 0; item < itemCount; item++) {
    final id = fields.read(idWidth);
    final method = version == 0 ? 0 : fields.read(2) & 15;
    final reference = fields.read(2);
    final base = fields.read(baseWidth);
    final count = fields.read(2);
    if (id != exifId) {
      fields.skip(count * (indexWidth + offsetWidth + lengthWidth));
      continue;
    }
    if (reference != 0 ||
        method > 1 ||
        (method == 1 && itemData == null) ||
        count == 0) {
      throw StateError(_invalid);
    }
    final origin = method == 1 ? itemData!.data : 0;
    final end = method == 1 ? itemData!.end : data.lengthInBytes;
    final payload = BytesBuilder(copy: false);
    var total = 0;
    for (var extent = 0; extent < count; extent++) {
      fields.read(indexWidth);
      final offset = fields.read(offsetWidth);
      final length = fields.read(lengthWidth);
      if (base > end - origin ||
          offset > end - origin - base ||
          length == 0 ||
          length > end - origin - base - offset ||
          length > 1048576 - total) {
        throw StateError(_invalid);
      }
      payload.add(
        Uint8List.view(
          data.buffer,
          data.offsetInBytes + origin + base + offset,
          length,
        ),
      );
      total += length;
    }
    final bytes = payload.takeBytes();
    if (bytes.length < 12) throw StateError(_invalid);
    final start = 4 + ByteData.sublistView(bytes).getUint32(0);
    if (start > bytes.length - 8) throw StateError(_invalid);
    return ByteData.sublistView(bytes, start);
  }
  throw StateError(_invalid);
}

img.ExifData? _captureTags(ByteData tiff) {
  final order = switch (tiff.getUint16(0)) {
    0x4949 => Endian.little,
    0x4d4d => Endian.big,
    _ => throw StateError(_invalid),
  };
  if (tiff.getUint16(2, order) != 42) throw StateError(_invalid);
  int? captureDirectory;
  for (final entry in _ifdEntries(tiff, tiff.getUint32(4, order), order)) {
    if (tiff.getUint16(entry, order) == 0x8769) {
      captureDirectory = tiff.getUint32(entry + 8, order);
      break;
    }
  }
  if (captureDirectory == null) return null;
  final metadata = img.ExifData();
  for (final entry in _ifdEntries(tiff, captureDirectory, order)) {
    final tag = tiff.getUint16(entry, order);
    if (!const {0x9003, 0x9011, 0x9291}.contains(tag)) continue;
    final count = tiff.getUint32(entry + 4, order);
    if (tiff.getUint16(entry + 2, order) != 2 || count < 2 || count > 64) {
      throw StateError(_invalid);
    }
    final offset = count <= 4 ? entry + 8 : tiff.getUint32(entry + 8, order);
    if (offset > tiff.lengthInBytes - count ||
        tiff.getUint8(offset + count - 1) != 0) {
      throw StateError(_invalid);
    }
    final value = String.fromCharCodes(
      Uint8List.view(tiff.buffer, tiff.offsetInBytes + offset, count - 1),
    );
    if (value.trim().isNotEmpty) {
      metadata.exifIfd[tag] = img.IfdValueAscii(value);
    }
  }
  if (metadata.exifIfd[0x9003] == null) return null;
  metadata.imageIfd.orientation =
      1; // The converter applies orientation to pixels.
  return metadata;
}

Iterable<int> _ifdEntries(ByteData tiff, int offset, Endian order) sync* {
  if (offset < 8 || offset > tiff.lengthInBytes - 2) throw StateError(_invalid);
  final count = tiff.getUint16(offset, order);
  if (offset + 2 + 12 * count > tiff.lengthInBytes) throw StateError(_invalid);
  for (var index = 0; index < count; index++) {
    yield offset + 2 + 12 * index;
  }
}

class _Fields {
  _Fields(this.data, _Box box) : position = box.data, end = box.end;

  final ByteData data;
  final int end;
  int position;
  double fraction({bool signed = false}) {
    var numerator = read(4);
    final denominator = read(4);
    if (denominator == 0) throw StateError(_invalid);
    if (signed && numerator >= 0x80000000) numerator -= 0x100000000;
    return numerator / denominator;
  }

  void skip(int size) {
    if (size > end - position) throw StateError(_invalid);
    position += size;
  }

  int read(int width) {
    if (width > 8 || width > end - position) throw StateError(_invalid);
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = (value << 8) | data.getUint8(position++);
    }
    if (value < 0) throw StateError(_invalid);
    return value;
  }
}
