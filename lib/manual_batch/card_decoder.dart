import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zxing_lib/zxing.dart';
import 'package:zxing_lib/common.dart';

/// 只在本机识别业务 Code128/二维码；识别结果只是分组建议，不能触发上传。
Future<String?> decodeCard(File file) async =>
    compute(decodeCardBytes, await file.readAsBytes());

Future<String?> decodeEndingBarcode(File file) async =>
    compute(_decodeEndingBarcode, await file.readAsBytes());

String? _decodeEndingBarcode(Uint8List bytes) =>
    decodeCardBytes(bytes, barcodeOnly: true);

String? cardSecret(String raw) {
  final query = Uri.tryParse(raw)?.queryParameters['qrSecret'];
  final value = (query ?? raw).trim().toUpperCase();
  return RegExp(r'^[A-Z0-9]{12}$').hasMatch(value) ? value : null;
}

String? decodeCardBytes(Uint8List bytes, {bool barcodeOnly = false}) {
  var image = img.decodeImage(bytes);
  if (image == null) throw StateError('照片无法解码，请检查文件是否完整');
  image = img.bakeOrientation(image);
  if (image.width > 1800 || image.height > 1800) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? 1800 : null,
      height: image.height > image.width ? 1800 : null,
    );
  }
  for (final angle in [0, 90, 180, 270]) {
    final rotated = angle == 0 ? image : img.copyRotate(image, angle: angle);
    for (final top in [0.55, 0.0]) {
      final y = (rotated.height * top).floor();
      final crop = img.copyCrop(
        rotated,
        x: 0,
        y: y,
        width: rotated.width,
        height: rotated.height - y,
      );
      final pixels = Int32List(crop.width * crop.height);
      for (final pixel in crop) {
        pixels[pixel.y * crop.width + pixel.x] =
            (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt();
      }
      final bitmap = BinaryBitmap(
        HybridBinarizer(RGBLuminanceSource(crop.width, crop.height, pixels)),
      );
      try {
        final result = MultiFormatReader().decode(
          bitmap,
          DecodeHint(
            tryHarder: true,
            possibleFormats: [
              BarcodeFormat.code128,
              if (!barcodeOnly) BarcodeFormat.qrCode,
            ],
          ),
        );
        final secret = cardSecret(result.text);
        if (secret != null) return secret;
      } on ReaderException {
        // 正常游客照没有业务条码，保留照片，等待摄影师选择结束照。
      }
    }
  }
  return null;
}
