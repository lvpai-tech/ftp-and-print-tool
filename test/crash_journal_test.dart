import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/diagnostics/crash_journal.dart';

void main() {
  test(
    'next launch retries a bounded log after the previous run is interrupted',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workstation-crash-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final interrupted = CrashJournal(
        directory,
        version: '0.4.5+9',
        compatibility: true,
      );
      for (var i = 0; i < 70; i++) {
        interrupted.record(CrashEvent.windowRestored);
      }
      interrupted.record(CrashEvent.printStarted);
      final next = CrashJournal(
        directory,
        version: '0.4.5+9',
        compatibility: false,
      );
      Object? reportId;
      await next.sendPending((report) async {
        reportId = report['reportId'];
        expect(report['renderer'], 'COMPATIBILITY');
        expect(report['events'], hasLength(64));
        expect((report['events'] as List).last['code'], 'PRINT_STARTED');
        return false;
      });
      expect(reportId, isNotNull);
      expect(directory.listSync(), hasLength(2));

      await next.sendPending((report) async {
        expect(report['reportId'], reportId);
        return true;
      });
      expect(directory.listSync(), hasLength(1));
      next.close();
      expect(directory.listSync(), isEmpty);
    },
  );
}
