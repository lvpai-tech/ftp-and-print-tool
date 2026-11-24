import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../photo_normalizer.dart';
import '../profile_store.dart';
import '../workstation_storage.dart';
import 'cos_upload.dart';
import 'folder_access.dart';
import 'folder_uploader.dart';
import 'upload_folders.dart';
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
    UploadFolders? folders,
    Map<String, dynamic>? settings,
    this.personnelToken,
  }) : _managed = Directory(
         p.join(
           inboxRoot.path,
           ProfileStore.uploadScope(profile.api),
           profile.stationId,
         ),
       ),
       _access = folderAccess ?? FolderAccess(),
       _folders =
           folders ??
           UploadFolders(
             store,
             inboxRoot,
             Directory(p.join(support.path, 'auto-upload')),
           ),
       _customFolder = settings?['folder'] as String?,
       _folderIdentity = settings?['folderIdentity'] as String?,
       _bookmark = settings?['folderBookmark'] as String?,
       _folderRequired = settings?['folderRequired'] == true,
       _legacyFolder = settings?['legacyFolder'] as String?,
       _legacyRecursive = settings?['recursive'] as bool? ?? true,
       _scanExisting =
           (settings?['scanExisting'] ?? settings?['scanLegacyExisting']) ==
           true,
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
  final String? Function()? personnelToken;
  final Directory _managed;
  final UploadFolders _folders;
  final bool _legacyRecursive;
  bool _scanExisting;
  final FolderAccess _access;
  String? _customFolder, _folderIdentity, _bookmark;
  bool _folderRequired;
  String? _legacyFolder;
  bool _folderAcquired = false;
  bool _folderAccessFailed = false;
  bool _importWritable = true;
  bool enabled;
  bool _closed = false;
  Future<void>? _work;
  String? message;

  bool get legacy => _legacyFolder != null;
  bool get hasFolder => folder.isNotEmpty;
  bool get custom => _customFolder != null;
  bool get scanExisting => _scanExisting;
  bool get canImport =>
      hasFolder &&
      !legacy &&
      !folderUnavailable &&
      _importWritable &&
      (!custom || running);
  bool get folderUnavailable =>
      enabled &&
      (_folderAccessFailed ||
          (uploader.running && !uploader.directoryReadable));
  String? get importUnavailable => running && !_importWritable
      ? '当前无法写入此收图文件夹。自动收图可用，导入照片需恢复写入后重新监听。'
      : null;
  String get folder =>
      _customFolder ?? _legacyFolder ?? (_folderRequired ? '' : _managed.path);
  bool get busy => _work != null;
  bool get active => busy || uploader.requiresStop;
  bool get running =>
      uploader.directoryReadable && !uploader.authorizationPaused;
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

  Future<void> reportCardTail(AutoJob job, int byteLength, String tail) async {
    if (_closed || !uploader.jobs.contains(job)) {
      throw StateError('上传任务已切换，请重新打开照片');
    }
    final client = CosUpload(profile);
    try {
      await client.reportCardTail(
        job.snapshot,
        job.id,
        byteLength,
        job.digest,
        job.captureMetadata,
        tail,
      );
    } finally {
      client.close();
    }
  }

  String get name => [
    profile.stationCode,
    profile.stationName,
  ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');

  String get status {
    if (busy) return '处理中';
    if (uploader.authorizationPaused) return '授权失效';
    if (folderUnavailable) return '收图目录不可用';
    if (uploader.fatalError != null || message != null) return '需要处理';
    if (uploader.sourcesNeedingOrder.isNotEmpty) return '待确认顺序';
    if (failures > 0 || uploader.issues.isNotEmpty) return '有异常';
    if (uploading) return '上传中';
    if (uploader.running) return '监听中';
    if (legacy && !enabled) return '待恢复旧目录';
    if (!hasFolder) return '待选择目录';
    return '已暂停';
  }

  Map<String, dynamic> _settings({required bool enabled}) => {
    'enabled': enabled,
    if (_folderRequired) 'folderRequired': true,
    'folder': ?_customFolder,
    'folderIdentity': ?_folderIdentity,
    'folderBookmark': ?_bookmark,
    'legacyFolder': ?_legacyFolder,
    'recursive': !legacy || _legacyRecursive,
    if (_scanExisting) (legacy ? 'scanLegacyExisting' : 'scanExisting'): true,
  };

  Future<void> restore() => _run(() async {
    if (enabled) await _start();
  });

  Future<void> setEnabled(bool value, {bool? scanExisting}) => _run(() async {
    if (value && !hasFolder) throw StateError('请先选择收图文件夹');
    final settings = _settings(enabled: value);
    if (value && (legacy || custom) && scanExisting != null) {
      settings[legacy ? 'scanLegacyExisting' : 'scanExisting'] = scanExisting;
    }
    await store.saveWatch(profile, settings);
    if (value && scanExisting != null) _scanExisting = scanExisting;
    enabled = value;
    if (value) {
      await _start();
    } else {
      await _stop();
      _folderAccessFailed = false;
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

  Future<PickedUploadFolder?> chooseFolder() => _access.chooseUploadFolder();

  Future<void> changeFolder(PickedUploadFolder picked) => _run(
    () => _folders.change(() async {
      if (!p.isAbsolute(picked.path)) throw StateError('请选择有效的收图文件夹');
      final scope = '${ProfileStore.uploadKey(profile)}.selection';
      final selected = await _access.acquire(
        picked.path,
        scope: scope,
        bookmark: picked.bookmark,
      );
      try {
        final resolved = await Directory(selected).resolveSymbolicLinks();
        // Open the directory before storing a location that may be unreadable.
        await Directory(selected)
            .list(followLinks: false)
            .take(1)
            .drain<void>();
        final previous = hasFolder
            ? _folderIdentity ?? await UploadFolders.identity(folder)
            : null;
        final same = previous != null && UploadFolders.same(previous, resolved);
        await _folders.validate(
          profile,
          selected,
          resolved,
          managed: same && !legacy && !custom,
        );
        if (same && !legacy && !custom) return;
        final restart = uploader.running;
        if (!same && previous != null) {
          if (uploader.running) {
            await uploader.scanNow();
            if (uploader.authorizationPaused || !uploader.canFinishMigration) {
              throw StateError('请停止向原目录投递，并处理完待传、待确认及失败照片后再更换目录');
            }
          } else if (await uploader.hasCosQueue(previous, profile)) {
            throw StateError('请先恢复原目录监听，确认原队列处理完毕后再更换目录');
          }
        }
        final settings = same
            ? (_settings(enabled: enabled)
                ..['folderIdentity'] = resolved
                ..['folderBookmark'] = picked.bookmark)
            : {
                'enabled': false,
                'folder': picked.path,
                'folderIdentity': resolved,
                'folderBookmark': ?picked.bookmark,
                'recursive': true,
              };
        await _stop();
        if (!same && restart && !uploader.queueDrained) {
          await _start();
          throw StateError('原目录还有未处理的照片，请稍后重试');
        }
        try {
          await store.saveWatch(profile, settings);
        } catch (_) {
          if (restart) await _start();
          rethrow;
        }
        _folderIdentity = resolved;
        _bookmark = picked.bookmark;
        if (!same) {
          _customFolder = picked.path;
          _legacyFolder = null;
          _folderRequired = false;
          _scanExisting = false;
          enabled = false;
          uploader.clearView();
        } else if (enabled) {
          await _start();
        }
      } finally {
        await _access.release(scope: scope);
      }
    }),
  );

  Future<void> _start() async {
    if (uploader.running) return;
    if (uploader.fatalError != null) await _stop();
    if (!hasFolder) return;
    final managed = !legacy && !custom;
    _folderAccessFailed = false;
    _importWritable = true;
    try {
      if (managed) await _ensureManaged();
      if (!managed && _access.apple && !_folderAcquired) {
        _folderAccessFailed = true;
        final authorized = await _access.acquire(
          folder,
          scope: ProfileStore.uploadKey(profile),
          bookmark: _bookmark,
        );
        _folderAcquired = true;
        if (!UploadFolders.same(
          await Directory(folder).resolveSymbolicLinks(),
          await Directory(authorized).resolveSymbolicLinks(),
        )) {
          throw StateError('目录授权与原队列不一致，请重新选择原目录');
        }
        _folderAccessFailed = false;
      }
      final resolved = await Directory(folder).resolveSymbolicLinks();
      if (_folderIdentity != null &&
          !UploadFolders.same(_folderIdentity!, resolved)) {
        _folderAccessFailed = true;
        throw StateError('收图目录指向已变化，请恢复原目录后再监听');
      }
      await _folders.validate(profile, folder, resolved, managed: managed);
      if (Platform.isMacOS && custom) {
        try {
          await checkWritableDirectory(Directory(resolved));
        } on FileSystemException {
          _importWritable = false;
        }
      }
      await uploader.start(
        Directory(folder),
        null,
        cosProfile: profile,
        personnelToken: personnelToken,
        recursive: !legacy || _legacyRecursive,
        includeExisting: managed || _scanExisting,
      );
    } on PlatformException catch (error) {
      await _releaseFolder();
      if (error.code != 'FOLDER_ACCESS') rethrow;
      _folderAccessFailed = true;
      throw StateError('无法访问收图文件夹。请重新选择原文件夹，或在「系统设置 → 隐私与安全性 → 文件与文件夹」恢复访问。');
    } on FileSystemException {
      await _releaseFolder();
      _folderAccessFailed = true;
      throw StateError('无法访问收图文件夹或待传目录，请检查目录和磁盘连接后重试。');
    } catch (_) {
      await _releaseFolder();
      rethrow;
    }
  }

  Future<void> _releaseFolder() async {
    if (!_folderAcquired) return;
    await _access.release(scope: ProfileStore.uploadKey(profile));
    _folderAcquired = false;
  }

  Future<void> _stop() async {
    try {
      if (uploader.requiresStop) await uploader.stop();
    } finally {
      await _releaseFolder();
    }
  }

  Future<void> importPhotos(List<File> photos) => _run(() async {
    if (!canImport) throw StateError('请先选择收图文件夹并开始监听');
    if (photos.isEmpty) return;
    if (!custom) await _ensureManaged();
    final directory = Directory(folder);
    final local = await directory.resolveSymbolicLinks();
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
    final staging = custom
        ? await directory.createTemp(FolderUploader.importStagingPrefix)
        : await _managed.parent.createTemp('import-');
    try {
      final names = <String>{};
      for (final photo in photos) {
        final name = p.basename(photo.path);
        if (!names.add(name.toLowerCase())) {
          throw StateError('本次导入包含同名文件，请分批导入');
        }
        await photo.copy(p.join(staging.path, name));
      }
      final name = p.basename(staging.path);
      await staging.rename(
        p.join(
          directory.path,
          custom ? name.substring('.lvpai-'.length) : name,
        ),
      );
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
