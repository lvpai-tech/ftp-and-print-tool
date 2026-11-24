import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

enum CrashEvent {
  start('START'),
  desktopReady('DESKTOP_READY'),
  desktopInitFailed('DESKTOP_INIT_FAILED'),
  windowMinimized('WINDOW_MINIMIZED'),
  windowRestored('WINDOW_RESTORED'),
  windowHidden('WINDOW_HIDDEN'),
  windowShown('WINDOW_SHOWN'),
  windowResized('WINDOW_RESIZED'),
  windowMoved('WINDOW_MOVED'),
  flutterError('FLUTTER_ERROR'),
  unhandledDartError('UNHANDLED_DART_ERROR'),
  uploadListening('UPLOAD_LISTENING'),
  uploadStopped('UPLOAD_STOPPED'),
  uploadStarted('UPLOAD_STARTED'),
  uploadIdle('UPLOAD_IDLE'),
  printConnected('PRINT_CONNECTED'),
  printDisconnected('PRINT_DISCONNECTED'),
  printStarted('PRINT_STARTED'),
  printIdle('PRINT_IDLE');

  const CrashEvent(this.code);
  final String code;
}

/// Stores only predefined activity codes so a native crash cannot lose
/// previously written events or expose app error strings or photo data.
class CrashJournal {
  CrashJournal(
    this.directory, {
    required this.version,
    required bool compatibility,
  }) : _renderer = compatibility ? 'COMPATIBILITY' : 'DEFAULT',
       _startedAt = DateTime.now().millisecondsSinceEpoch,
       _id = List.generate(
         16,
         (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
       ).join() {
    directory.createSync(recursive: true);
    record(CrashEvent.start);
  }

  static final _random = Random.secure();
  static final _filename = RegExp(r'^[a-f0-9]{32}\.json$');
  static final _unfinished = RegExp(r'^[a-f0-9]{32}\.json\.tmp$');
  static const _maxEvents = 64;
  static const _maxPending = 5;
  static const _maxBytes = 8192;
  final Directory directory;
  final String version;
  final String _renderer;
  final int _startedAt;
  final String _id;
  final _events = <Map<String, Object>>[];
  bool _sending = false;
  bool _closed = false;
  File get _current => File(p.join(directory.path, '$_id.json'));

  void record(CrashEvent event) {
    if (_closed) return;
    if (_events.length == _maxEvents) _events.removeAt(0);
    _events.add({
      'code': event.code,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    try {
      final pending = File('${_current.path}.tmp');
      pending.writeAsStringSync(
        jsonEncode({
          'reportId': _id,
          'version': version,
          'renderer': _renderer,
          'startedAt': _startedAt,
          'events': _events,
        }),
        flush: true,
      );
      pending.renameSync(_current.path);
    } on FileSystemException catch (error) {
      developer.log(
        'Workstation crash journal write failed (${error.osError?.errorCode})',
      );
    }
  }

  void close() {
    try {
      if (_current.existsSync()) _current.deleteSync();
    } on FileSystemException catch (error) {
      developer.log(
        'Workstation crash journal close failed (${error.osError?.errorCode})',
      );
    }
    _closed = true;
  }

  void resume() {
    if (!_closed) return;
    _closed = false;
    record(CrashEvent.desktopReady);
  }

  /// Keeps a bounded backlog when credentials, the network or server are unavailable.
  Future<void> sendPending(
    Future<bool> Function(Map<String, dynamic> report) send,
  ) async {
    if (_sending || _closed) return;
    _sending = true;
    try {
      final entries = await directory.list(followLinks: false).toList();
      for (final file in entries.whereType<File>()) {
        if (p.basename(file.path) != '$_id.json.tmp' &&
            _unfinished.hasMatch(p.basename(file.path))) {
          await file.delete();
        }
      }
      final previous =
          entries.whereType<File>().where((file) {
            return file.path != _current.path &&
                _filename.hasMatch(p.basename(file.path));
          }).toList()..sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );
      for (final file in previous.skip(_maxPending)) {
        await file.delete();
      }
      for (final file in previous.take(_maxPending)) {
        if (_closed) return;
        if (await file.length() > _maxBytes) {
          await file.delete();
          continue;
        }
        final String content = await file.readAsString();
        final Map<String, dynamic> report;
        try {
          report = jsonDecode(content) as Map<String, dynamic>;
          if (report['reportId'] != p.basenameWithoutExtension(file.path)) {
            throw const FormatException('Crash report ID does not match file');
          }
        } on FormatException {
          await file.delete();
          continue;
        } on TypeError {
          await file.delete();
          continue;
        }
        if (!await send(report)) return;
        await file.delete();
      }
    } finally {
      _sending = false;
    }
  }
}
