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

img.Image _decode(Uint8List bytes, String? sourcePath) {
  final photo = img.decodeImage(
    normalizeJpegPrimary(bytes, sourcePath: sourcePath),
  );
  if (photo == null) throw StateError('照片无法解码');
  return img.bakeOrientation(photo);
}

/// Preview and inference both use the EXIF-oriented pixel coordinates.
(Uint8List, Size) cardTailPreview(Uint8List bytes, {String? sourcePath}) {
  final photo = _decode(bytes, sourcePath);
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

List<(Float32List, int)> _inputs((Uint8List, Rect?, String?) request) {
  final (bytes, selection, sourcePath) = request;
  final photo = _decode(bytes, sourcePath);
  if (selection != null) return [_input(photo, selection)];

  // The model reads one line. Scan overlapping bands at two scales so a
  // printed line surrounded by the rest of the photo can still be read.
  return [
    _input(photo, const Rect.fromLTRB(0, 0, 1, 1), capWidth: true),
    for (final left in [0.0, .2, .4])
      for (var row = 8; row >= 0; row--)
        if (photo.height * .2 >= 8 && photo.width * .6 >= 12)
          _input(photo, Rect.fromLTWH(left, row / 10, .6, .2), capWidth: true),
  ];
}

(Float32List, int) _input(
  img.Image photo,
  Rect selection, {
  bool capWidth = false,
}) {
  final left = (selection.left * photo.width).floor();
  final top = (selection.top * photo.height).floor();
  final width = (selection.right * photo.width).ceil() - left;
  final height = (selection.bottom * photo.height).ceil() - top;
  if (width < 12 || height < 8) throw StateError('请框住完整尾号');
  final crop = img.copyCrop(
    photo,
    x: left,
    y: top,
    width: width,
    height: height,
  );
  final naturalWidth = (width * _height / height).ceil();
  if (naturalWidth > 3200 && !capWidth) {
    throw StateError('选区过宽，请重新框选完整尾号');
  }
  final scaledWidth = math.min(naturalWidth, 3200);
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
String? decodeCardTail(
  List<num> scores,
  List<String> labels, {
  bool wholeImage = false,
}) {
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
  final pattern = wholeImage
      ? RegExp(r'^(?:[A-Z]{2,8}-)?([0-9]{6})$')
      : RegExp(r'^([0-9]{6})$');
  return pattern.firstMatch(candidate)?.group(1);
}

class CardTailRecognizer {
  static final shared = CardTailRecognizer._();
  CardTailRecognizer._();

  OrtSession? _session;
  List<String>? _labels;
  bool _running = false;

  Future<String?> recognize(
    Uint8List bytes,
    Rect? selection, {
    String? sourcePath,
  }) async {
    if (_running) throw StateError('上一张照片仍在识别，请稍后重试');
    _running = true;
    try {
      final inputs = await compute(_inputs, (bytes, selection, sourcePath));
      final labels = _labels ??= List<String>.from(
        jsonDecode(await rootBundle.loadString(_dictionary)) as List,
      );
      final session = _session ??= await OnnxRuntime().createSessionFromAsset(
        _model,
        options: OrtSessionOptions(intraOpNumThreads: 1, interOpNumThreads: 1),
      );
      String? candidate;
      for (final (data, width) in inputs) {
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
            final tail = decodeCardTail(
              scores,
              labels,
              wholeImage: selection == null,
            );
            if (tail != null) {
              if (candidate != null && candidate != tail) return null;
              candidate = tail;
            }
          } finally {
            for (final output in outputs.values) {
              await output.dispose();
            }
          }
        } finally {
          await input.dispose();
        }
      }
      return candidate;
    } finally {
      _running = false;
    }
  }
}
