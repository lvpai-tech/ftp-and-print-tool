import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../auto_upload/journal.dart';
import '../transfer.dart';
import '../photo_normalizer.dart';
import 'card_decoder.dart';

String _id() => List.generate(
  16,
  (_) => Random.secure().nextInt(256),
).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class BatchPhoto {
  final String id, source, snapshot, digest;
  final String? secret;
  final int size;
  BatchPhoto(
    this.id,
    this.source,
    this.snapshot,
    this.digest,
    this.size,
    this.secret,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'snapshot': snapshot,
    'digest': digest,
    'size': size,
    'secret': secret,
  };
  factory BatchPhoto.fromJson(Map<String, dynamic> v) => BatchPhoto(
    v['id'],
    v['source'],
    v['snapshot'],
    v['digest'],
    v['size'],
    v['secret'],
  );
}

class PhotoBatch {
  final String id;
  final List<String> photoIds;
  String? endPhotoId, secret, target;
  String state = 'draft', error = '';
  double progress = 0;
  PhotoBatch(this.id, this.photoIds);
  bool get editable => state == 'draft';
  Map<String, dynamic> toJson() => {
    'id': id,
    'photos': photoIds,
    'endPhotoId': endPhotoId,
    'secret': secret,
    'target': target,
    'state': state,
    'error': error,
  };
  factory PhotoBatch.fromJson(Map<String, dynamic> v) =>
      PhotoBatch(v['id'], List<String>.from(v['photos']))
        ..endPhotoId = v['endPhotoId']
        ..secret = v['secret']
        ..target = v['target']
        ..state = v['state'] == 'uploading' ? 'retry' : v['state']
        ..error = v['error'];
}

/// 手动批次持久化工作区。监听只复制和建议分组；唯一网络入口为 uploadBatch。
class BatchWorkspace extends ChangeNotifier {
  final Directory storage;
  final Future<String?> Function(File) recognize;
  final Duration stableFor;
  final photos = <String, BatchPhoto>{};
  final batches = <PhotoBatch>[];
  final _observed = <String, (String, DateTime)>{};
  final _seen = <String, String>{};
  final issues = <String, String>{};
  QueueJournal? _journal;
  Timer? _timer;
  Directory? _root;
  Future<void> _tail = Future.value();
  Future<void>? _scanTask;
  bool watching = false, uploading = false, failed = false, _disposed = false;
  String message = '选择接收目录，或添加照片；核对批次后点击上传';
  BatchWorkspace({
    required this.storage,
    Future<String?> Function(File)? recognize,
    this.stableFor = const Duration(seconds: 3),
  }) : recognize = recognize ?? decodeCard;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> open() async {
    _journal = QueueJournal(File(p.join(storage.path, 'batches.jsonl')));
    final events = await _journal!.open();
    if (events.isNotEmpty) {
      final last = events.last;
      if (last['version'] != 1) throw StateError('批次记录版本不支持，禁止覆盖');
      for (final v in last['photos'] as List) {
        final photo = BatchPhoto.fromJson(Map<String, dynamic>.from(v));
        photos[photo.id] = photo;
      }
      for (final v in last['batches'] as List) {
        batches.add(PhotoBatch.fromJson(Map<String, dynamic>.from(v)));
      }
      _seen.addAll(Map<String, String>.from(last['seen']));
    }
    _notify();
  }

  Future<void> _save() async {
    if (failed) throw StateError('批次记录写入失败，请重启后恢复，禁止继续上传');
    try {
      await _journal!.append({
        'version': 1,
        'photos': photos.values.map((p) => p.toJson()).toList(),
        'batches': batches.map((b) => b.toJson()).toList(),
        'seen': _seen,
      });
    } catch (_) {
      failed = true;
      watching = false;
      _timer?.cancel();
      message = '无法保存批次记录，已停止；检查本机磁盘后重新打开';
      _notify();
      rethrow;
    }
    _notify();
  }

  List<BatchPhoto> get unassigned {
    final used = batches.expand((b) => b.photoIds).toSet();
    return photos.values.where((p) => !used.contains(p.id)).toList();
  }

  Future<void> startWatching(Directory root) async {
    if (watching) throw StateError('已经在监听');
    final resolved = await root.resolveSymbolicLinks();
    if (p.isWithin(resolved, storage.absolute.path) ||
        p.equals(resolved, storage.absolute.path)) {
      throw StateError('接收目录不能包含批次待传区');
    }
    _root = Directory(resolved);
    watching = true;
    message = '手动模式监听中 · 新照片只在本机分组，不自动上传';
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(
        scanNow().catchError((Object _) {
          message = '扫描失败，请检查目录和磁盘权限';
          _notify();
        }),
      );
    });
    await scanNow();
    _notify();
  }

  Future<void> stopWatching() async {
    watching = false;
    _timer?.cancel();
    await _tail;
    _notify();
  }

  Future<void> scanNow() =>
      _scanTask ??= _scan().whenComplete(() => _scanTask = null);

  Future<void> _scan() => _serial(() async {
    if (!watching || failed) return;
    final files = <File>[];
    await for (final f in _root!.list(followLinks: false)) {
      if (f is File &&
          [
            '.jpg',
            '.jpeg',
            '.mpo',
            '.png',
          ].contains(p.extension(f.path).toLowerCase())) {
        files.add(f);
      }
    }
    // 到达/文件时间仅用于辅助展示与建议，不作为服务端拍摄时间或批次归属依据。
    files.sort((a, b) {
      final cmp = a.lastModifiedSync().compareTo(b.lastModifiedSync());
      return cmp == 0 ? a.path.compareTo(b.path) : cmp;
    });
    for (final f in files) {
      if (!watching) break;
      final stat = await f.stat();
      final signature = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
      if (_seen[f.path] == signature) continue;
      final observed = _observed[f.path];
      if (observed == null || observed.$1 != signature) {
        _observed[f.path] = (signature, DateTime.now());
        continue;
      }
      if (DateTime.now().difference(observed.$2) < stableFor ||
          stat.size == 0) {
        continue;
      }
      try {
        await _capture(f, signature);
      } catch (_) {
        issues[f.path] = '图片读取/识别失败，请检查后重新扫描';
        _notify();
      }
    }
  });
  Future<void> addFiles(List<File> files, {String? batchId}) =>
      _serial(() async {
        if (failed) throw StateError('批次记录不可写');
        final batch = batchId == null
            ? null
            : batches.firstWhere((b) => b.id == batchId);
        if (batch != null && !batch.editable) throw StateError('已开始上传的批次不可修改');
        for (final file in files) {
          final stat = await file.stat();
          await _capture(
            file,
            '${stat.size}:${stat.modified.microsecondsSinceEpoch}',
            batch: batch,
          );
        }
      });
  Future<void> _capture(
    File file,
    String signature, {
    PhotoBatch? batch,
  }) async {
    if (![
      '.jpg',
      '.jpeg',
      '.mpo',
      '.png',
    ].contains(p.extension(file.path).toLowerCase())) {
      throw StateError('仅支持 JPEG/PNG/MPO');
    }
    final before = await file.stat();
    await storage.create(recursive: true);
    final snapshot = File(
      p.join(storage.path, '${_id()}${photoUploadExtension(file.path)}'),
    );
    await file.copy(snapshot.path);
    final after = await file.stat();
    if (before.size != after.size ||
        before.modified != after.modified ||
        before.size != await snapshot.length()) {
      await snapshot.delete();
      throw StateError('照片仍在写入，请稍后再试');
    }
    String? secret;
    try {
      await normalizePhotoSnapshot(snapshot, sourcePath: file.path);
      secret = await recognize(snapshot);
    } catch (_) {
      await snapshot.delete();
      rethrow;
    }
    final digest = (await sha256.bind(snapshot.openRead()).first).toString();
    final existing = photos.values.where((p) => p.digest == digest).firstOrNull;
    if (existing != null) {
      await snapshot.delete();
      _seen[file.path] = signature;
      if (batch != null) _move(existing.id, batch);
      await _save();
      return;
    }
    final photo = BatchPhoto(
      _id(),
      file.path,
      snapshot.path,
      digest,
      await snapshot.length(),
      secret,
    );
    photos[photo.id] = photo;
    _seen[file.path] = signature;
    var target =
        batch ??
        batches.where((b) => b.editable && b.endPhotoId == null).lastOrNull;
    target ??= PhotoBatch(_id(), [])..state = 'draft';
    if (!batches.contains(target)) batches.add(target);
    target.photoIds.add(photo.id);
    if (secret != null && batch == null) {
      target.endPhotoId = photo.id;
      target.secret = secret;
    }
    issues.remove(file.path);
    await _save();
  }

  void _move(String photoId, PhotoBatch target) {
    final sources = batches.where((b) => b.photoIds.contains(photoId));
    if (!target.editable || sources.any((b) => !b.editable)) {
      throw StateError('已上传/待重试批次不可修改');
    }
    for (final source in sources.toList()) {
      source.photoIds.remove(photoId);
      if (source.endPhotoId == photoId) {
        source.endPhotoId = null;
        source.secret = null;
      }
    }
    if (!target.photoIds.contains(photoId)) target.photoIds.add(photoId);
  }

  Future<void> movePhoto(String photoId, String batchId) => _serial(() async {
    if (!photos.containsKey(photoId)) throw StateError('照片不存在');
    _move(photoId, batches.firstWhere((b) => b.id == batchId));
    await _save();
  });
  Future<void> removePhoto(String batchId, String photoId) => _serial(() async {
    final batch = batches.firstWhere((b) => b.id == batchId);
    if (!batch.editable) throw StateError('已开始上传的批次不可修改');
    batch.photoIds.remove(photoId);
    if (batch.endPhotoId == photoId) {
      batch.endPhotoId = null;
      batch.secret = null;
    }
    await _save();
  });
  Future<void> setEnding(String batchId, String photoId) => _serial(() async {
    final batch = batches.firstWhere((b) => b.id == batchId);
    if (!batch.editable || !batch.photoIds.contains(photoId)) {
      throw StateError('不能修改该结束照');
    }
    batch.endPhotoId = photoId;
    batch.secret = photos[photoId]!.secret;
    await _save();
  });
  Future<void> newBatch() => _serial(() async {
    batches.add(PhotoBatch(_id(), []));
    await _save();
  });

  /// 只有摄影师点击调用，才冻结成员并上传；重试固定同一清单和目标，不会自动恢复上传。
  Future<void> uploadBatch(String batchId, ServerProfile profile) async {
    if (uploading || failed) throw StateError('当前不能上传');
    uploading = true;
    _notify();
    try {
      final batch = await _serial(() async {
        final b = batches.firstWhere((b) => b.id == batchId);
        if (!['draft', 'retry'].contains(b.state) ||
            b.endPhotoId == null ||
            b.secret == null ||
            b.photoIds.length < 2 ||
            b.photoIds.length > 101) {
          throw StateError('批次须有1至100张游客照和一张已识别的取片卡结束照');
        }
        final target = sha256
            .convert(
              utf8.encode(
                '${profile.host}:${profile.port}:${profile.user}:${profile.directory}',
              ),
            )
            .toString();
        if (b.target != null && b.target != target) {
          throw StateError('重试须使用原上传目标');
        }
        b.target = target;
        b.state = 'uploading';
        b.error = '';
        await _save();
        return b;
      });
      try {
        final members = batch.photoIds.map((id) => photos[id]!).toList();
        final prefix = 'manual-batches/${batch.id}';
        for (var i = 0; i < members.length; i++) {
          final photo = members[i];
          final file = File(photo.snapshot);
          if (!await file.exists() ||
              (await sha256.bind(file.openRead()).first).toString() !=
                  photo.digest) {
            throw StateError('待传副本缺失或变化，已停止该批次');
          }
          final transfer = PhotoTransfer(profile);
          try {
            await transfer.open(profile.directory);
            await transfer.uploadQueued(
              file,
              '$prefix/${photo.id}${photoUploadExtension(file.path)}',
              photo.id,
              photo.digest,
              (v) {
                batch.progress = (i + v) / (members.length + 1);
                _notify();
              },
            );
          } finally {
            await transfer.close();
          }
        }
        final manifest = File(p.join(storage.path, '${batch.id}.ready.json'));
        await manifest.writeAsString(
          jsonEncode({
            'version': 1,
            'batchId': batch.id,
            'cardSecret': batch.secret,
            'endPhotoId': batch.endPhotoId,
            'photos': members
                .map(
                  (photo) => {
                    'id': photo.id,
                    'name': '${photo.id}${p.extension(photo.snapshot)}',
                    'sha256': photo.digest,
                    'size': photo.size,
                  },
                )
                .toList(),
          }),
          flush: true,
        );
        final digest = (await sha256.bind(manifest.openRead()).first)
            .toString();
        final transfer = PhotoTransfer(profile);
        try {
          await transfer.open(profile.directory);
          await transfer.uploadQueued(
            manifest,
            'manual-batch-commits/${batch.id}.ready.json',
            batch.id,
            digest,
            (_) {},
          );
        } finally {
          await transfer.close();
        }
        await _serial(() async {
          batch.state = 'submitted';
          batch.progress = 1;
          await _save();
        });
        message = '批次文件及清单已上传，等待服务器校验归卡；不代表游客已可见';
      } catch (e) {
        await _serial(() async {
          batch.state = 'retry';
          batch.error = e is StateError ? e.message : '传输未确认，请检查网络后点击重试';
          await _save();
        });
        rethrow;
      }
    } finally {
      uploading = false;
      _notify();
    }
  }

  /// 主动检查后台接收结果，不自动上传或改动冻结成员。
  Future<void> checkReceipt(String batchId, ServerProfile profile) async {
    final batch = batches.firstWhere((b) => b.id == batchId);
    if (!['submitted', 'retry', 'accepted', 'rejected'].contains(batch.state)) {
      throw StateError('该批次尚未提交');
    }
    final target = sha256
        .convert(
          utf8.encode(
            '${profile.host}:${profile.port}:${profile.user}:${profile.directory}',
          ),
        )
        .toString();
    if (batch.target != target) throw StateError('须使用原上传目标检查回执');
    final transfer = PhotoTransfer(profile);
    try {
      await transfer.open(profile.directory);
      final receipt = await transfer.batchReceipt(batchId);
      if (receipt == null) {
        message = '服务器尚未返回归卡结果，请稍后检查';
        _notify();
        return;
      }
      if (receipt['version'] != 1 ||
          receipt['batchId'] != batchId ||
          !['ACCEPTED', 'REJECTED'].contains(receipt['state'])) {
        throw StateError('服务器回执不完整，未确认成功');
      }
      await _serial(() async {
        batch.state = receipt['state'] == 'ACCEPTED' ? 'accepted' : 'rejected';
        batch.error = batch.state == 'rejected'
            ? '服务器未接收该批次，请核对卡片机位和结束照，联系运营处理'
            : '';
        await _save();
      });
      message = batch.state == 'accepted' ? '服务器已确认该批次归卡' : batch.error;
      _notify();
    } finally {
      await transfer.close();
    }
  }

  Future<void> close() async {
    await stopWatching();
    await _journal?.close();
    _journal = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
