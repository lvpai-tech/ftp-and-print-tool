import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../transfer.dart';
import '../manual_batch/card_decoder.dart';
import '../camera_metadata.dart';
import '../photo_normalizer.dart';
import 'cos_upload.dart';
import 'journal.dart';
import 'upload_slots.dart';

class AutoJob {
  final String id, source, relative, signature, digest, snapshot;
  final bool normalized;
  final String? captureTime;
  final CameraMetadata? captureMetadata;
  String state;
  String error;
  int attempts;
  DateTime nextAttempt;
  DateTime? ingestedAt;
  double progress = 0;
  AutoJob({
    required this.id,
    required this.source,
    required this.relative,
    required this.signature,
    required this.digest,
    required this.snapshot,
    this.normalized = false,
    this.captureTime,
    this.captureMetadata,
    this.state = 'pending',
    this.error = '',
    this.attempts = 0,
    this.ingestedAt,
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
    if (normalized) 'normalized': true,
    if (captureTime != null) 'captureTime': captureTime,
    if (captureMetadata != null) 'captureMetadata': captureMetadata!.toJson(),
    'state': state,
    'error': error,
    'attempts': attempts,
    'nextAttempt': nextAttempt.millisecondsSinceEpoch,
    if (ingestedAt != null) 'ingestedAt': ingestedAt!.millisecondsSinceEpoch,
  };
  factory AutoJob.fromJson(Map<String, dynamic> v) => AutoJob(
    id: v['id'] as String,
    source: v['source'] as String,
    relative: v['relative'] as String,
    signature: v['signature'] as String,
    digest: v['digest'] as String,
    snapshot: v['snapshot'] as String,
    normalized: v['normalized'] == true,
    captureTime: v['captureTime'] as String?,
    captureMetadata: v['captureMetadata'] is Map<String, dynamic>
        ? CameraMetadata.fromJson(v['captureMetadata'] as Map<String, dynamic>)
        : null,
    state: v['state'] as String,
    error: v['error'] as String,
    attempts: v['attempts'] as int,
    nextAttempt: DateTime.fromMillisecondsSinceEpoch(v['nextAttempt'] as int),
    ingestedAt: switch (v['ingestedAt']) {
      final int value => DateTime.fromMillisecondsSinceEpoch(value),
      _ => null,
    },
  );

  Future<Uint8List> readPhotoForReview() async {
    for (final path in [snapshot, source]) {
      try {
        final bytes = await File(path).readAsBytes();
        final expected = digest;
        if (path == source && needsPhotoTranscode(path)) {
          final jpeg = await normalizedCameraPhoto(bytes, path);
          if (sha256.convert(jpeg).toString() == expected) return jpeg;
          break;
        }
        final verified = await compute(_verifiedPhoto, (
          bytes,
          expected,
          source,
        ));
        if (verified != null) return verified;
      } on FileSystemException {
        // The uploaded snapshot can be cleaned up while this row is open.
      }
    }
    throw StateError('队列照片已移走或内容已变化，请重新选择原图');
  }

  Future<Uint8List?> readNormalizedThumbnail() async {
    final codec = await ui.instantiateImageCodec(
      await readPhotoForReview(),
      targetWidth: 144,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}

Uint8List? _verifiedPhoto((Uint8List, String, String) request) {
  final (bytes, expected, source) = request;
  if (sha256.convert(bytes).toString() == expected) return bytes;
  try {
    final normalized = normalizeJpegPrimary(bytes, sourcePath: source);
    if (sha256.convert(normalized).toString() == expected) return normalized;
  } on StateError {
    // Older queue entries used the first frame without reading the MP Index.
  }
  try {
    final first = normalizeJpegPrimary(bytes, legacyFirstImage: true);
    if (sha256.convert(first).toString() == expected) return first;
  } on StateError {
    // The source may have been replaced with an incomplete image.
  }
  return null;
}

class _Observation {
  final String signature;
  final DateTime since;
  _Observation(this.signature, this.since);
}

/// 事件触发和定时补扫并用；扫描、落盘及上传各自串行，上传不阻塞新图发现。
class FolderUploader extends ChangeNotifier {
  static const importStagingPrefix = '.lvpai-import-';
  final Directory storage;
  final Duration scanInterval, stableFor, retryDelay;
  final Future<bool> Function(File) validateImage;
  final UploadSlots? transferSlots;
  final UploadSlots? preparationSlots;
  final Map<String, AutoJob> _jobs = {};
  final Map<String, AutoJob> _cosJobsByDigest = {};
  final Map<String, String> _seen = {}, _ignored = {};
  final Map<String, _Observation> _observations = {};
  final Map<String, DateTime> _missingSince = {};
  // Singletons have a known position. Larger groups wait for an operator's order.
  final List<List<String>> _waiting = [];
  final Set<String> _fileEvents = {};
  final Set<String> _changedFiles = {};
  String? _confirmedSource;
  String? _discardingSource;
  final Map<String, String> issues = {};
  QueueJournal? _journal;
  StreamSubscription<FileSystemEvent>? _events;
  Timer? _timer, _debounce, _progressTimer;
  ServerProfile? _profile;
  CosUpload? _cos;
  bool _authorizationPaused = false;
  Directory? _root;
  Future<void>? _scanTask, _pumpTask, _noticeTask;
  final Map<String, String> _noticeBaseline = {},
      _noticeChecked = {},
      _noticePending = {};
  final Map<String, String> _legacyNoticeSignatures = {};
  final Set<String> _reportedEndingRequests = {};
  final Map<String, String> _duplicateSources = {};
  final Map<String, DateTime> _noticeRetryAt = {};
  final Map<String, String> noticeIssues = {};
  bool _noticeInitialized = false;
  bool running = false, stopping = false, _initialized = false, _closed = false;
  bool _recursive = true, _includeExisting = false;
  String message = '选择接收相机照片的文件夹，点击开始监听';
  String watcherNotice = '';
  String? fatalError;
  bool get authorizationPaused => _authorizationPaused;
  bool get requiresStop => running || stopping || _journal != null;
  bool _directoryReadable = false;
  bool get directoryReadable => running && _directoryReadable;
  bool get canFinishMigration => directoryReadable && queueDrained;
  bool get queueDrained =>
      _waiting.isEmpty &&
      _noticePending.isEmpty &&
      issues.isEmpty &&
      !_jobs.values.any(
        (job) => const {
          'pending',
          'uploading',
          'accepted',
          'failed',
        }.contains(job.state),
      );
  DateTime? get latestIngested {
    DateTime? latest;
    for (final job in _jobs.values) {
      final time = job.ingestedAt;
      if (time != null && (latest == null || time.isAfter(latest))) {
        latest = time;
      }
    }
    return latest;
  }

  List<AutoJob> get jobs => _jobs.values.toList().reversed.toList();
  int get settling => _cos == null
      ? _observations.length
      : _waiting.fold(0, (count, group) => count + group.length);
  Map<String, String?> get waitingSources {
    final sources = _cos == null
        ? _observations.keys
        : _waiting.expand((group) => group);
    return Map.unmodifiable({
      for (final source in sources) source: _observations[source]?.signature,
    });
  }

  List<String> get sourcesNeedingOrder =>
      _waiting.isNotEmpty && _waiting.first.length > 1
      ? List.unmodifiable(_waiting.first)
      : const [];

  String? get orderWaitMessage {
    if (_cos == null) return null;
    for (final job in _jobs.values) {
      final reason = switch (job.state) {
        'accepted' => '等待服务端入库，后续照片暂缓上传',
        'failed' => '上传或入库失败，重试后继续上传后续照片',
        'pending' when job.attempts > 0 => '等待重试，后续照片暂缓上传',
        _ => null,
      };
      if (reason != null) return '${job.relative}：$reason';
      if (job.state == 'pending' || job.state == 'uploading') return null;
    }
    if (_waiting.isEmpty || _waiting.first.length > 1) return null;
    final source = _waiting.first.single;
    final reason = issues[source] ?? '等待文件写完，后续照片暂缓上传';
    return '${p.relative(source, from: _root!.path)}：$reason';
  }

  FolderUploader({
    required this.storage,
    this.transferSlots,
    this.preparationSlots,
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
  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  bool _isPhoto(String path) {
    if (p
        .split(p.relative(path, from: _root!.path))
        .any((part) => part.startsWith(importStagingPrefix))) {
      return false;
    }
    final extension = p.extension(path).toLowerCase();
    return cameraPhotoExtensions.any((type) => extension == '.$type');
  }

  void _prioritizeSource(String source) {
    _waiting.first.remove(source);
    _waiting.insert(0, [source]);
    if (_waiting[1].isEmpty) _waiting.removeAt(1);
  }

  void _resolveSource(String source) {
    if (_waiting.isEmpty || !_waiting.first.remove(source)) return;
    if (_waiting.first.isEmpty) _waiting.removeAt(0);
  }

  void _discardSource(String source, String? signature) {
    final index = _waiting.indexWhere((group) => group.contains(source));
    if (index >= 0) {
      final group = _waiting[index];
      group.remove(source);
      if (group.isEmpty) _waiting.removeAt(index);
    }
    if (signature != null) _seen[source] = signature;
    _observations.remove(source);
    _duplicateSources.remove(source);
    _missingSince.remove(source);
    issues.remove(source);
    if (signature == null) {
      _noticePending.remove(source);
      _noticeRetryAt.remove(source);
      noticeIssues.remove(source);
    }
  }

  Future<void> discardWaitingSource(String source, String? signature) async {
    // Reserve the scan slot before validating or writing the discard event.
    while (_scanTask != null) {
      await _scanTask;
    }
    if (!running ||
        _cos == null ||
        source == _confirmedSource ||
        !_waiting.any((group) => group.contains(source))) {
      throw StateError('照片已离开待准备队列，请刷新后核对。');
    }
    _discardingSource = source;
    final discard = _persistDiscard(source, signature);
    final scanSlot = discard
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() {
          _scanTask = null;
          _discardingSource = null;
        });
    _scanTask = scanSlot;
    try {
      await discard;
    } finally {
      await scanSlot;
    }
    _notify();
    _tick();
  }

  Future<void> _persistDiscard(String source, String? signature) async {
    if (signature == null) await _noticeTask;
    final stat = await File(source).stat();
    final current = stat.type == FileSystemEntityType.file
        ? _signature(stat)
        : null;
    if (current != signature) throw StateError('文件有变化，请核对最新缩略图后再移除。');
    await _recordDiscard(source, signature);
  }

  Future<void> _recordDiscard(String source, String? signature) async {
    await _append({
      'type': 'discardSource',
      'source': source,
      'signature': signature,
    });
    _discardSource(source, signature);
  }

  void confirmNextSource(String source) {
    if (running &&
        _confirmedSource == null &&
        source != _discardingSource &&
        sourcesNeedingOrder.contains(source)) {
      _confirmedSource = source;
      _tick();
    }
  }

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
    ServerProfile? profile, {
    CosUploadProfile? cosProfile,
    String? Function()? personnelToken,
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
    if ((profile == null) == (cosProfile == null)) {
      throw StateError('请选择一个自动上传通道');
    }
    final absolute = Directory(await root.resolveSymbolicLinks());
    if (p.isWithin(absolute.path, storage.absolute.path) ||
        p.equals(absolute.path, storage.absolute.path)) {
      throw StateError('监听目录不能包含应用待传区');
    }
    _root = absolute;
    _profile = profile;
    _authorizationPaused = false;
    _directoryReadable = false;
    _cos = cosProfile == null
        ? null
        : CosUpload(cosProfile, personnelToken: personnelToken);
    _recursive = recursive;
    _includeExisting = includeExisting;
    _resetQueue();
    final key = cosProfile != null
        ? _cosQueueKey(absolute.path, cosProfile)
        : _hash(
            '${absolute.path}\u0000${profile!.host.toLowerCase()}\u0000'
            '${profile.port}\u0000${profile.user}\u0000${profile.directory}',
          );
    final journal = QueueJournal(_queueFile(key));
    await _startQueue(absolute, journal, recursive);
  }

  void clearView() {
    if (requiresStop) throw StateError('请先停止当前监听');
    _resetQueue();
    message = '确认相机导出目录后，点击开始监听';
    watcherNotice = '';
    _notify();
  }

  void _resetQueue() {
    _jobs.clear();
    _seen.clear();
    _cosJobsByDigest.clear();
    _ignored.clear();
    _observations.clear();
    _missingSince.clear();
    _noticeBaseline.clear();
    _noticeChecked.clear();
    _noticePending.clear();
    _legacyNoticeSignatures.clear();
    _reportedEndingRequests.clear();
    _duplicateSources.clear();
    _noticeRetryAt.clear();
    noticeIssues.clear();
    _noticeInitialized = false;
    _waiting.clear();
    _fileEvents.clear();
    _changedFiles.clear();
    _confirmedSource = null;
    issues.clear();
    fatalError = null;
    _initialized = false;
  }

  Future<void> _startQueue(
    Directory absolute,
    QueueJournal journal,
    bool recursive,
  ) async {
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
          case 'noticeBaseline':
            _noticeInitialized = true;
            _noticeBaseline.addAll(
              Map<String, String>.from(event['files'] as Map),
            );
          case 'noticePending':
            final source = event['source'] as String;
            final signature = event['signature'] as String;
            _noticePending[source] = signature;
            if (event['contentIdentity'] != true) {
              _legacyNoticeSignatures[source] = signature;
            }
          case 'noticeChecked':
            final source = event['source'] as String;
            final signature = event['signature'] as String;
            _noticePending.remove(source);
            _noticeChecked[source] = signature;
            if (event['contentIdentity'] != true) {
              _legacyNoticeSignatures[source] = signature;
            }
            final requestId = event['reportedRequestId'];
            if (requestId is String) _reportedEndingRequests.add(requestId);
          case 'ignore':
            _ignored[event['source'] as String] = event['signature'] as String;
          case 'arrival':
            _waiting.addAll(
              (event['groups'] as List).map(
                (group) => List<String>.from(group as List),
              ),
            );
          case 'nextSource':
            _prioritizeSource(event['source'] as String);
          case 'resolvedSource':
            final source = event['source'] as String;
            _seen[source] = event['signature'] as String;
            _resolveSource(source);
          case 'discardSource':
            _discardSource(
              event['source'] as String,
              event['signature'] as String?,
            );
          case 'job':
            final job = AutoJob.fromJson(event);
            if (job.state == 'uploading') job.state = 'pending';
            // Status updates for older jobs cannot consume a later observation
            // of a different photo written to the same filename.
            if (!_jobs.containsKey(job.id)) {
              _resolveSource(job.source);
              _seen[job.source] = job.signature;
            }
            _jobs[job.id] = job;
            if (_cos != null) {
              final existing = _cosJobsByDigest[job.digest];
              if (existing == null || existing.id == job.id) {
                _cosJobsByDigest[job.digest] = job;
              }
            }
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
              (event) {
                if (_cos != null && !event.isDirectory) {
                  if (event is FileSystemDeleteEvent ||
                      event is FileSystemMoveEvent) {
                    final key = p.canonicalize(event.path);
                    _fileEvents.remove(key);
                    _changedFiles.remove(key);
                  }
                  if (event case FileSystemModifyEvent(contentChanged: true)
                      when _isPhoto(event.path)) {
                    _changedFiles.add(p.canonicalize(event.path));
                  }
                  final path = switch (event) {
                    FileSystemCreateEvent() => event.path,
                    FileSystemMoveEvent() => event.destination,
                    _ => null,
                  };
                  if (path != null && _isPhoto(path)) {
                    _fileEvents.add(p.canonicalize(path));
                  }
                }
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
      _notify();
    } catch (_) {
      running = false;
      _timer?.cancel();
      _debounce?.cancel();
      await _events?.cancel();
      _journal = null;
      _cos?.close();
      _cos = null;
      await journal.close();
      rethrow;
    }
  }

  File _queueFile(String key) => File(p.join(storage.path, key, 'queue.jsonl'));

  static String _cosQueueKey(String folder, CosUploadProfile profile) =>
      _hash('$folder\u0000cos\u0000${profile.queueTarget}');

  Future<bool> hasCosQueue(String resolvedFolder, CosUploadProfile profile) =>
      _queueFile(_cosQueueKey(resolvedFolder, profile)).exists();

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
        if (entity is File && _isPhoto(entity.path)) {
          files.add(entity);
        }
      }
    } on FileSystemException {
      _directoryReadable = false;
      issues.removeWhere((source, _) => _missingSince.containsKey(source));
      _missingSince.clear();
      message = '无法读取监听目录，等待恢复；请检查磁盘、目录和权限';
      _notify();
      return;
    }
    if (!running) return;
    _directoryReadable = true;
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
    _duplicateSources.removeWhere((path, _) => !present.contains(path));
    issues.removeWhere((path, _) => !present.contains(path));
    if (_cos != null) {
      if (!_noticeInitialized) {
        for (final file in files) {
          final stat = await file.stat();
          if (stat.type == FileSystemEntityType.file &&
              !_fileEvents.contains(p.canonicalize(file.path))) {
            _noticeBaseline[file.path] = _signature(stat);
          }
        }
        await _append({'type': 'noticeBaseline', 'files': _noticeBaseline});
        _noticeInitialized = true;
      }
      await _scanInOrder(files);
    } else {
      for (final file in files) {
        if (!running) break;
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file &&
            _observe(file.path, stat)) {
          await _enqueue(file, stat);
        }
      }
    }
    _notify();
  }

  bool _observe(String source, FileStat stat, {bool reserved = false}) {
    final signature = _signature(stat);
    if (!reserved &&
        (_seen[source] == signature ||
            (!_includeExisting && _ignored[source] == signature))) {
      _observations.remove(source);
      return false;
    }
    final observed = _observations[source];
    if (observed == null || observed.signature != signature) {
      _observations[source] = _Observation(signature, DateTime.now());
      issues.remove(source);
      return false;
    }
    return stat.size > 0 &&
        DateTime.now().difference(observed.since) >= stableFor;
  }

  Future<void> _scanInOrder(List<File> files) async {
    final reserved = _waiting.expand((group) => group).toSet();
    final discovered = <String, String>{};
    final ready = <String, FileStat>{};
    final present = <String>{};
    final listed = <String>{};
    for (final file in files) {
      if (!running) return;
      final key = p.canonicalize(file.path);
      listed.add(key);
      final changed = _changedFiles.remove(key) || _fileEvents.contains(key);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) continue;
      present.add(file.path);
      if (changed) {
        _seen.remove(file.path);
        _ignored.remove(file.path);
        _noticeBaseline.remove(file.path);
        _noticeChecked.remove(file.path);
        _observations.remove(file.path);
        _duplicateSources.remove(file.path);
      }
      final isReserved = reserved.contains(file.path);
      if (_observe(file.path, stat, reserved: isReserved)) {
        ready[file.path] = stat;
      }
      if (!isReserved && _observations.containsKey(file.path)) {
        discovered[key] = file.path;
      }
    }
    final ordered = [
      for (final key in _fileEvents)
        if (discovered.containsKey(key)) discovered[key]!,
    ];
    _fileEvents.removeWhere(listed.contains);
    if (discovered.isNotEmpty && running) {
      final groups = discovered.length == ordered.length
          ? ordered.map((source) => [source]).toList()
          : [discovered.values.toList()];
      await _append({'type': 'arrival', 'groups': groups});
      _waiting.addAll(groups);
    }
    await _discardMissingSources(reserved, present);
    for (final entry in ready.entries) {
      if (!running) return;
      final signature = _signature(entry.value);
      if (_duplicateSources[entry.key] == signature) {
        await _recordDiscard(entry.key, signature);
      }
    }
    final confirmed = _confirmedSource;
    _confirmedSource = null;
    if (confirmed != null && sourcesNeedingOrder.contains(confirmed)) {
      await _append({'type': 'nextSource', 'source': confirmed});
      _prioritizeSource(confirmed);
    }
    if (_noticeTask == null) {
      final noticeFiles = Map<String, FileStat>.of(ready);
      for (final source in _noticePending.keys.toList()) {
        if (!present.contains(source) || noticeFiles.containsKey(source)) {
          continue;
        }
        final stat = await File(source).stat();
        if (stat.type == FileSystemEntityType.file &&
            _noticePending[source] == _signature(stat)) {
          noticeFiles[source] = stat;
        }
      }
      _noticeTask = _scanNotices(noticeFiles)
          .catchError((Object error) => _fail())
          .whenComplete(() {
            _noticeTask = null;
            _notify();
          });
    }
    while (running && _waiting.isNotEmpty && _waiting.first.length == 1) {
      final source = _waiting.first.single;
      if (!present.contains(source)) break;
      final stat = ready[source];
      if (stat == null) break;
      final signature = _signature(stat);
      if (_noticeBaseline[source] != signature &&
          _noticeChecked[source] != signature &&
          !(noticeIssues.containsKey(source) &&
              _noticePending[source] == signature)) {
        break;
      }
      final slots = preparationSlots;
      final prepared = slots == null
          ? await _enqueue(File(source), stat)
          : await slots.run(
              () async => running && await _enqueue(File(source), stat),
            );
      if (!prepared) break;
    }
  }

  Future<void> _discardMissingSources(
    Set<String> reserved,
    Set<String> present,
  ) async {
    final now = DateTime.now();
    for (final source in reserved) {
      if (!running) return;
      if (present.contains(source)) {
        _missingSince.remove(source);
        continue;
      }
      issues[source] = '文件不在监听目录，持续缺失时将自动移出队列';
      final since = _missingSince[source];
      _missingSince[source] = since ?? now;
      // Let any in-flight ending notice finish before discarding its local state.
      if (since == null ||
          now.difference(since) < stableFor ||
          _noticeTask != null) {
        continue;
      }
      final stat = await File(source).stat();
      if (stat.type == FileSystemEntityType.file) {
        _missingSince.remove(source);
        issues.remove(source);
        continue;
      }
      if (running) await _recordDiscard(source, null);
    }
  }

  Future<void> _scanNotices(Map<String, FileStat> ready) async {
    final cos = _cos!;
    final noticeDir = Directory(p.join(_journal!.file.parent.path, 'notices'));
    for (final entry in ready.entries) {
      if (!running) return;
      final source = entry.key;
      final signature = _signature(entry.value);
      if (_noticeBaseline[source] == signature ||
          _noticeChecked[source] == signature ||
          (_noticeRetryAt[source]?.isAfter(DateTime.now()) ?? false)) {
        continue;
      }
      final file = File(source);
      await noticeDir.create(recursive: true);
      final snapshot = File(
        p.join(noticeDir.path, 'ending${photoUploadExtension(source)}'),
      );
      final contentIdentity = _legacyNoticeSignatures[source] != signature;
      String? requestId;
      String? secret;
      var copied = false;
      var duplicate = false;
      try {
        Future<void> recognize() async {
          if (!running) return;
          await file.copy(snapshot.path);
          if (_signature(await file.stat()) != signature ||
              await snapshot.length() != entry.value.size) {
            return;
          }
          copied = true;
          await normalizePhotoSnapshot(snapshot, sourcePath: source);
          final digest = (await sha256.bind(snapshot.openRead()).first)
              .toString();
          final existing = _cosJobsByDigest[digest];
          if (existing != null &&
              (existing.source != source ||
                  _noticePending[source] != signature)) {
            duplicate = true;
            return;
          }
          secret = await decodeEndingBarcode(snapshot);
          if (secret != null) {
            requestId =
                existing?.id ?? _photoRequestId(source, signature, digest);
          }
        }

        final slots = preparationSlots;
        if (slots == null) {
          await recognize();
        } else {
          await slots.run(recognize);
        }
        if (!running) return;
        if (!copied || _signature(await file.stat()) != signature) continue;
      } catch (_) {
        // 解码失败的照片仍交原上传准备流程统一校验。
        if (_signature(await file.stat()) != signature) continue;
      } finally {
        if (await snapshot.exists()) await snapshot.delete();
      }
      if (duplicate) _duplicateSources[source] = signature;
      final endingRequestId = requestId;
      if (endingRequestId != null &&
          !_reportedEndingRequests.contains(endingRequestId)) {
        if (_noticePending[source] != signature) {
          await _append({
            'type': 'noticePending',
            'source': source,
            'signature': signature,
            'contentIdentity': contentIdentity,
          });
          _noticePending[source] = signature;
        }
        try {
          await cos.reportEnding(endingRequestId, secret!);
          _reportedEndingRequests.add(endingRequestId);
        } catch (_) {
          noticeIssues[source] = '结束照上传状态上报失败，稍后重试';
          _noticeRetryAt[source] = DateTime.now().add(retryDelay);
          continue;
        }
      }
      noticeIssues.remove(source);
      _noticeRetryAt.remove(source);
      await _append({
        'type': 'noticeChecked',
        'source': source,
        'signature': signature,
        'contentIdentity': contentIdentity,
        'reportedRequestId': ?endingRequestId,
      });
      _noticeChecked[source] = signature;
      _noticePending.remove(source);
    }
  }

  String _uploadRelative(String source) => p.posix.joinAll(
    p.split(
      p.setExtension(
        p.relative(source, from: _root!.path),
        photoUploadExtension(source),
      ),
    ),
  );

  String _photoRequestId(String source, String signature, String digest) {
    // Reuse the legacy request ID if an older client may have reported this
    // ending before the corresponding upload job was written.
    if (_cos == null || _legacyNoticeSignatures[source] == signature) {
      return _hash('${_uploadRelative(source)}\u0000$digest');
    }
    return _hash('cos-content-v1\u0000$digest');
  }

  Future<bool> _enqueue(File file, FileStat stat) async {
    final signature = _signature(stat);
    File? snapshot;
    try {
      final tempDir = Directory(p.join(_journal!.file.parent.path, 'pending'));
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
        return false;
      }
      final raw = isRawCameraPhoto(file.path);
      final transcodes = needsPhotoTranscode(file.path);
      var captureMetadata = _cos != null && transcodes
          ? await readCameraMetadata(snapshot, file.path, raw: raw)
          : null;
      final normalized = await normalizePhotoSnapshot(
        snapshot,
        sourcePath: file.path,
      );
      // JPEG/MPO normalization selects a frame without rewriting its EXIF.
      if (_cos != null && !transcodes) {
        captureMetadata = await readCameraMetadata(
          snapshot,
          file.path,
          raw: false,
        );
      }
      try {
        if (!await validateImage(snapshot)) throw StateError('照片无法解码');
      } catch (_) {
        throw StateError('照片无法解码');
      }
      final digest = (await sha256.bind(snapshot.openRead()).first).toString();
      final relative = _uploadRelative(file.path);
      final captureTime = _cos != null && (raw || isJpegCameraPhoto(file.path))
          ? await readJpegCaptureTime(snapshot)
          : null;
      if (_cos == null && _signature(await file.stat()) != signature) {
        _observations.remove(file.path);
        return false;
      }
      final id = _photoRequestId(file.path, signature, digest);
      final paired =
          captureTime != null &&
          _jobs.values.any(
            (job) =>
                job.captureTime == captureTime &&
                (raw
                    ? isJpegCameraPhoto(job.source)
                    : isRawCameraPhoto(job.source)) &&
                p.equals(
                  p.withoutExtension(job.source),
                  p.withoutExtension(file.path),
                ),
          );
      if (_jobs.containsKey(id) ||
          _cosJobsByDigest.containsKey(digest) ||
          paired) {
        if (_cos != null) {
          await _append({
            'type': 'resolvedSource',
            'source': file.path,
            'signature': signature,
          });
          _resolveSource(file.path);
        }
        _seen[file.path] = signature;
        _observations.remove(file.path);
        issues.remove(file.path);
        return true;
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
        normalized: normalized,
        captureTime: captureTime,
        captureMetadata: captureMetadata,
      );
      // 复制文件的失败与日志写入失败分开处理，持久化失败必须中止。
      await _append(job.toJson());
      _jobs[id] = job;
      if (_cos != null) _cosJobsByDigest[digest] = job;
      _resolveSource(file.path);
      _seen[file.path] = signature;
      _observations.remove(file.path);
      issues.remove(file.path);
      snapshot = null;
      return true;
    } on FileSystemException {
      issues[file.path] = '照片不可读取或磁盘写入失败，等待重试';
    } on StateError catch (e) {
      issues[file.path] = '${e.message}，等待重新检测';
    } finally {
      if (snapshot != null && await snapshot.exists()) {
        await snapshot.delete();
      }
    }
    return false;
  }

  Future<void> _pump() async {
    if (_authorizationPaused) return;
    for (final job in _jobs.values.toList()) {
      if (!running) break;
      if (_cos != null && job.state == 'accepted') {
        await _refreshCosStatus(priority: job);
        if (job.state == 'accepted' || job.state == 'failed') return;
      }
      if (_cos != null &&
          (job.state == 'failed' ||
              (job.state == 'pending' &&
                  job.nextAttempt.isAfter(DateTime.now())))) {
        break;
      }
      if (job.state != 'pending' || job.nextAttempt.isAfter(DateTime.now())) {
        continue;
      }
      job.state = 'uploading';
      job.attempts++;
      job.progress = 0;
      await _append(job.toJson());
      _notify();
      final transfer = _profile == null ? null : PhotoTransfer(_profile!);
      try {
        final file = File(job.snapshot);
        if (!await file.exists() ||
            (await sha256.bind(file.openRead()).first).toString() !=
                job.digest) {
          throw StateError('待传副本丢失或变化，请检查本机存储');
        }
        void onProgress(double progress) {
          job.progress = progress;
          if (!_closed) {
            _progressTimer ??= Timer(
              const Duration(milliseconds: 100),
              _notify,
            );
          }
        }

        if (transfer != null) {
          await transfer.open(_profile!.directory);
          await transfer.uploadQueued(
            file,
            job.relative,
            job.id,
            job.digest,
            onProgress,
          );
          job.state = 'done';
        } else {
          Future<String> upload() => _cos!.upload(
            file,
            job.id,
            job.digest,
            onProgress,
            recover: job.attempts > 1,
            captureMetadata: job.captureMetadata,
          );
          final slots = transferSlots;
          final status = slots == null
              ? await upload()
              : await slots.run<String?>(
                  () async => running ? await upload() : null,
                );
          if (status == null) {
            job.state = 'pending';
            job.attempts--;
          } else {
            job.state = switch (status) {
              'GROUPED' => 'grouped',
              'INGESTED' => 'ingested',
              _ => 'accepted',
            };
            if (job.state == 'ingested' || job.state == 'grouped') {
              job.ingestedAt ??= DateTime.now();
            }
            job.nextAttempt = DateTime.now();
          }
        }
        if (job.state != 'pending') {
          job.progress = 1;
          job.error = '';
        }
      } on CosUploadAuthorizationError catch (error) {
        _authorizationPaused = true;
        message = error.message;
        job.error = error.message;
        job.state = 'pending';
        job.attempts--;
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
          await transfer?.close();
        } catch (_) {
          message = 'FTP连接关闭异常，已保留任务结果';
        }
      }
      await _append(job.toJson());
      if (const {'done', 'ingested', 'grouped'}.contains(job.state)) {
        await _removeSnapshot(job);
      }
      _notify();
      if (_cos != null && job.state != 'ingested' && job.state != 'grouped') {
        break;
      }
    }
    if (_cos != null && !_authorizationPaused) await _refreshCosStatus();
  }

  Future<void> _removeSnapshot(AutoJob job) async {
    try {
      final copy = File(job.snapshot);
      if (await copy.exists()) await copy.delete();
    } on FileSystemException {
      message = '已上传，但本机待传副本清理失败';
    }
  }

  Future<void> _refreshCosStatus({AutoJob? priority}) async {
    final due =
        _jobs.values
            .where(
              (job) =>
                  const {'accepted', 'ingested'}.contains(job.state) &&
                  !job.nextAttempt.isAfter(DateTime.now()),
            )
            .toList()
          ..sort((a, b) {
            if (a == b) return 0;
            if (a == priority) return -1;
            if (b == priority) return 1;
            return a.nextAttempt.compareTo(b.nextAttempt);
          });
    for (final job in due.take(12)) {
      if (!running) break;
      job.nextAttempt = DateTime.now().add(
        job.state == 'accepted' ? scanInterval : const Duration(seconds: 15),
      );
      late final ({String status, String error}) result;
      try {
        result = await _cos!.status(job.id);
      } on CosUploadAuthorizationError catch (error) {
        _authorizationPaused = true;
        message = error.message;
        _notify();
        break;
      } catch (_) {
        message = '暂时无法查询 COS 归集状态，稍后重试';
        _notify();
        break;
      }
      if (result.status == 'GROUPED') {
        job.state = 'grouped';
        job.error = '';
      } else if (result.status == 'INGESTED' && job.state == 'accepted') {
        job.state = 'ingested';
        job.error = '';
      } else if (result.status == 'FAILED') {
        job.state = 'failed';
        job.error = result.error;
      } else {
        continue;
      }
      final ingested = job.state == 'grouped' || job.state == 'ingested';
      if (ingested) job.ingestedAt ??= DateTime.now();
      await _append(job.toJson());
      if (ingested) {
        await _removeSnapshot(job);
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
      await _noticeTask;
    } finally {
      try {
        _cos?.close();
        _cos = null;
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
