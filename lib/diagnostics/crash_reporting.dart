import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../auto_upload/cos_upload.dart';
import '../printing/print_bridge.dart';
import '../profile_store.dart';
import '../release/update_service.dart';
import 'crash_journal.dart';

Future<CrashJournal?> startCrashReporting({
  required bool compatibility,
  required PrintBridge bridge,
}) async {
  if (!Platform.isWindows || !kReleaseMode) return null;
  try {
    final support = await getApplicationSupportDirectory();
    final package = await PackageInfo.fromPlatform();
    final journal = CrashJournal(
      Directory(p.join(support.path, 'diagnostics', updateChannel)),
      version: '${package.version}+${package.buildNumber}',
      compatibility: compatibility,
    );

    final flutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      journal.record(CrashEvent.flutterError);
      flutterError?.call(details);
    };
    final dispatcher = PlatformDispatcher.instance;
    final dartError = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      journal.record(CrashEvent.unhandledDartError);
      return dartError?.call(error, stack) ?? false;
    };

    var wasConnected = bridge.connected;
    var wasPrinting = bridge.printing;
    bridge.addListener(() {
      if (wasConnected != bridge.connected) {
        wasConnected = bridge.connected;
        journal.record(
          wasConnected
              ? CrashEvent.printConnected
              : CrashEvent.printDisconnected,
        );
      }
      if (wasPrinting != bridge.printing) {
        wasPrinting = bridge.printing;
        journal.record(
          wasPrinting ? CrashEvent.printStarted : CrashEvent.printIdle,
        );
      }
    });

    Future<void> upload() async {
      try {
        await journal.sendPending((report) => _send(report, bridge));
      } catch (_) {
        developer.log('Workstation crash reports remain queued for retry');
      }
    }

    Timer.periodic(const Duration(minutes: 5), (_) => unawaited(upload()));
    Timer(const Duration(seconds: 15), () => unawaited(upload()));
    return journal;
  } catch (_) {
    developer.log('Workstation crash journal initialization failed');
    return null;
  }
}

Future<bool> _send(Map<String, dynamic> report, PrintBridge bridge) async {
  final api = CosUploadProfile.tryParseApiBase(workstationUploadApiBase);
  if (api == null) throw StateError('Invalid workstation diagnostics origin');
  try {
    if (await _sendForStation(report, api)) return true;
  } catch (_) {
    developer.log('Workstation crash report could not use station credentials');
  }
  if (!bridge.connected || !bridge.configured) return false;
  return await bridge.call('sendCrashReport', [report]) == report['reportId'];
}

Future<bool> _sendForStation(Map<String, dynamic> report, Uri api) async {
  final stations = await const ProfileStore().loadStations(api);
  final client = http.Client();
  try {
    for (final station in stations.take(3)) {
      final url = api.replace(
        path:
            '/api/operation/workstation-upload/stations/${station.stationId}/crash-reports',
      );
      final request = http.Request('POST', url)
        ..followRedirects = false
        ..headers.addAll({
          'X-Workstation-Token': station.token,
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode(report);
      try {
        final response = await client
            .send(request)
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) continue;
        final payload = jsonDecode(response.body);
        if (payload is Map &&
            payload['code'] == 200 &&
            payload['data'] == report['reportId']) {
          return true;
        }
      } on TimeoutException {
        break;
      } on http.ClientException {
        break;
      } on FormatException {
        break;
      }
    }
  } finally {
    client.close();
  }
  return false;
}
