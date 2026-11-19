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
}
