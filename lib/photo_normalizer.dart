import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

/// 只处理私有待传副本。保留JPEG压缩数据、EXIF方向/拍摄时间和ICC色彩，绝不改相机源文件。
/// MPF的第一张为主图；移除其多图索引并截取到主图EOI，不重新编码像素。
Future<void> normalizePhotoSnapshot(File snapshot) =>
    Isolate.run(() => _normalize(snapshot.path));

void _normalize(String path) {
  final file = File(path);
  final source = file.readAsBytesSync();
  final result = normalizeJpegPrimary(source);
  if (!identical(source, result)) file.writeAsBytesSync(result, flush: true);
}

/// 非JPEG由现有解码校验决定；JPEG标记损坏或主图截断时明确失败。
Uint8List normalizeJpegPrimary(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0xff || bytes[1] != 0xd8) return bytes;
  final output = BytesBuilder(copy: false)..add(bytes.sublist(0, 2));
  var offset = 2;
  var mpf = false;
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
      return mpf ? output.takeBytes() : bytes;
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
    } else {
      output.add(bytes.sublist(markerStart, offset + length));
    }
    offset += length;
    entropy = marker == 0xda;
  }
  throw StateError('JPEG主图不完整，请等待照片写入完成');
}

/// MPO上传为标准JPEG文件名，源文件名保持不变。
String photoUploadExtension(String path) =>
    p.extension(path).toLowerCase() == '.mpo' ? '.jpg' : p.extension(path);
