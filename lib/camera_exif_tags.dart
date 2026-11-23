import 'dart:convert';
import 'dart:typed_data';

/// Read only the three IFD0 text tags, without walking private directories.
({String? artist, String? make, String? model}) cameraTagsFromTiff(
  ByteData tiff,
) {
  final order = switch (tiff.getUint16(0)) {
    0x4949 => Endian.little,
    0x4d4d => Endian.big,
    _ => throw const FormatException('Invalid EXIF byte order'),
  };
  if (tiff.getUint16(2, order) != 42) {
    throw const FormatException('Invalid EXIF header');
  }
  final directory = tiff.getUint32(4, order);
  final entries = tiff.getUint16(directory, order);
  if (directory + 2 + entries * 12 > tiff.lengthInBytes) {
    throw const FormatException('Invalid EXIF directory');
  }
  final values = <int, String>{};
  for (var i = 0; i < entries; i++) {
    final entry = directory + 2 + i * 12;
    final tag = tiff.getUint16(entry, order);
    if (!const {0x013b, 0x010f, 0x0110}.contains(tag)) continue;
    final type = tiff.getUint16(entry + 2, order);
    final count = tiff.getUint32(entry + 4, order);
    if ((type != 2 && type != 129) || count == 0 || count > 513) continue;
    final offset = count <= 4 ? entry + 8 : tiff.getUint32(entry + 8, order);
    if (offset > tiff.lengthInBytes - count) continue;
    final bytes = Uint8List.view(
      tiff.buffer,
      tiff.offsetInBytes + offset,
      count,
    );
    try {
      values[tag] = utf8.decode(bytes);
    } on FormatException {
      if (type == 2) values[tag] = latin1.decode(bytes);
    }
  }
  return (artist: values[0x013b], make: values[0x010f], model: values[0x0110]);
}
