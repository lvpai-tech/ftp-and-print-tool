import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/auto_upload/folder_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/folder-access');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('苹果目录恢复使用书签返回的新路径，不信任缓存裸路径', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'restore' ? '/授权目录/已移动' : null;
    });
    final access = FolderAccess(channel: channel, apple: true);
    expect(await access.acquire('/旧路径'), '/授权目录/已移动');
    await access.release();
    expect(calls, ['restore', 'release']);
  });

  test('苹果书签缺失或被撤销明确失败，不退回裸路径', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final access = FolderAccess(channel: channel, apple: true);
    await expectLater(access.acquire('/仍存在的路径'), throwsStateError);
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'FOLDER_ACCESS');
    });
    await expectLater(
      access.acquire('/仍存在的路径'),
      throwsA(isA<PlatformException>()),
    );
  });

  test('取消苹果选择保持取消，收图目录由原生明确提供', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'inbox' ? '/Documents/CameraInbox' : null,
    );
    final access = FolderAccess(channel: channel, apple: true);
    expect(await access.choose(), isNull);
    expect(await access.useInbox(), '/Documents/CameraInbox');
  });

  test('Windows 开始和结束不调用苹果授权通道', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => fail('不应调用苹果通道'),
    );
    final access = FolderAccess(channel: channel, apple: false);
    expect(await access.acquire(r'D:\相机收图'), r'D:\相机收图');
    await access.release();
  });

  test('苹果选择取得独立书签，释放选择作用域不会释放已有机位', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'chooseScoped' => {'path': '/相机', 'bookmark': 'c2NvcGU='},
        'acquireScoped' => '/相机',
        _ => null,
      };
    });
    final access = FolderAccess(channel: channel, apple: true);
    final picked = (await access.chooseUploadFolder())!;
    await access.acquire(
      picked.path,
      scope: '20.selection',
      bookmark: picked.bookmark,
    );
    await access.release(scope: '20.selection');
    expect(calls.map((call) => call.method), [
      'chooseScoped',
      'acquireScoped',
      'releaseScoped',
    ]);
    expect(calls[1].arguments, {
      'scope': '20.selection',
      'path': '/相机',
      'bookmark': 'c2NvcGU=',
    });
    expect(calls[2].arguments, {'scope': '20.selection'});
  });
}
