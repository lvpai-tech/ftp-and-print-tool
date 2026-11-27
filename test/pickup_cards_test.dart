import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/printing/pickup_cards/page.dart';
import 'package:lvpai_ftp_client/printing/print_bridge.dart';
import 'package:lvpai_ftp_client/ui/workstation_home.dart';
import 'package:lvpai_ftp_client/workstation_account.dart';
import 'package:lvpai_ftp_client/workstation_session.dart';
import 'package:material_ui/material_ui.dart';

class _PickupAccount extends WorkstationAccount {
  _PickupAccount() : super(Uri.parse('https://test.invalid'));

  String? pending;
  final requests = <Map<String, Object>>[];
  bool ready = false;

  static const batch = {
    'batchNo': 'QR-TEST-001',
    'quantity': 2,
    'export': {
      'format': 'PDF',
      'status': 'READY',
      'prepared': 2,
      'completedParts': 1,
      'partCount': 1,
    },
  };

  @override
  Future<String?> pendingPickupExport(String userId, String scenicId) async =>
      pending;

  @override
  Future<void> rememberPickupExport(
    String userId,
    String scenicId,
    String? request,
  ) async => pending = request;

  @override
  Future<Map<String, dynamic>> requestPickupCards(
    String scenicId,
    String suffix, {
    Map<String, Object>? body,
    bool post = false,
  }) async {
    expect(scenicId, '42');
    if (post) {
      requests.add(body!);
      if (requests.length == 1) throw StateError('提交结果待确认');
      ready = true;
      return batch;
    }
    if (suffix.isEmpty) {
      return {
        'exports': [if (ready) batch],
      };
    }
    expect(suffix, '/QR-TEST-001/PDF');
    return {
      ...batch,
      'files': [
        {'partNo': 1, 'fileName': 'QR-TEST-001.pdf', 'sizeBytes': 100},
      ],
    };
  }
}

class _PickupBridge extends PrintBridge {
  _PickupBridge() {
    connected = true;
  }

  @override
  Future<dynamic> call(String method, [List<dynamic> args = const []]) async {
    expect(method, 'listPrinters');
    return ['卡纸打印机 A', '卡纸打印机 B'];
  }
}

void main() {
  for (final width in [375.0, 1280.0]) {
    testWidgets('更多操作在 ${width.toInt()} px 打开取片码入口', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      WorkModule? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkstationHome(
              uploadStatus: '运行中',
              printStatus: '已关闭',
              uploadActive: true,
              printActive: false,
              showPickupCards: true,
              onOpen: (module) => selected = module,
            ),
          ),
        ),
      );
      await tester.tap(find.text('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打印取片码'));
      await tester.pumpAndSettle();
      expect(selected, WorkModule.pickupCards);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('取片卡保留原请求号，PDF 就绪后可选专用打印队列', (tester) async {
    final account = _PickupAccount();
    final bridge = _PickupBridge();
    const scenic = (id: '42', name: '测试景区', code: 'TEST');
    final session = WorkstationSession(bridge, account: account)
      ..identity = const WorkstationIdentity('7', '测试人员', 'operator', [scenic])
      ..scenic = scenic;
    addTearDown(session.dispose);
    addTearDown(bridge.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PickupCardsPage(session: session, visible: true)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成 PDF'));
    await tester.pumpAndSettle();
    expect(account.pending, isNotNull);
    expect(find.text('提交结果待确认'), findsOneWidget);
    await tester.tap(find.text('核对并重试生成 PDF'));
    await tester.pumpAndSettle();
    expect(account.pending, isNull);
    expect(account.requests.last, account.requests.first);

    if (Platform.isWindows || Platform.isMacOS) {
      await tester.ensureVisible(find.text('下载或打印'));
      await tester.tap(find.text('下载或打印'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('选择打印机'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '送打此卷'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('请选择系统打印队列'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('卡纸打印机 B'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '送打此卷'))
            .onPressed,
        isNotNull,
      );
      expect(find.text('卡纸打印机 B'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
