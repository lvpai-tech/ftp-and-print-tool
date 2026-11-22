import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import '../photo_normalizer.dart';

const _height = 48;
const _model = 'assets/card-ocr/inference.onnx';
const _dictionary = 'assets/card-ocr/characters.json';

img.Image _decode(Uint8List bytes) {
  final photo = img.decodeImage(normalizeJpegPrimary(bytes));
  if (photo == null) throw StateError('照片无法解码');
  return img.bakeOrientation(photo);
}

/// Preview and inference both use the EXIF-oriented pixel coordinates.
(Uint8List, Size) cardTailPreview(Uint8List bytes) {
  final photo = _decode(bytes);
  final resized = photo.width <= 1000 && photo.height <= 1000
      ? photo
      : img.copyResize(
          photo,
          width: photo.width >= photo.height ? 1000 : null,
          height: photo.height > photo.width ? 1000 : null,
          interpolation: img.Interpolation.average,
        );
  return (
    img.encodeJpg(resized, quality: 92),
    Size(resized.width.toDouble(), resized.height.toDouble()),
  );
}

(Float32List, int) _input((Uint8List, Rect) request) {
  final (bytes, selection) = request;
  final photo = _decode(bytes);
  final left = (selection.left * photo.width).floor();
  final top = (selection.top * photo.height).floor();
  final width = (selection.right * photo.width).ceil() - left;
  final height = (selection.bottom * photo.height).ceil() - top;
  if (width < 12 || height < 8) throw StateError('请框住完整四位数字');
  final crop = img.copyCrop(
    photo,
    x: left,
    y: top,
    width: width,
    height: height,
  );
  final scaledWidth = (width * _height / height).ceil();
  if (scaledWidth > 3200) throw StateError('选区过宽，请重新框选四位数字');
  final resized = img.copyResize(
    crop,
    width: scaledWidth,
    height: _height,
    interpolation: img.Interpolation.linear,
  );
  final paddedWidth = math.max(320, scaledWidth);
  final plane = _height * paddedWidth;
  final data = Float32List(3 * plane);
  for (final pixel in resized) {
    final index = pixel.y * paddedWidth + pixel.x;
    data[index] = pixel.bNormalized * 2 - 1;
    data[index + plane] = pixel.gNormalized * 2 - 1;
    data[index + 2 * plane] = pixel.rNormalized * 2 - 1;
  }
  return (data, paddedWidth);
}

/// Greedy CTC over the original vocabulary, then validate the complete string.
String? decodeCardTail(List<num> scores, List<String> labels) {
  final classes = labels.length;
  if (classes < 2 || scores.isEmpty || scores.length % classes != 0) {
    throw StateError('尾号模型输出尺寸不匹配');
  }
  final text = StringBuffer();
  var previous = 0;
  for (var offset = 0; offset < scores.length; offset += classes) {
    var best = 0;
    for (var index = 1; index < classes; index++) {
      if (scores[offset + index] > scores[offset + best]) best = index;
    }
    if (best != 0 && best != previous) {
      final confidence = scores[offset + best];
      if (!confidence.isFinite || confidence < 0.8) return null;
      text.write(labels[best]);
    }
    previous = best;
  }
  final candidate = text.toString();
  return RegExp(r'^[0-9]{4}$').hasMatch(candidate) ? candidate : null;
}

class CardTailRecognizer {
  static final shared = CardTailRecognizer._();
  CardTailRecognizer._();

  OrtSession? _session;
  List<String>? _labels;
  bool _running = false;

  Future<String?> recognize(Uint8List bytes, Rect selection) async {
    if (_running) throw StateError('上一张照片仍在识别，请稍后重试');
    _running = true;
    try {
      final (data, width) = await compute(_input, (bytes, selection));
      final labels = _labels ??= List<String>.from(
        jsonDecode(await rootBundle.loadString(_dictionary)) as List,
      );
      final session = _session ??= await OnnxRuntime().createSessionFromAsset(
        _model,
        options: OrtSessionOptions(intraOpNumThreads: 1, interOpNumThreads: 1),
      );
      final input = await OrtValue.fromList(data, [1, 3, _height, width]);
      try {
        final outputs = await session.run({session.inputNames.single: input});
        try {
          final output = outputs.values.single;
          if (output.shape.length != 3 ||
              output.shape.first != 1 ||
              output.shape.last != labels.length) {
            throw StateError('尾号模型输出格式不匹配');
          }
          final scores = (await output.asFlattenedList()).cast<num>();
          return decodeCardTail(scores, labels);
        } finally {
          for (final output in outputs.values) {
            await output.dispose();
          }
        }
      } finally {
        await input.dispose();
      }
    } finally {
      _running = false;
    }
  }
}
