import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lvpai_ftp_client/printing/app.dart';
import 'package:lvpai_ftp_client/printing/print_bridge.dart';

class ControlledBridge extends PrintBridge {
  final calls = <String>[];
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
            'fileUrl':
                '/print-agents/jobs/${args.first}/preview-files/COVER/1',
          },
          {
            'kind': 'ORIGINAL',
            'label': '原片',
            'copies': 1,
            'fileUrl':
                '/print-agents/jobs/${args.first}/preview-files/PHOTO/2',
          },
          {
            'kind': 'CREATIVE',
            'label': '创意',
            'copies': 1,
            'fileUrl':
                '/print-agents/jobs/${args.first}/preview-files/WORK/3',
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

void main() {
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
      expect(find.text('已完成 3 / 9 张'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 单'), findsOneWidget);
      expect(find.text('打印本单'), findsWidgets);
      await tester.tap(find.text('继续剩余'));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('continueJobs'));
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
}
