import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/auto_upload/cos_upload.dart';
import 'package:lvpai_ftp_client/auto_upload/folder_access.dart';
import 'package:lvpai_ftp_client/auto_upload/station_upload.dart';
import 'package:lvpai_ftp_client/auto_upload/upload_folders.dart';
import 'package:lvpai_ftp_client/auto_upload/upload_slots.dart';
import 'package:lvpai_ftp_client/profile_store.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const store = ProfileStore();
  const gateway = 'https://upload.example';
  final first = CosUploadProfile(gateway, '11', 'a' * 64);
  final second = CosUploadProfile(gateway, '12', 'b' * 64);
  late Directory root, support;
  late UploadFolders folders;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('camera-folders-');
    addTearDown(() => root.delete(recursive: true));
    support = Directory(p.join(root.path, 'app'));
    folders = UploadFolders(
      store,
      Directory(p.join(support.path, 'inbox')),
      Directory(p.join(support.path, 'auto-upload')),
    );
  });

  Future<StationUpload> station(
    CosUploadProfile profile, {
    FolderAccess? access,
  }) async {
    final value = StationUpload(
      profile: profile,
      store: store,
      support: support,
      inboxRoot: folders.inbox,
      folders: folders,
      settings: await store.loadWatch(profile),
      transferSlots: UploadSlots(3),
      preparationSlots: UploadSlots(2),
      folderAccess: access ?? FolderAccess(apple: false),
    );
    addTearDown(() async {
      await value.suspend();
      value.dispose();
    });
    return value;
  }

  test('原单机位目录和已暂停的新机位拒绝同目录与父子目录', () async {
    final old = await Directory(p.join(root.path, 'camera', 'old'))
        .create(recursive: true);
    final child = await Directory(p.join(old.path, 'child')).create();
    final other = await Directory(p.join(root.path, 'camera', 'old-2'))
        .create();
    FlutterSecureStorage.setMockInitialValues({
      'cos.auto.profile.v1': jsonEncode(first.toJson()),
      'ftp.watch.v1': jsonEncode({'folder': old.path, 'recursive': true}),
    });
    await store.saveCos(second);
    await store.migrateUploads(first.api);
    final oldStation = await station(first);
    final newStation = await station(second);
    expect(oldStation.folder, old.path);
    expect(oldStation.running, isFalse);
    for (final path in [
      old.path,
      old.parent.path,
      child.path,
      if (Platform.isWindows) old.path.toUpperCase(),
    ]) {
      await newStation.changeFolder((path: path, bookmark: null));
      expect(newStation.message, contains('机位 11'));
      expect(newStation.hasFolder, isFalse);
    }
    await newStation.changeFolder((path: other.path, bookmark: null));
    expect(newStation.folder, other.path);
    expect(newStation.enabled, isFalse);
    expect(newStation.message, isNull);
    await oldStation.changeFolder((path: other.path, bookmark: null));
    expect(oldStation.message, contains('机位 12'));
    expect(oldStation.folder, old.path);
  });

  test('物理目录别名不能绕过占用检查', () async {
    final photos = await Directory(p.join(root.path, 'camera')).create();
    final alias = p.join(root.path, 'alias');
    if (Platform.isWindows) {
      final result = await Process.run(
        'pwsh',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'New-Item -ItemType Junction -Path $env:LVPAI_TEST_ALIAS -Target $env:LVPAI_TEST_FOLDER | Out-Null',
        ],
        environment: {
          'LVPAI_TEST_ALIAS': alias,
          'LVPAI_TEST_FOLDER': photos.path,
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
    } else {
      await Link(alias).create(photos.path);
    }
    addTearDown(() async {
      if (await Link(alias).exists()) await Link(alias).delete();
    });
    await store.saveCos(first);
    await store.saveCos(second);
    final owner = await station(first);
    await owner.changeFolder((path: photos.path, bookmark: null));
    expect(owner.message, isNull);
    final newcomer = await station(second);
    await newcomer.changeFolder((path: alias, bookmark: null));
    expect(newcomer.message, contains('机位 11'));
    expect(newcomer.hasFolder, isFalse);
  });

  test('并行选择同一目录只保存一次，重启恢复已启用的自选目录', () async {
    final photos = await Directory(p.join(root.path, 'camera')).create();
    await store.saveCos(first);
    await store.saveCos(second);
    final a = await station(first);
    final b = await station(second);
    final selection = (path: photos.path, bookmark: null);
    await Future.wait([a.changeFolder(selection), b.changeFolder(selection)]);
    expect([a, b].where((value) => value.hasFolder), hasLength(1));
    final selected = [a, b].singleWhere((value) => value.hasFolder);
    final blocked = [a, b].singleWhere((value) => !value.hasFolder);
    expect(blocked.message, contains('机位 ${selected.profile.stationId}'));
    await selected.setEnabled(true);
    expect(selected.running, isTrue);
    await selected.suspend();
    final restarted = await station(selected.profile);
    await restarted.restore();
    expect(restarted.folder, photos.path);
    expect(restarted.running, isTrue);
    await restarted.suspend();
    await store.removeCos(selected.profile);
    await blocked.changeFolder(selection);
    expect(blocked.message, contains('机位 ${selected.profile.stationId}'));
  });

  test('收图目录离线时报告不可用，目录恢复后继续同一队列', () async {
    final photos = await Directory(p.join(root.path, 'camera')).create();
    await store.saveCos(first);
    final selected = await station(first);
    await selected.changeFolder((path: photos.path, bookmark: null));
    await selected.setEnabled(true);
    expect(selected.running, isTrue);
    final moved = await photos.rename(p.join(root.path, 'offline'));
    await selected.uploader.scanNow();
    expect(selected.status, '收图目录不可用');
    expect(selected.canImport, isFalse);
    await moved.rename(photos.path);
    await selected.uploader.scanNow();
    expect(selected.status, '监听中');
    expect(selected.canImport, isTrue);
  });

  test('重选授权失效的原目录后恢复已启用机位', () async {
    final photos = await Directory(p.join(root.path, 'camera')).create();
    await store.saveCos(first);
    await store.saveWatch(first, {
      'folder': photos.path,
      'folderIdentity': await photos.resolveSymbolicLinks(),
      'folderBookmark': 'old',
      'enabled': true,
    });
    const channel = MethodChannel('test/station-folder-access');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'acquireScoped') return null;
      final args = call.arguments as Map;
      if (args['bookmark'] == 'old') {
        throw PlatformException(code: 'FOLDER_ACCESS');
      }
      return photos.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final selected = await station(
      first,
      access: FolderAccess(channel: channel, apple: true),
    );
    await selected.restore();
    expect(selected.status, '收图目录不可用');
    expect(selected.enabled, isTrue);
    await selected.changeFolder((path: photos.path, bookmark: 'new'));
    expect(selected.running, isTrue);
    expect((await store.loadWatch(first))?['folderBookmark'], 'new');
  });
}
