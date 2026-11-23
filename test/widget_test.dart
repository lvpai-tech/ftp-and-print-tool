import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/auto_upload/cos_upload.dart';
import 'package:lvpai_ftp_client/printing/print_bridge.dart';
import 'package:lvpai_ftp_client/profile_store.dart';
import 'package:lvpai_ftp_client/ui/transfer_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

void main() {
  const apiBase = String.fromEnvironment(
    'LVPAI_WORKSTATION_API_BASE',
    defaultValue: 'https://hilvpai.com',
  );
  final gateway = Uri.parse(apiBase);
  late Directory support;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    support = await Directory.systemTemp.createTemp('station-ui-');
  });

  tearDown(() async {
    await support.delete(recursive: true);
  });

  Future<void> showUpload(WidgetTester tester, {PrintBridge? bridge}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TransferPage(
          supportDirectory: () async => support,
          printBridge: bridge,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('上传页使用机位所属档案并保留上传队列入口', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    FlutterSecureStorage.setMockInitialValues({
      'cos.auto.profile.v1': jsonEncode({
        'api': gateway.origin,
        'stationId': '317',
        'stationCode': 'A08',
        'scenicId': '5',
        'scenicName': '汉京中心',
        'token': 'a' * 64,
      }),
    });
    final bridge = _BatchBridge();
    addTearDown(bridge.dispose);
    await showUpload(tester, bridge: bridge);
    await tester.tap(find.text('A08'));
    await tester.pumpAndSettle();
    expect(find.text('照片批次矫正'), findsOneWidget);
    expect(find.text('取片卡 6969'), findsOneWidget);
    expect(bridge.calls, ['listBatchStations', 'listPhotoBatches']);
    await tester.tap(find.text('上传队列'));
    await tester.pumpAndSettle();
    expect(find.text('本机暂无上传任务'), findsOneWidget);
    await tester.tap(find.text('取片批次'));
    await tester.pumpAndSettle();
    expect(find.text('取片卡 6969'), findsOneWidget);
    expect(bridge.calls, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> settleStorage(
    WidgetTester tester,
    Future<void> Function() operation,
  ) async {
    await operation();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
  }

  Future<void> waitForStationUi(
    WidgetTester tester,
    Finder finder, {
    bool present = true,
  }) async {
    for (var attempt = 0; attempt < 80; attempt++) {
      await tester.pump();
      if (finder.evaluate().isNotEmpty == present) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
    await tester.pumpAndSettle();
    expect(finder, present ? findsOneWidget : findsNothing);
  }

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(1280, 900),
  ]) {
    testWidgets('首次申请入口和手动绑定在 ${size.width}×${size.height} 可用', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'ftp.profile.v1': jsonEncode({'host': 'ftp.invalid'}),
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showUpload(tester);
      expect(find.text('申请机位'), findsOneWidget);

      await tester.tap(find.text('手动绑定机位'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();
      expect(find.text('请填写机位 ID 和有效机位密钥'), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '317');
      await tester.enterText(fields.at(1), 'a' * 64);
      await settleStorage(tester, () => tester.tap(find.text('保存配置')));
      final saved = (await const ProfileStore().loadStations(gateway)).single;
      expect(saved.stationId, '317');
      expect(find.text('机位 317'), findsOneWidget);
      expect(find.textContaining('待选择目录'), findsOneWidget);
      expect(find.text('运行中'), findsNothing);
      expect(find.text('申请机位'), findsOneWidget);
      await tester.ensureVisible(find.text('机位 317'));
      await tester.tap(find.text('机位 317'));
      await tester.pumpAndSettle();
      expect(find.text('选择收图文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 75));
      });
    });
  }

  testWidgets('现有机位可查看原收图路径，仍可同时管理其他机位', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'cos.auto.profile.v1': jsonEncode({
        'api': gateway.origin,
        'stationId': '317',
        'token': 'a' * 64,
        'stationCode': 'A17',
      }),
      'ftp.watch.v1': jsonEncode({'folder': 'test-inbox', 'recursive': true}),
    });
    await showUpload(tester);
    expect(find.text('A17'), findsOneWidget);
    await tester.tap(find.text('A17'));
    await tester.pumpAndSettle();
    expect(find.text('test-inbox'), findsOneWidget);
    expect(find.text('更换收图文件夹'), findsOneWidget);
    expect(find.text('恢复旧目录监听'), findsOneWidget);
    await tester.tap(find.text('更新机位密钥'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).readOnly, isTrue);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, '317');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回机位列表'));
    await tester.pumpAndSettle();
    expect(find.text('申请机位'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 75));
    });
  });

  testWidgets('刷新显示各机位状态，移除单个机位保留目录和旧配置隔离', (tester) async {
    const store = ProfileStore();
    final legacy = CosUploadProfile(
      gateway.origin,
      '317',
      'a' * 64,
      stationCode: 'A17',
    );
    FlutterSecureStorage.setMockInitialValues({
      'cos.auto.profile.v1': jsonEncode(legacy.toJson()),
      'ftp.watch.v1': jsonEncode({'folder': 'test-inbox', 'recursive': true}),
    });
    await showUpload(tester);
    expect(find.text('未运行'), findsOneWidget);
    expect(find.textContaining('待恢复旧目录'), findsOneWidget);

    final added = CosUploadProfile(gateway.origin, '318', 'b' * 64);
    await store.saveCos(added, keepManagedDefault: true);
    await tester.tap(find.text('刷新机位'));
    await waitForStationUi(tester, find.text('运行中'));
    expect(find.text('未运行'), findsOneWidget);
    final addedFolder = Directory(
      p.join(support.path, 'inbox', ProfileStore.uploadScope(gateway), '318'),
    );
    final marker = File(p.join(addedFolder.path, 'keep.txt'));
    await tester.runAsync(() => marker.writeAsString('保留本机文件'));
    final queueLog = await tester.runAsync(
      () async =>
          Directory(p.join(support.path, 'auto-upload'))
              .listSync(recursive: true)
              .whereType<File>()
              .singleWhere((file) => p.basename(file.path) == 'queue.jsonl'),
    );

    Future<void> openRemoval(String id) async {
      final row = find.byKey(ValueKey(id));
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('机位操作')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('从本机移除'));
      await tester.pumpAndSettle();
    }

    await openRemoval('318');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('机位 318'), findsOneWidget);
    await openRemoval('318');
    await tester.tap(find.text('确认移除'));
    await waitForStationUi(tester, find.text('机位 318'), present: false);
    expect((await store.loadStations(gateway)).single.stationId, '317');
    expect(await tester.runAsync(marker.readAsString), '保留本机文件');
    expect(queueLog?.existsSync(), isTrue);

    await openRemoval('317');
    await tester.tap(find.text('确认移除'));
    await waitForStationUi(tester, find.text('A17'), present: false);
    await store.migrateUploads(gateway);
    expect(await store.loadStations(gateway), isEmpty);
    expect((await store.loadWatch(legacy))?['legacyFolder'], 'test-inbox');
    expect(find.text('A17'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('另一个服务的机位凭据和目录不会进入当前列表', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'cos.auto.profile.v1': jsonEncode({
        'api': 'https://old-upload.example',
        'stationId': '317',
        'token': 'a' * 64,
      }),
    });
    await showUpload(tester);
    expect(find.text('申请机位'), findsOneWidget);
    expect(find.text('机位 317'), findsNothing);
    await tester.tap(find.text('手动绑定机位'));
    await tester.pumpAndSettle();
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.controller?.text, isEmpty);
    }
  });
}

class _BatchBridge extends PrintBridge {
  _BatchBridge() {
    connected = true;
    snapshot = {
      'configured': true,
      'config': {
        'activeScenicProfileId': 'active-print',
        'scenicProfiles': [
          {
            'id': 'active-print',
            'scenicIds': ['1'],
            'scenicName': '蓝月谷',
          },
          {
            'id': 'upload-scenic',
            'scenicIds': ['5'],
            'scenicName': '汉京中心',
          },
        ],
      },
    };
  }

  final calls = <String>[];

  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    calls.add(method);
    expect(args.last, {'profileId': 'upload-scenic', 'scenicId': '5'});
    return switch (method) {
      'listBatchStations' => <Json>[
        {'id': '317', 'code': 'A08', 'name': '验收机位'},
      ],
      'listPhotoBatches' => {
        'batches': <Json>[
          {
            'id': 'card-6969',
            'receivedAt': '2026-11-23T09:23:24Z',
            'status': 'CARD',
            'cardTail': '6969',
            'targetPhotoId': '209',
            'targetCardId': '6969',
            'photos': <Json>[
              {
                'id': '209',
                'receivedAt': '2026-11-23T09:23:24Z',
                'ending': true,
                'thumbnailUrl': 'https://example.invalid/photo.jpg',
              },
            ],
          },
        ],
      },
      _ => throw StateError(method),
    };
  }
}
