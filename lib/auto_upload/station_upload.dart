import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../photo_normalizer.dart';
import '../profile_store.dart';
import 'cos_upload.dart';
import 'folder_access.dart';
import 'folder_uploader.dart';
import 'upload_slots.dart';

/// 一个机位的目录和队列由上传工作台持有，可跨页面持续运行。
class StationUpload extends ChangeNotifier {
  StationUpload({
    required this.profile,
    required this.store,
    required Directory support,
    required Directory inboxRoot,
    required UploadSlots transferSlots,
    required UploadSlots preparationSlots,
    FolderAccess? folderAccess,
    Map<String, dynamic>? settings,
  }) : _managed = Directory(
         p.join(
           inboxRoot.path,
           ProfileStore.uploadScope(profile.api),
           profile.stationId,
         ),
       ),
       _access = folderAccess ?? FolderAccess(),
       _legacyFolder = settings?['legacyFolder'] as String?,
       _legacyRecursive = settings?['recursive'] as bool? ?? true,
       _scanLegacyExisting = settings?['scanLegacyExisting'] == true,
       enabled =
           settings?['enabled'] as bool? ?? settings?['legacyFolder'] == null,
       uploader = FolderUploader(
         storage: Directory(p.join(support.path, 'auto-upload')),
         transferSlots: transferSlots,
         preparationSlots: preparationSlots,
       ) {
    uploader.addListener(_changed);
  }

  CosUploadProfile profile;
  final ProfileStore store;
  final FolderUploader uploader;
  final Directory _managed;
  final bool _legacyRecursive;
  bool _scanLegacyExisting;
  final FolderAccess _access;
  String? _legacyFolder;
  bool _legacyAcquired = false;
  bool enabled;
  bool _closed = false;
  Future<void>? _work;
  String? message;

  bool get legacy => _legacyFolder != null;
  String get folder => _legacyFolder ?? _managed.path;
  bool get busy => _work != null;
  bool get active => busy || uploader.requiresStop;
  bool get uploading => uploader.jobs.any((job) => job.state == 'uploading');
  int get pending =>
      uploader.settling +
      uploader.jobs
          .where(
            (job) =>
                const {'pending', 'uploading', 'accepted'}.contains(job.state),
          )
          .length;
  int get failures =>
      uploader.jobs.where((job) => job.state == 'failed').length;
  DateTime? get latestIngested => uploader.latestIngested;

  String get name => [
    profile.stationCode,
    profile.stationName,
  ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');

  String get status {
    if (busy) return '处理中';
    if (uploader.authorizationPaused) return '授权失效';
    if (uploader.fatalError != null || message != null) return '需要处理';
    if (uploader.sourcesNeedingOrder.isNotEmpty) return '待确认顺序';
    if (failures > 0 || uploader.issues.isNotEmpty) return '有异常';
    if (uploading) return '上传中';
    if (uploader.running) return '监听中';
    if (legacy && !enabled) return '待恢复旧目录';
    return '已暂停';
  }

  Future<void> _save({required bool enabled, required String? legacyFolder}) =>
      store.saveWatch(profile, {
        'enabled': enabled,
        'legacyFolder': ?legacyFolder,
        'recursive': _legacyRecursive,
        if (legacyFolder != null && _scanLegacyExisting)
          'scanLegacyExisting': true,
      });

  Future<void> restore() => _run(() async {
    if (enabled) await _start();
  });

  Future<void> setEnabled(bool value, {bool scanLegacyExisting = false}) =>
      _run(() async {
        if (value && legacy) _scanLegacyExisting = scanLegacyExisting;
        await _save(enabled: value, legacyFolder: _legacyFolder);
        enabled = value;
        if (value) {
          await _start();
        } else {
          await _stop();
        }
      });

  Future<void> suspend() => _run(_stop);

  Future<void> suspendForUpdate() => _run(_stop, propagate: true);

  Future<void> resume() => restore();

  Future<void> replaceProfile(CosUploadProfile next, {required bool start}) =>
      _run(() async {
        if (profile.queueTarget != next.queueTarget) {
          throw StateError('机位配置与队列不一致');
        }
        await _stop();
        profile = next;
        if (enabled && start) await _start();
      });

  Future<void> finishMigration() => _run(() async {
    if (!legacy || !uploader.running || uploader.authorizationPaused) {
      throw StateError('请先恢复旧目录监听并处理队列');
    }
    await uploader.scanNow();
    if (!uploader.canFinishMigration) {
      throw StateError('请停止向旧目录投递，并先处理旧目录中的待传、待确认或失败照片');
    }
    await _stop();
    await _save(enabled: true, legacyFolder: null);
    _legacyFolder = null;
    enabled = true;
    await _start();
  });

  Future<void> _start() async {
    if (uploader.running) return;
    if (uploader.fatalError != null) await _stop();
    await _ensureManaged();
    try {
      if (legacy && _access.apple && !_legacyAcquired) {
        final authorized = await _access.acquire(folder);
        _legacyAcquired = true;
        if (!p.equals(
          await Directory(folder).resolveSymbolicLinks(),
          await Directory(authorized).resolveSymbolicLinks(),
        )) {
          throw StateError('旧目录授权与原队列不一致，请恢复原目录授权');
        }
      }
      if (legacy) {
        final previous = await Directory(folder).resolveSymbolicLinks();
        final root = await _managed.parent.resolveSymbolicLinks();
        if (p.equals(previous, root) ||
            p.isWithin(previous, root) ||
            p.isWithin(root, previous)) {
          throw StateError('旧收图路径与托管路径重叠，请联系管理员保留旧队列并迁移');
        }
      }
      await uploader.start(
        Directory(folder),
        null,
        cosProfile: profile,
        recursive: !legacy || _legacyRecursive,
        includeExisting: !legacy || _scanLegacyExisting,
      );
    } catch (_) {
      await _releaseLegacy();
      rethrow;
    }
  }

  Future<void> _releaseLegacy() async {
    if (!_legacyAcquired) return;
    await _access.release();
    _legacyAcquired = false;
  }

  Future<void> _stop() async {
    try {
      if (uploader.requiresStop) await uploader.stop();
    } finally {
      await _releaseLegacy();
    }
  }

  Future<void> importPhotos(List<File> photos) => _run(() async {
    if (legacy) throw StateError('请先完成旧目录切换');
    if (photos.isEmpty) return;
    await _ensureManaged();
    final local = await _managed.resolveSymbolicLinks();
    for (final photo in photos) {
      final extension = p.extension(photo.path).toLowerCase();
      if (extension.isEmpty ||
          !cameraPhotoExtensions.contains(extension.substring(1))) {
        throw StateError('选取的文件包含不支持的照片格式');
      }
      if (p.isWithin(local, await photo.resolveSymbolicLinks())) {
        throw StateError('所选照片已经在当前机位的收图目录中');
      }
    }
    final staging = await _managed.parent.createTemp('import-');
    try {
      final names = <String>{};
      for (final photo in photos) {
        final name = p.basename(photo.path);
        if (!names.add(name.toLowerCase())) {
          throw StateError('本次导入包含同名文件，请分批导入');
        }
        await photo.copy(p.join(staging.path, name));
      }
      await staging.rename(p.join(_managed.path, p.basename(staging.path)));
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
    await uploader.scanNow();
  });

  Future<void> _run(
    Future<void> Function() operation, {
    bool propagate = false,
  }) {
    if (_closed) return Future.value();
    late final Future<void> next;
    next = (_work ?? Future<void>.value())
        .then((_) async {
          if (_closed) return;
          message = null;
          _changed();
          try {
            await operation();
          } catch (error) {
            message = error is StateError
                ? error.message
                : '收图操作失败，请检查目录、存储空间或访问权限';
            if (propagate) rethrow;
          }
        })
        .whenComplete(() {
          if (identical(_work, next)) _work = null;
          _changed();
        });
    return _work = next;
  }

  Future<void> _ensureManaged() async {
    final environment = _managed.parent;
    final root = environment.parent;
    await root.create(recursive: true);
    final local = await root.resolveSymbolicLinks();
    await environment.create();
    if (!p.equals(
      await environment.resolveSymbolicLinks(),
      p.join(local, p.basename(environment.path)),
    )) {
      throw StateError('收图路径被重定向，请恢复该机位的本地收图目录');
    }
    await _managed.create(recursive: true);
    if (!p.equals(
      await _managed.resolveSymbolicLinks(),
      p.join(local, p.basename(environment.path), p.basename(_managed.path)),
    )) {
      throw StateError('收图路径被重定向，请恢复该机位的本地收图目录');
    }
  }

  void _changed() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    uploader.removeListener(_changed);
    unawaited(
      () async {
        try {
          await _work;
          await _stop();
        } finally {
          uploader.dispose();
        }
      }().catchError((Object _) {}),
    );
    super.dispose();
  }
}
