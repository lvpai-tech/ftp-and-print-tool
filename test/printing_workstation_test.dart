import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lvpai_ftp_client/printing/app.dart';
import 'package:lvpai_ftp_client/printing/print_bridge.dart';

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
        'dataUrl':
            'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
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

void main() {
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
      await tester.pumpAndSettle();
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
      expect(bridge.calls, contains('continueJobs'));
      expect(bridge.arguments['continueJobs'], [
        ['9007199254740993'],
      ]);
    });
  }
  testWidgets('首次连接不展示假数据且密钥遮挡', (tester) async {
    final bridge = ControlledBridge(configured: false);
    await tester.pumpWidget(MaterialApp(home: Workstation(bridge: bridge)));
    await tester.pumpAndSettle();
    expect(find.text('验证并连接景区'), findsOneWidget);
    expect(find.text('#9007199254740993'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, true);
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
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
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
