import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../profile_store.dart';
import 'cos_upload.dart';

class UploadFolders {
  UploadFolders(this.store, this.inbox, this.queueStorage);

  final ProfileStore store;
  final Directory inbox;
  final Directory queueStorage;
  Future<void> _changes = Future.value();

  Future<void> change(Future<void> Function() action) {
    final next = _changes.then((_) => action());
    _changes = next.catchError((Object _) {});
    return next;
  }

  static bool same(String first, String second) =>
      p.equals(p.canonicalize(first), p.canonicalize(second));

  static bool _overlaps(String first, String second) {
    final a = p.canonicalize(first);
    final b = p.canonicalize(second);
    return p.equals(a, b) || p.isWithin(a, b) || p.isWithin(b, a);
  }

  // Resolve the nearest accessible ancestor even if a configured folder is offline.
  static Future<String> identity(String path) async {
    var directory = p.absolute(path);
    final leaf = <String>[];
    while (true) {
      try {
        final resolved = await Directory(directory)
            .resolveSymbolicLinks()
            .timeout(const Duration(seconds: 3));
        return p.normalize(p.joinAll([resolved, ...leaf.reversed]));
      } on TimeoutException {
        return p.normalize(p.absolute(path));
      } on FileSystemException {
        final parent = p.dirname(directory);
        if (parent == directory) return p.normalize(p.absolute(path));
        leaf.add(p.basename(directory));
        directory = parent;
      }
    }
  }

  Future<void> validate(
    CosUploadProfile profile,
    String path,
    String resolved, {
    required bool managed,
  }) async {
    if (!managed) {
      for (final root in [inbox, queueStorage]) {
        if (_overlaps(path, root.path) ||
            _overlaps(resolved, root.path) ||
            _overlaps(resolved, await identity(root.path))) {
          throw StateError('收图目录不能与软件的托管收图目录或待传区重叠');
        }
      }
    }
    final current = ProfileStore.uploadKey(profile);
    for (final folder in await store.loadWatchFolders()) {
      if (folder.key == current) continue;
      final paths = {
        folder.path,
        ?folder.identity,
        await identity(folder.path),
      };
      if (paths.any(
        (other) => _overlaps(path, other) || _overlaps(resolved, other),
      )) {
        final owner = folder.key?.split('.').last;
        throw StateError(
          owner == null
              ? '此目录与旧上传配置的收图目录重叠，请选择其他文件夹'
              : '此目录与机位 $owner 的收图目录重叠，请选择其他文件夹',
        );
      }
    }
  }
}
