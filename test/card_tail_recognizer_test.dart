import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/auto_upload/folder_uploader.dart';
import 'package:lvpai_ftp_client/manual_batch/card_tail_recognizer.dart';
import 'package:path/path.dart' as p;

void main() {
  test('CTC keeps leading zero and blank-separated repeated digits', () {
    const labels = ['', '0', '5', 'X'];
    List<double> scores(List<int> sequence, {double confidence = 0.99}) => [
      for (final winner in sequence)
        for (var index = 0; index < labels.length; index++)
          index == winner ? confidence : 0.0,
    ];
    expect(decodeCardTail(scores([1, 1, 0, 2, 0, 2, 1, 2, 1]), labels), '055050');
    expect(decodeCardTail(scores([1, 2, 1, 2, 1, 2]), labels), '050505');
    expect(decodeCardTail(scores([1, 2, 1, 2]), labels), isNull);
    expect(decodeCardTail(scores([1, 2, 1, 2, 1]), labels), isNull);
    expect(decodeCardTail(scores([1, 2, 0, 2, 3]), labels), isNull);
    expect(
      decodeCardTail(scores([1, 2, 1, 2, 1, 2], confidence: 0.6), labels),
      isNull,
    );
    expect(decodeCardTail(scores([1, 2, 2, 1]), labels), isNull);
  });

  test(
    'auto queue reviews the snapshot or the same original after upload',
    () async {
      final folder = await Directory.systemTemp.createTemp('card-tail-review-');
      addTearDown(() => folder.delete(recursive: true));
      final source = File(p.join(folder.path, 'source.png'));
      final snapshot = File(p.join(folder.path, 'snapshot.png'));
      final bytes = [1, 2, 3];
      await source.writeAsBytes([4, 5, 6]);
      await snapshot.writeAsBytes(bytes);
      final job = AutoJob(
        id: 'id',
        source: source.path,
        relative: 'source.png',
        signature: 'signature',
        digest: sha256.convert(bytes).toString(),
        snapshot: snapshot.path,
      );
      expect(await job.readPhotoForReview(), bytes);
      await snapshot.delete();
      await expectLater(job.readPhotoForReview(), throwsStateError);
      await source.writeAsBytes(bytes);
      expect(await job.readPhotoForReview(), bytes);
    },
  );
}
