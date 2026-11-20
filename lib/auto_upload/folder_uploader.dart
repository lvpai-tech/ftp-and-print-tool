import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../transfer.dart';
import '../photo_normalizer.dart';
import 'journal.dart';

class AutoJob {
  final String id, source, relative, signature, digest, snapshot;
  String state;
  String error;
  int attempts;
  DateTime nextAttempt;
  double progress = 0;
  AutoJob({
    required this.id,
    required this.source,
    required this.relative,
    required this.signature,
    required this.digest,
    required this.snapshot,
    this.state = 'pending',
    this.error = '',
    this.attempts = 0,
    DateTime? nextAttempt,
  }) : nextAttempt = nextAttempt ?? DateTime.fromMillisecondsSinceEpoch(0);
  Map<String, dynamic> toJson() => {
    'type': 'job',
    'id': id,
    'source': source,
    'relative': relative,
    'signature': signature,
    'digest': digest,
    'snapshot': snapshot,
    'state': state,
    'error': error,
    'attempts': attempts,
    'nextAttempt': nextAttempt.millisecondsSinceEpoch,
  };
  factory AutoJob.fromJson(Map<String, dynamic> v) => AutoJob(
    id: v['id'] as String,
    source: v['source'] as String,
    relative: v['relative'] as String,
    signature: v['signature'] as String,
    digest: v['digest'] as String,
    snapshot: v['snapshot'] as String,
    state: v['state'] as String,
    error: v['error'] as String,
    attempts: v['attempts'] as int,
    nextAttempt: DateTime.fromMillisecondsSinceEpoch(v['nextAttempt'] as int),
  );
}

class _Observation {
  final String signature;
  final DateTime since;
  _Observation(this.signature, this.since);
}

/// 事件触发和定时补扫并用；扫描、落盘及上传各自串行，上传不阻塞新图发现。
class FolderUploader extends ChangeNotifier {
  final Directory storage;
  final Duration scanInterval, stableFor, retryDelay;
  final Future<bool> Function(File) validateImage;
  final Map<String, AutoJob> _jobs = {};
  final Map<String, String> _seen = {}, _ignored = {};
  final Map<String, _Observation> _observations = {};
  final Map<String, String> issues = {};
  QueueJournal? _journal;
  StreamSubscription<FileSystemEvent>? _events;
  Timer? _timer, _debounce, _progressTimer;
  ServerProfile? _profile;
  Directory? _root;
  Future<void>? _scanTask, _pumpTask;
  bool running = false, stopping = false, _initialized = false, _closed = false;
  bool _recursive = true, _includeExisting = false;
  String message = '选择接收相机照片的文件夹，点击开始监听';
  String watcherNotice = '';
  String? fatalError;
  List<AutoJob> get jobs => _jobs.values.toList().reversed.toList();
  int get settling => _observations.length;

  FolderUploader({
    required this.storage,
    this.scanInterval = const Duration(seconds: 2),
    this.stableFor = const Duration(seconds: 3),
    this.retryDelay = const Duration(seconds: 5),
    Future<bool> Function(File)? validateImage,
  }) : validateImage = validateImage ?? _decodeImage;

  static Future<bool> _decodeImage(File file) async {
    final input = await file.open();
    try {
      final length = await input.length();
      if (length < 16) return false;
      final head = await input.read(8);
      await input.setPosition(length - 12);
      final tail = await input.read(12);
      final jpeg =
          head[0] == 0xff &&
          head[1] == 0xd8 &&
          head[2] == 0xff &&
          tail[10] == 0xff &&
          tail[11] == 0xd9;
      final png =
          listEquals(head, [137, 80, 78, 71, 13, 10, 26, 10]) &&
          listEquals(tail, [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]);
      if (!jpeg && !png) return false;
    } finally {
      await input.close();
    }
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final codec = await descriptor.instantiateCodec(
          targetWidth: 64,
          targetHeight: 64,
        );
        try {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
          return true;
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  void _notify() {
    _cancelProgressNotification();
    if (!_closed) notifyListeners();
  }

  void _cancelProgressNotification() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  String _signature(FileStat s) =>
      '${s.size}:${s.modified.microsecondsSinceEpoch}';
  String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

  Future<void> _append(Map<String, dynamic> event) async {
    try {
      await _journal!.append(event);
    } catch (_) {
      _fail();
      throw const _PersistenceFailure();
    }
  }

  Future<void> start(
    Directory root,
    ServerProfile profile, {
    bool recursive = true,
    bool includeExisting = false,
  }) async {
    if (running || stopping || _journal != null) throw StateError('请先停止当前监听');
    if (!Platform.isWindows &&
        !Platform.isMacOS &&
        !Platform.isLinux &&
        !Platform.isIOS) {
      throw StateError('当前平台不支持目录监听');
    }
    final absolute = Directory(await root.resolveSymbolicLinks());
    if (p.isWithin(absolute.path, storage.absolute.path) ||
        p.equals(absolute.path, storage.absolute.path)) {
      throw StateError('监听目录不能包含应用待传区');
    }
    _root = absolute;
    _profile = profile;
    _recursive = recursive;
    _includeExisting = includeExisting;
    _jobs.clear();
    _seen.clear();
    _ignored.clear();
    _observations.clear();
    issues.clear();
    fatalError = null;
    _initialized = false;
    final key = _hash(
      '${absolute.path}\u0000${profile.host.toLowerCase()}\u0000'
      '${profile.port}\u0000${profile.user}\u0000${profile.directory}',
    );
    final journal = QueueJournal(
      File(p.join(storage.path, key, 'queue.jsonl')),
    );
    try {
      for (final event in await journal.open()) {
        switch (event['type']) {
          case 'initialized':
            _initialized = true;
            if (event['ignored'] != null) {
              _ignored.addAll(
                Map<String, String>.from(event['ignored'] as Map),
              );
            }
          case 'ignore':
            _ignored[event['source'] as String] = event['signature'] as String;
          case 'job':
            final job = AutoJob.fromJson(event);
            if (job.state == 'uploading') job.state = 'pending';
            _jobs[job.id] = job;
            _seen[job.source] = job.signature;
          default:
            throw StateError('队列日志版本无法识别');
        }
      }
      _journal = journal;
      running = true;
      message = '正在监听 · 文件稳定后自动上传';
      watcherNotice = '';
      try {
        _events = absolute
            .watch(recursive: recursive)
            .listen(
              (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), _tick);
              },
              onError: (Object error) {
                watcherNotice = '系统文件事件不可用，仍每${scanInterval.inSeconds}秒补扫';
                _notify();
              },
            );
      } catch (_) {
        watcherNotice = '系统文件事件不可用，仍每${scanInterval.inSeconds}秒补扫';
      }
      _timer = Timer.periodic(scanInterval, (_) => _tick());
      await scanNow();
      _tick();
      _notify();
    } catch (_) {
      running = false;
      _timer?.cancel();
      _debounce?.cancel();
      await _events?.cancel();
      _journal = null;
      await journal.close();
      rethrow;
    }
  }

  void _tick() {
    if (!running || _closed) return;
    unawaited(scanNow().catchError((Object error) => _fail()));
    _pumpTask ??= _pump().catchError((Object error) => _fail()).whenComplete(
      () {
        _pumpTask = null;
      },
    );
  }

  void _fail() {
    fatalError = '队列持久化或读取失败，已停止自动任务；请检查磁盘和目录权限后停止并重启监听';
    running = false;
    _timer?.cancel();
    _debounce?.cancel();
    _notify();
  }

  Future<void> scanNow() {
    if (!running) return Future.value();
    return _scanTask ??= _scan().whenComplete(() {
      _scanTask = null;
      if (running) {
        _pumpTask ??= _pump()
            .catchError((Object error) => _fail())
            .whenComplete(() => _pumpTask = null);
      }
    });
  }

  Future<void> _scan() async {
    final files = <File>[];
    try {
      await for (final entity in _root!.list(
        recursive: _recursive,
        followLinks: false,
      )) {
        if (entity is File &&
            [
              '.jpg',
              '.jpeg',
              '.mpo',
              '.png',
            ].contains(p.extension(entity.path).toLowerCase())) {
          files.add(entity);
        }
      }
    } on FileSystemException {
      message = '无法读取监听目录，等待恢复；请检查磁盘、目录和权限';
      _notify();
      return;
    }
    if (!running) return;
    message = '正在监听 · 文件稳定后自动上传';
    if (!_initialized) {
      // 首次快照先固定忽略集合，防止初始化途中新增照片被当作历史图。
      final baseline = <String, String>{};
      for (final file in files) {
        if (!_includeExisting) {
          final stat = await file.stat();
          if (stat.type == FileSystemEntityType.file) {
            final signature = _signature(stat);
            baseline[file.path] = signature;
          }
        }
      }
      await _append({'type': 'initialized', 'ignored': baseline});
      _ignored.addAll(baseline);
      _initialized = true;
    }
    final present = files.map((f) => f.path).toSet();
    _observations.removeWhere((path, _) => !present.contains(path));
    issues.removeWhere((path, _) => !present.contains(path));
    for (final file in files) {
      if (!running) break;
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) continue;
      final signature = _signature(stat);
      if (_seen[file.path] == signature ||
          (!_includeExisting && _ignored[file.path] == signature)) {
        _observations.remove(file.path);
        continue;
      }
      final observed = _observations[file.path];
      if (observed == null || observed.signature != signature) {
        _observations[file.path] = _Observation(signature, DateTime.now());
        issues.remove(file.path);
        continue;
      }
      if (DateTime.now().difference(observed.since) < stableFor ||
          stat.size == 0) {
        continue;
      }
      File? snapshot;
      try {
        final tempDir = Directory(
          p.join(_journal!.file.parent.path, 'pending'),
        );
        await tempDir.create(recursive: true);
        snapshot = File(
          p.join(
            tempDir.path,
            'capture-${DateTime.now().microsecondsSinceEpoch}${photoUploadExtension(file.path)}',
          ),
        );
        await file.copy(snapshot.path);
        if (_signature(await file.stat()) != signature ||
            await snapshot.length() != stat.size) {
          _observations.remove(file.path);
          continue;
        }
        await normalizePhotoSnapshot(snapshot);
        try {
          if (!await validateImage(snapshot)) throw StateError('照片无法解码');
        } catch (_) {
          throw StateError('照片无法解码');
        }
        final digest = (await sha256.bind(snapshot.openRead()).first)
            .toString();
        if (_signature(await file.stat()) != signature) {
          _observations.remove(file.path);
          continue;
        }
        var relative = p
            .relative(file.path, from: _root!.path)
            .split(p.separator)
            .join('/');
        if (p.extension(relative).toLowerCase() == '.mpo') {
          relative = p.setExtension(relative, '.jpg');
        }
        final id = _hash('$relative\u0000$digest');
        if (_jobs.containsKey(id)) {
          _seen[file.path] = signature;
          _observations.remove(file.path);
          continue;
        }
        final stableSnapshot = await snapshot.rename(
          p.join(tempDir.path, '$id${photoUploadExtension(file.path)}'),
        );
        snapshot = stableSnapshot;
        final job = AutoJob(
          id: id,
          source: file.path,
          relative: relative,
          signature: signature,
          digest: digest,
          snapshot: snapshot.path,
        );
        // 复制文件的失败与日志写入失败分开处理，持久化失败必须中止。
        await _append(job.toJson());
        _jobs[id] = job;
        _seen[file.path] = signature;
        _observations.remove(file.path);
        issues.remove(file.path);
        snapshot = null;
      } on FileSystemException {
        issues[file.path] = '照片不可读取或磁盘写入失败，等待重试';
      } on StateError catch (e) {
        issues[file.path] = '${e.message}，等待重新检测';
      } finally {
        if (snapshot != null && await snapshot.exists()) {
          await snapshot.delete();
        }
      }
    }
    _notify();
  }

  Future<void> _pump() async {
    for (final job in _jobs.values.toList()) {
      if (!running) break;
      if (job.state != 'pending' || job.nextAttempt.isAfter(DateTime.now())) {
        continue;
      }
      job.state = 'uploading';
      job.attempts++;
      job.progress = 0;
      await _append(job.toJson());
      _notify();
      final transfer = PhotoTransfer(_profile!);
      try {
        final file = File(job.snapshot);
        if (!await file.exists() ||
            (await sha256.bind(file.openRead()).first).toString() !=
                job.digest) {
          throw StateError('待传副本丢失或变化，请检查本机存储');
        }
        await transfer.open(_profile!.directory);
        await transfer.uploadQueued(file, job.relative, job.id, job.digest, (
          progress,
        ) {
          job.progress = progress;
          if (!_closed) {
            _progressTimer ??= Timer(
              const Duration(milliseconds: 100),
              _notify,
            );
          }
        });
        job.state = 'done';
        job.progress = 1;
        job.error = '';
      } catch (error) {
        job.error = error is StateError
            ? error.message
            : '连接或传输失败，请检查网络、账号和服务器权限';
        final permanent =
            error is StateError &&
            (error.message.contains('同名') ||
                error.message.contains('副本') ||
                error.message.contains('不合法'));
        job.state = permanent || job.attempts >= 3 ? 'failed' : 'pending';
        job.nextAttempt = DateTime.now().add(retryDelay * job.attempts);
      } finally {
        _cancelProgressNotification();
        try {
          await transfer.close();
        } catch (_) {
          message = 'FTP连接关闭异常，已保留任务结果';
        }
      }
      await _append(job.toJson());
      if (job.state == 'done') {
        try {
          final copy = File(job.snapshot);
          if (await copy.exists()) await copy.delete();
        } on FileSystemException {
          message = '已上传，但本机待传副本清理失败';
        }
      }
      _notify();
    }
  }

  Future<void> retryFailed() async {
    if (!running) return;
    try {
      for (final job
          in _jobs.values.where((j) => j.state == 'failed').toList()) {
        job.state = 'pending';
        job.attempts = 0;
        job.nextAttempt = DateTime.fromMillisecondsSinceEpoch(0);
        await _append(job.toJson());
      }
      _tick();
      _notify();
    } catch (_) {
      _fail();
    }
  }

  Future<void> stop() async {
    if (stopping) return;
    running = false;
    stopping = true;
    _timer?.cancel();
    _debounce?.cancel();
    await _events?.cancel();
    _events = null;
    message = '正在停止，当前文件完成后保留剩余任务';
    _notify();
    try {
      await _scanTask;
      await _pumpTask;
    } finally {
      try {
        await _journal?.close();
      } finally {
        _journal = null;
        stopping = false;
        message = '监听已停止，重新开始时恢复未完成任务';
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _cancelProgressNotification();
    unawaited(stop().catchError((Object _) {}));
    super.dispose();
  }
}

class _PersistenceFailure implements Exception {
  const _PersistenceFailure();
}
