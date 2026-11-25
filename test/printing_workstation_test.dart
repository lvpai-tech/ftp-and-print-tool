import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lvpai_ftp_client/printing/app.dart';
import 'package:lvpai_ftp_client/printing/print_bridge.dart';
import 'package:lvpai_ftp_client/printing/print_enrollment.dart';
import 'package:lvpai_ftp_client/ui/workstation_form_dialog.dart';

import 'support/mock_workstation_credentials.dart';

class ControlledBridge extends PrintBridge {
  final calls = <String>[];
  final arguments = <String, List<dynamic>>{};
  ControlledBridge({bool configured = true}) {
    connected = true;
    snapshot = {
      'configured': configured,
      'config': {
        'scenicName': '隔离测试景区',
        'activeScenicProfileId': 'default',
        'scenicProfiles': [
          {
            'id': 'default',
            'token': '[已配置]',
            'scenicName': '隔离测试景区',
            'scenicIds': ['1'],
          },
        ],
        'statusCommand': ['controlled'],
        'printers': {},
      },
      'state': {
        'jobPage': {
          'total': 1,
          'pageNum': 1,
          'list': [
            {
              'id': '9007199254740993',
              'cardTail': '4987',
              'status': 'FAILED',
              'contentSummary': '开头片 1 · 原片 2 · 创意 6',
              'completedSheets': 3,
              'totalSheets': 9,
            },
          ],
        },
      },
      'logs': [],
    };
  }
  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    calls.add(method);
    arguments[method] = args;
    if (method == 'listPrinters') return ['真实系统适配的测试替身'];
    if (method == 'listBatchStations') {
      return <Json>[
        {'id': '317', 'code': 'A08', 'name': '隔离测试机位'},
      ];
    }
    if (method == 'listPhotoBatches') return {'batches': <Json>[]};
    if (method == 'revealToken' || method == 'revealScenicProfileToken') {
      return {'token': 'isolation-test-token'};
    }
    if (method == 'previewJob') {
      return {
        'id': '${args.first}',
        'items': [
          {
            'kind': 'COVER',
            'label': '开头片',
            'copies': 1,
            'fileUrl': '/print-agents/jobs/${args.first}/preview-files/COVER/1',
          },
          {
            'kind': 'ORIGINAL',
            'label': '原片',
            'copies': 1,
            'fileUrl': '/print-agents/jobs/${args.first}/preview-files/PHOTO/2',
          },
          {
            'kind': 'CREATIVE',
            'label': '创意',
            'copies': 1,
            'fileUrl': '/print-agents/jobs/${args.first}/preview-files/WORK/3',
          },
        ],
      };
    }
    if (method == 'previewJobImage') {
      return {
        'contentType': 'image/gif',
        'dataUrl': 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
      };
    }
    if (method == 'recoveryDetails') {
      return {
        'sheets': [
          for (final (index, state) in ['DONE', 'UNCERTAIN', 'READY'].indexed)
            {
              'index': index,
              'state': state,
              'kind': 'ORIGINAL',
              'label': '原片',
              'fileUrl':
                  '/print-agents/jobs/${args.first}/preview-files/PHOTO/$index',
            },
        ],
      };
    }
    return snapshot;
  }
}

class GeneratingQueueBridge extends ControlledBridge {
  bool pending = true;
  bool hasDetails = true;
  static const thumbnailBase =
      '/print-agents/generating/9007199254740994/original-thumbnails';

  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    if (method == 'queryJobs') {
      final filter = (args.first as Json)['printStatus'];
      final current = snapshot['state'] as Json;
      final printPage = current['printPage'] ?? current['jobPage'];
      snapshot['state'] = {
        ...current,
        'jobQuery': {'printStatus': filter},
        'printPage': printPage,
        'jobPage': filter == 'GENERATING'
            ? {
                'list': [
                  if (pending)
                    {
                      'receiptId': '9007199254740994',
                      'cardTail': '3893',
                      'submittedAt': '2026-11-21T01:20:00Z',
                      if (hasDetails) ...{
                        'originalPhotoCount': 4,
                        'originalThumbnailUrls': [
                          '$thumbnailBase/101',
                          '$thumbnailBase/102',
                          '$thumbnailBase/103',
                        ],
                        'estimatedTotalSheets': 11,
                        'estimatedContentSummary': '开头片×1、原片×4、创意×6',
                      },
                    },
                ],
                'total': pending ? 1 : 0,
                'pageNum': 1,
              }
            : printPage,
      };
    }
    return super.call(method, args);
  }
}

class LocationSwitchBridge extends ControlledBridge {
  bool rejectSwitch = false;

  LocationSwitchBridge() {
    snapshot['config']['scenicProfiles'].add({
      'id': 'other',
      'scenicName': '另一景区',
      'scenicCode': 'NEXT',
    });
    snapshot['state'] = {...state, 'autoPrint': true};
  }

  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) {
    if (method == 'autoPrint') {
      snapshot['state']['autoPrint'] = args.single;
      notifyListeners();
    }
    if (method == 'activateScenicProfile') {
      if (rejectSwitch) return Future.error(StateError('打印权限已撤销'));
      snapshot['config']['activeScenicProfileId'] = args.single['id'];
      snapshot['config']['scenicName'] = '另一景区';
      notifyListeners();
    }
    return super.call(method, args);
  }
}

Future<void> openCurrentPrintLocation(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('print-location-default')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('打印点使用同一授权的点位名称，并在自动打印时只允许进入当前点', (tester) async {
    tester.view.physicalSize = const Size(375, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    setMockWorkstationCredentials({
      '${PrintEnrollment.prefix}default': jsonEncode({
        'id': 'default',
        'location': '一楼取片区',
        'createdAt': '2026-11-24T00:00:00Z',
      }),
    });
    final bridge = LocationSwitchBridge();
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.4),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Workstation(bridge: bridge, embedded: true, onBack: () {}),
      ),
    );
    await tester.pumpAndSettle();
    final other = find.byKey(const ValueKey('print-location-other'));
    expect(find.text('打印点'), findsOneWidget);
    expect(find.text('本机已开通 2 个打印点'), findsOneWidget);
    expect(find.text('一楼取片区'), findsOneWidget);
    expect(find.text('隔离测试景区'), findsOneWidget);
    expect(find.text('另一景区 · NEXT'), findsOneWidget);
    expect(find.text('请在当前打印点关闭自动打印后再切换。'), findsOneWidget);
    expect(find.text('待打印'), findsNothing);
    await tester.tap(other);
    await tester.pumpAndSettle();
    expect(bridge.calls, isNot(contains('activateScenicProfile')));
    await openCurrentPrintLocation(tester);
    expect(find.text('自动打印 开启'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回打印点列表'));
    await tester.pumpAndSettle();
    bridge.rejectSwitch = true;
    await tester.tap(other);
    await tester.pumpAndSettle();
    expect(find.text('打印权限已撤销'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('待打印'), findsNothing);
    bridge.rejectSwitch = false;
    await tester.tap(other);
    await tester.pumpAndSettle();
    expect(bridge.arguments['activateScenicProfile'], [
      {'id': 'other'},
    ]);
    expect(find.text('待打印'), findsOneWidget);
    expect(find.text('另一景区'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('print-open-locations')));
    await tester.pumpAndSettle();
    final current = find.byKey(const ValueKey('print-location-other'));
    expect(
      find.descendant(of: current, matching: find.text('当前使用')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('首次进入打印点列表可申请或查记录', (tester) async {
    setMockWorkstationCredentials({});
    final bridge = ControlledBridge(configured: false)
      ..snapshot['config'] = <String, dynamic>{};
    await tester.pumpWidget(
      MaterialApp(home: Workstation(bridge: bridge, embedded: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有打印点'), findsOneWidget);
    expect(find.text('申请打印权限'), findsOneWidget);
    await tester.tap(find.text('申请记录（0）'));
    await tester.pumpAndSettle();
    expect(find.text('打印申请记录'), findsOneWidget);
    expect(find.text('暂无打印申请记录'), findsOneWidget);
    expect(find.text('待打印'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '关闭'));
    await tester.pumpAndSettle();
    expect(find.text('暂无打印申请记录'), findsNothing);
    expect(find.text('还没有打印点'), findsOneWidget);
  });

  testWidgets('短窗口可滚动查看打印申请记录，关闭按钮位置固定', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 300);
    addTearDown(tester.view.reset);
    setMockWorkstationCredentials({
      for (var index = 1; index <= 6; index++)
        '${PrintEnrollment.prefix}print-$index': jsonEncode({
          'id': 'print-$index',
          'scenicName': '测试景区',
          'location': '点位 $index',
          'status': 'PENDING',
          'createdAt': DateTime.utc(2026, 11, index).toIso8601String(),
        }),
    });
    addTearDown(() => setMockWorkstationCredentials({}));
    final bridge = ControlledBridge();
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Workstation(bridge: bridge, embedded: true)),
    );
    await tester.pumpAndSettle();

    final open = find.text('申请记录（6）');
    final printPoint = find.byKey(const ValueKey('print-location-default'));
    final printPointBounds = tester.getRect(printPoint);
    final newest = find.text('测试景区 · 点位 6');
    final oldest = find.text('测试景区 · 点位 1');
    expect(newest, findsNothing);
    await tester.tap(open);
    await tester.pumpAndSettle();
    final dialog = find.byType(WorkstationFormDialog);
    final close = find.widgetWithText(FilledButton, '关闭');
    final closeBounds = tester.getRect(close);
    expect(newest.hitTestable(), findsOneWidget);
    expect(oldest.hitTestable(), findsNothing);
    await tester.scrollUntilVisible(
      oldest,
      100,
      scrollable: find
          .descendant(of: dialog, matching: find.byType(Scrollable))
          .first,
    );
    expect(oldest.hitTestable(), findsOneWidget);
    expect(tester.getRect(close), closeBounds);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(open.hitTestable(), findsOneWidget);
    expect(tester.getRect(printPoint), printPointBounds);
    expect(tester.takeException(), isNull);
  });

  for (final (width, table) in [
    (375.0, false),
    (760.0, false),
    (768.0, true),
    (1280.0, true),
  ]) {
    testWidgets('生成中在宽度 $width 显示只读取片单并支持刷新', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = GeneratingQueueBridge();
      await tester.pumpWidget(
        MaterialApp(home: Workstation(bridge: bridge, embedded: true)),
      );
      await openCurrentPrintLocation(tester);
      bridge.calls.clear();
      final queueColumns = {
        '取片卡尾号 / 工单': '取片卡尾号 / 小票',
        '照片预览': '照片预览',
        '打印内容': '打印内容',
        '状态': '状态',
        '创建时间': '提交时间',
      };
      final columnStarts = table
          ? queueColumns.keys
                .map((label) => tester.getTopLeft(find.text(label)).dx)
                .toList()
          : const <double>[];

      await tester.tap(find.text('生成中'));
      await tester.pumpAndSettle();
      expect(
        bridge.arguments['queryJobs']?.first,
        containsPair('printStatus', 'GENERATING'),
      );
      expect(find.text('3893'), findsOneWidget);
      expect(find.text('小票 #9007199254740994'), findsOneWidget);
      expect(find.text('2026-11-21 09:20'), findsOneWidget);
      expect(find.text('AI 创意生成中'), findsOneWidget);
      if (table) {
        final generatingStarts = queueColumns.values.map(
          (label) => tester.getTopLeft(find.text(label)).dx,
        );
        expect(generatingStarts, orderedEquals(columnStarts));
      } else {
        expect(find.text('照片预览'), findsNothing);
      }
      expect(find.text('预计 11 张'), findsOneWidget);
      expect(find.text('开头片×1、原片×4、创意×6'), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(3));
      expect(find.text('+1'), findsOneWidget);
      expect(bridge.arguments['previewJobImage'], [
        '${GeneratingQueueBridge.thumbnailBase}/103',
      ]);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byTooltip('查看照片'), findsNothing);
      expect(find.text('操作'), findsNothing);
      expect(find.text('打印本单'), findsNothing);
      expect(bridge.calls, ['queryJobs', ...List.filled(3, 'previewJobImage')]);

      if (width == 1280) {
        bridge.hasDetails = false;
        await tester.tap(find.byTooltip('刷新生成中的任务'));
        await tester.pumpAndSettle();
        expect(find.text('当前服务未提供打印明细'), findsOneWidget);
        expect(find.text('当前服务未提供原片预览'), findsOneWidget);
      }

      bridge.pending = false;
      await tester.tap(find.byTooltip('刷新生成中的任务'));
      await tester.pumpAndSettle();
      expect(find.text('暂无正在生成的任务'), findsOneWidget);

      await tester.tap(find.text('待打印'));
      await tester.pumpAndSettle();
      expect(
        bridge.arguments['queryJobs']?.first,
        containsPair('printStatus', 'UNPRINTED'),
      );
      expect(find.text('#9007199254740993'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [820.0, 1280.0, 1600.0]) {
    testWidgets('工单在 $width 宽度可操作且ID不丢精度', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = ControlledBridge();
      await tester.pumpWidget(MaterialApp(home: Workstation(bridge: bridge)));
      await tester.pumpAndSettle();
      expect(find.text('#9007199254740993'), findsOneWidget);
      expect(find.text('4987'), findsOneWidget);
      expect(find.text('共 9 张'), findsOneWidget);
      expect(find.text('已完成 3 / 9 张'), findsOneWidget);
      expect(find.text('继续剩余'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 单'), findsOneWidget);
      expect(find.text('打印选中'), findsNothing);
      await tester.tap(find.text('继续剩余'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '续打'));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('continueJobs'));
      expect(bridge.arguments['continueJobs'], [
        ['9007199254740993'],
      ]);
    });
  }
  testWidgets('首次启动显示打印申请和申请记录', (tester) async {
    final bridge = ControlledBridge(configured: false);
    await tester.pumpWidget(MaterialApp(home: Workstation(bridge: bridge)));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '申请打印权限'), findsOneWidget);
    expect(find.text('#9007199254740993'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('申请记录（0）'));
    await tester.pumpAndSettle();
    expect(find.text('暂无打印申请记录'), findsOneWidget);
  });

  testWidgets('打印申请景区使用浮层，点外收起且不移动点位输入框', (tester) async {
    setMockWorkstationCredentials({});
    addTearDown(() => setMockWorkstationCredentials({}));
    final bridge = ControlledBridge(configured: false)
      ..snapshot['config'] = <String, dynamic>{};
    addTearDown(bridge.dispose);
    Map<String, dynamic>? submitted;
    final client = MockClient((request) async {
      final Object data;
      if (request.url.path == '/api/miniprogram/scenics') {
        data = [
          {'id': '1', 'name': '景区甲'},
          {'id': '2', 'name': '景区乙'},
          {'id': '3', 'name': '景区丙'},
        ];
      } else if (request.method == 'POST') {
        expect(
          request.url.path,
          '/api/operation/print-workstation-enrollment/applications',
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        submitted = body;
        data = {
          'id': body['requestId'],
          'scenicId': body['scenicId'],
          'status': 'PENDING',
        };
      } else {
        expect(request.method, 'GET');
        expect(
          request.url.path,
          '/api/operation/print-workstation-enrollment/applications/${submitted!['requestId']}',
        );
        data = {
          'id': submitted!['requestId'],
          'scenicId': submitted!['scenicId'],
          'status': 'REJECTED',
          'reviewReason': '请核对打印点名称',
        };
      }
      return http.Response(
        jsonEncode({'code': 200, 'data': data}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(home: Workstation(bridge: bridge, embedded: true)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('申请打印权限'));
      // The progress indicator behind the dialog animates until it closes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      final dialog = find.byType(WorkstationFormDialog);
      final picker = find.widgetWithText(OutlinedButton, '选择景区');
      final name = find.widgetWithText(TextField, '申请人姓名');
      final location = find.widgetWithText(TextField, '具体地点');
      final submit = find.widgetWithText(FilledButton, '提交申请');
      for (final label in ['0/20', '0/60']) {
        final counter = find.text(label);
        final container = InputDecorator.containerOf(tester.element(counter))!;
        final bounds = container.localToGlobal(Offset.zero) & container.size;
        expect(bounds.contains(tester.getCenter(counter)), isTrue);
      }
      await tester.tap(submit);
      await tester.pump();
      expect(find.text('请选择景区').hitTestable(), findsWidgets);
      expect(find.text('请填写申请人姓名'), findsOneWidget);
      expect(find.text('请填写具体地点'), findsOneWidget);
      expect(submitted, isNull);

      final fieldBefore = tester.getRect(location);
      final buttonBefore = tester.getRect(submit);
      final close = find.byTooltip('关闭弹窗');
      expect(
        tester.getRect(close).right,
        greaterThan(tester.getRect(picker).center.dx),
      );
      expect(
        tester.getRect(close).bottom,
        lessThan(tester.getRect(picker).top),
      );
      await tester.tap(picker);
      await tester.pump();
      final lastOption = find.text('景区丙');
      final menu = tester.getRect(
        find.ancestor(of: lastOption, matching: find.byType(ListView)).first,
      );
      final trigger = tester.getRect(picker);
      expect(menu.top, greaterThan(trigger.bottom));
      expect(menu.left, trigger.left);
      expect(menu.width, trigger.width);
      expect(tester.getRect(location), fieldBefore);
      expect(tester.getRect(submit), buttonBefore);
      await tester.tap(find.text('申请打印权限').last);
      await tester.pump();
      expect(lastOption, findsNothing);
      expect(location.hitTestable(), findsOneWidget);
      await tester.enterText(name, '  李四  ');
      await tester.tap(picker);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('景区乙'));
      await tester.pump();
      final longestLocation = '前台' * 30;
      final overlongLocation = '东$longestLocation';
      await tester.enterText(location, overlongLocation);
      await tester.pump();
      expect(find.text('61/60'), findsOneWidget);
      await tester.tap(submit);
      await tester.pump();
      expect(find.text('地点最多 60 个字符'), findsOneWidget);
      expect(find.text(overlongLocation), findsOneWidget);
      expect(submitted, isNull);
      await tester.enterText(location, '\u{20000}' * 49);
      await tester.tap(submit);
      await tester.pump();
      expect(find.text('姓名和地点合计过长，请缩短后提交'), findsOneWidget);
      expect(submitted, isNull);
      await tester.enterText(location, longestLocation);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(submit, findsNothing);
      expect(dialog, findsOneWidget);
      expect(find.text('打印申请记录'), findsOneWidget);
      expect(submitted, containsPair('scenicId', '2'));
      expect(submitted, containsPair('location', '李四 · $longestLocation'));
      expect(find.text('景区乙 · 李四 · $longestLocation'), findsOneWidget);
      expect(find.text('待审核'), findsOneWidget);
      await tester.tap(find.text('刷新申请状态'));
      await tester.pumpAndSettle();
      expect(find.text('已驳回'), findsOneWidget);
      expect(find.text('请核对打印点名称'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '关闭'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.text('申请记录（1）'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });

  testWidgets('查看批次在打印页标签栏内切换并读取机位', (tester) async {
    final bridge = ControlledBridge();
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Workstation(bridge: bridge, embedded: true)),
    );
    await openCurrentPrintLocation(tester);

    final tab = find.widgetWithText(TextButton, '查看批次');
    final printed = find.widgetWithText(TextButton, '已打印');
    expect(tester.getRect(printed).center.dy, tester.getRect(tab).center.dy);
    expect(tester.getRect(tab).left, greaterThan(tester.getRect(printed).left));
    expect(bridge.calls, isNot(contains('listBatchStations')));
    await tester.tap(tab);
    await tester.pumpAndSettle();
    expect(find.text('打印记录'), findsOneWidget);
    expect(find.byTooltip('刷新打印任务'), findsNothing);
    expect(find.text('待打印'), findsOneWidget);
    expect(find.textContaining('A08'), findsOneWidget);
    expect(find.text('当天暂无收图'), findsOneWidget);
    expect(bridge.arguments['listBatchStations'], isEmpty);
    expect(
      bridge.arguments['listPhotoBatches']?.single,
      containsPair('stationId', '317'),
    );
    await tester.tap(find.widgetWithText(TextButton, '待打印'));
    await tester.pumpAndSettle();
    expect(find.text('当天暂无收图'), findsNothing);
    expect(find.byTooltip('刷新打印任务'), findsOneWidget);
  });

  testWidgets('自动打印必须经过实际出纸确认', (tester) async {
    final bridge = ControlledBridge();
    await tester.pumpWidget(MaterialApp(home: Workstation(bridge: bridge)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('开启自动打印'), findsNWidgets(2));
    expect(bridge.calls, isNot(contains('autoPrint')));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(bridge.calls, isNot(contains('autoPrint')));
  });

  testWidgets('勾选后原位显示批量操作，缩略图可直接打开预览', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = ControlledBridge();
    final job = bridge.snapshot['state']['jobPage']['list'][0] as Json;
    job['status'] = 'QUEUED';
    job['completedSheets'] = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Workstation(bridge: bridge, embedded: true, onBack: () {}),
      ),
    );
    await openCurrentPrintLocation(tester);
    final tail = find.text('4987');
    final top = tester.getTopLeft(tail).dy;
    expect(find.text('自动打印 关闭'), findsOneWidget);
    expect(find.text('打印本单'), findsOneWidget);
    expect(find.text('打印选中'), findsNothing);
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(tail).dy, top);
    expect(find.text('打印选中'), findsOneWidget);
    expect(find.text('继续剩余'), findsNothing);
    await tester.tap(find.text('取消选择'));
    await tester.pumpAndSettle();
    expect(find.text('待打印'), findsWidgets);
    expect(find.text('生成中'), findsOneWidget);
    expect(find.text('已打印'), findsOneWidget);
    expect(find.text('全部任务'), findsNothing);
    expect(find.text('需处理'), findsNothing);
    await tester.tap(find.byTooltip('查看照片'));
    await tester.pumpAndSettle();
    expect(find.textContaining('取片码'), findsOneWidget);
    expect(find.textContaining('4987'), findsWidgets);
    expect(find.textContaining('打印预览'), findsOneWidget);
    expect(bridge.arguments['previewJob'], ['9007199254740993']);
    expect(bridge.calls, isNot(contains('printJobs')));
  });

  testWidgets('工单刷新后留在待打印，缺纸时可从同一行续打', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = ControlledBridge();
    addTearDown(bridge.dispose);
    final job = bridge.jobs.single;
    final state = bridge.state;
    bridge.snapshot['state'] = state;
    void showQueue(List<Json> rows) {
      state['jobPage'] = {'list': rows, 'total': rows.length, 'pageNum': 1};
      bridge.notifyListeners();
    }

    showQueue([
      {...job, 'status': 'QUEUED', 'completedSheets': 0},
    ]);
    await tester.pumpWidget(
      MaterialApp(home: Workstation(bridge: bridge, embedded: true)),
    );
    await openCurrentPrintLocation(tester);
    await tester.tap(find.text('打印本单'));
    await tester.pumpAndSettle();
    expect(bridge.arguments['printJobs'], [
      [job['id']],
    ]);

    state['printBusy'] = true;
    state['activePrintJob'] = {...job, 'status': 'PRINTING'};
    showQueue([]);
    await tester.pump();
    expect(find.text('#${job['id']}'), findsOneWidget);
    expect(find.text('打印中'), findsOneWidget);
    expect(find.text('已完成 3 / 9 张'), findsOneWidget);
    expect(find.text('打印本单'), findsNothing);

    state['printBusy'] = false;
    state.remove('activePrintJob');
    final failed = {...job, 'errorReason': '作业缺纸'};
    state['localPrintIssues'] = [failed];
    state['printIssues'] = {
      'list': [failed],
      'total': 1,
      'pageNum': 1,
      'pageSize': 10,
    };
    showQueue([]);
    await tester.pumpAndSettle();
    expect(find.text('#${job['id']}'), findsOneWidget);
    expect(find.text('缺纸中断'), findsOneWidget);
    expect(find.text('续打'), findsOneWidget);
    await tester.tap(find.text('续打'));
    await tester.pumpAndSettle();
    expect(bridge.calls, isNot(contains('continueJobs')));
    await tester.tap(find.widgetWithText(FilledButton, '续打'));
    await tester.pumpAndSettle();
    expect(bridge.arguments['continueJobs'], [
      [job['id']],
    ]);

    state.remove('printIssues');
    state['localPrintIssues'] = [
      {...job, 'status': 'RESULT_UNCONFIRMED'},
    ];
    showQueue([]);
    await tester.pumpAndSettle();
    expect(find.text('#${job['id']}'), findsOneWidget);
    expect(find.text('待核对'), findsOneWidget);
    expect(find.text('续打'), findsNothing);

    state.remove('localPrintIssues');
    showQueue([]);
    await tester.pumpAndSettle();
    expect(find.text('#${job['id']}'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('待核对按单张选择补印并阻止整单直接送打', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = ControlledBridge();
    addTearDown(bridge.dispose);
    final job = bridge.snapshot['state']['jobPage']['list'][0] as Json;
    job['status'] = 'CLAIMED';
    bridge.snapshot['state'] = {
      ...bridge.state,
      'recoveryJobs': [
        {
          ...job,
          'status': 'RECOVERY_REQUIRED',
          'totalSheets': 3,
          'completedSheets': 1,
        },
      ],
    };
    await tester.pumpWidget(
      MaterialApp(home: Workstation(bridge: bridge, embedded: true)),
    );
    await openCurrentPrintLocation(tester);
    expect(find.text('打印本单'), findsNothing);
    await tester.tap(find.text('核对打印'));
    await tester.pumpAndSettle();
    expect(find.text('已确认完成'), findsOneWidget);
    expect(find.text('尚未送打'), findsOneWidget);
    final initial = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '补印 1 张'),
    );
    expect(initial.onPressed, isNull);
    await tester.tap(find.text('第 2 张 · 原片'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('已核对纸面和系统打印队列'));
    await tester.tap(find.text('已核对纸面和系统打印队列'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '补印 2 张'));
    await tester.pumpAndSettle();
    expect(bridge.arguments['recoverPrintJob'], [
      job['id'],
      [1, 2],
    ]);
    expect(bridge.calls, isNot(contains('printJobs')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('异常菜单核对纸面后才确认已打印', (tester) async {
    tester.view.physicalSize = const Size(375, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = ControlledBridge();
    final job = bridge.snapshot['state']['jobPage']['list'][0] as Json;
    job['completedSheets'] = 9;
    job['errorReason'] = '缺纸';
    await tester.pumpWidget(
      MaterialApp(
        home: Workstation(bridge: bridge, embedded: true, onBack: () {}),
      ),
    );
    await openCurrentPrintLocation(tester);
    expect(find.text('缺纸'), findsOneWidget);
    await tester.tap(find.byTooltip('处理异常'));
    await tester.pumpAndSettle();
    expect(find.text('继续剩余'), findsNothing);
    await tester.tap(find.text('确认已打印'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请先核对纸面已齐'), findsOneWidget);
    expect(bridge.calls, isNot(contains('confirmPrinted')));
    await tester.tap(find.widgetWithText(FilledButton, '确认已打印'));
    await tester.pumpAndSettle();
    expect(bridge.arguments['confirmPrinted'], [
      ['9007199254740993'],
    ]);
    expect(bridge.calls, isNot(contains('printJobs')));
    expect(tester.takeException(), isNull);
  });
}
