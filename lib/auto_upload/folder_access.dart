import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

typedef PickedUploadFolder = ({String path, String? bookmark});

/// 苹果端由原生层保管目录书签及安全作用域；Dart 不把裸路径当成授权。
class FolderAccess {
  final MethodChannel channel;
  final bool apple;
  FolderAccess({MethodChannel? channel, bool? apple})
    : channel = channel ?? const MethodChannel('ai.lvpai.ftp/folder-access'),
      apple = apple ?? (Platform.isMacOS || Platform.isIOS);

  Future<String?> restore() async =>
      apple ? await channel.invokeMethod<String>('restore') : null;

  Future<String?> choose() async {
    if (apple) return channel.invokeMethod<String>('choose');
    return (await FilePicker.pickDirectory(dialogTitle: '选择相机照片接收文件夹'))
        ?.toFilePath();
  }

  Future<PickedUploadFolder?> chooseUploadFolder() async {
    if (!apple) {
      final path = await choose();
      return path == null ? null : (path: path, bookmark: null);
    }
    final selection = await channel.invokeMapMethod<String, String>(
      'chooseScoped',
    );
    if (selection == null) return null;
    final path = selection['path'];
    final bookmark = selection['bookmark'];
    if (path == null || bookmark == null || bookmark.isEmpty) {
      throw StateError('未取得文件夹授权，请重新选择');
    }
    return (path: path, bookmark: bookmark);
  }

  Future<String> acquire(String path, {String? scope, String? bookmark}) async {
    if (!apple) return path;
    final restored = scope == null
        ? await restore()
        : await channel.invokeMethod<String>('acquireScoped', {
            'scope': scope,
            'bookmark': ?bookmark,
          });
    if (restored == null || restored.isEmpty) {
      throw StateError('目录授权不存在，请重新选择文件夹');
    }
    return restored;
  }

  Future<String> useInbox() async {
    final path = await channel.invokeMethod<String>('inbox');
    if (path == null || path.isEmpty) throw StateError('无法创建收图目录');
    return path;
  }

  Future<void> release({String? scope}) async {
    if (!apple) return;
    if (scope == null) {
      await channel.invokeMethod<void>('release');
    } else {
      await channel.invokeMethod<void>('releaseScoped', {'scope': scope});
    }
  }
}
