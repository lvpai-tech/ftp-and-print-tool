import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lvpai_ftp_client/auto_upload/cos_upload.dart';
import 'package:lvpai_ftp_client/auto_upload/workstation_enrollment.dart';
import 'package:lvpai_ftp_client/profile_store.dart';
import 'package:lvpai_ftp_client/ui/dropdown_field.dart';
import 'package:lvpai_ftp_client/ui/workstation_enrollment_panel.dart';
import 'package:lvpai_ftp_client/ui/workstation_form_dialog.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const store = ProfileStore();
  final gateway = Uri.parse('https://upload.example');

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('景区下拉失败可重试，选定后用正式名称提交且无编码', (tester) async {
    var attempts = 0;
    var manual = 0;
    var refreshes = 0;
    Map<String, dynamic>? submitted;
    final client = MockClient((request) async {
      if (request.url.path == '/api/miniprogram/scenics') {
        expect(request.method, 'GET');
        expect(request.url, gateway.resolve('/api/miniprogram/scenics'));
        expect(request.followRedirects, isFalse);
        expect(request.headers, isEmpty);
        if (++attempts == 1) return http.Response('', 503);
        return result([
          {'id': '1', 'name': '景区甲'},
          {'id': '2', 'name': '景区乙'},
        ]);
      }
      if (request.method == 'GET') {
        expect(request.url.pathSegments.last, submitted?['requestId']);
        refreshes++;
        return result({
          'id': submitted?['requestId'],
          'status': 'REJECTED',
          'reason': '请补充入口位置',
        });
      }
      expect(
        request.url.path,
        '/api/operation/workstation-enrollment/applications',
      );
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      submitted = body;
      return result({'id': body['requestId'], 'status': 'PENDING'});
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkstationEnrollmentPanel(
              api: gateway,
              store: store,
              onBound: () async {},
              onManual: () async => manual++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('手动绑定机位'));
      expect(manual, 1);
      await tester.tap(find.text('申请机位'));
      await tester.pumpAndSettle();
      final submit = find.widgetWithText(FilledButton, '提交申请');
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      expect(find.text('景区列表加载失败'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '  东门观景台  ');
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      final locationField = find.byType(TextField);
      final picker = find.descendant(
        of: find.byType(DropdownField<EnrollmentScenic>),
        matching: find.byType(OutlinedButton),
      );
      final option = find.widgetWithText(ListTile, '景区乙');
      final locationBefore = tester.getRect(locationField);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      final options = tester.getRect(find.byType(ListView));
      final anchor = tester.getRect(picker);
      expect(options.top, greaterThan(anchor.bottom));
      expect(options.left, anchor.left);
      expect(options.width, anchor.width);
      expect(tester.getRect(locationField), locationBefore);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(option, findsNothing);
      expect(submit, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, '景区乙'), findsOneWidget);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(option).selected, isTrue);
      await tester.tap(find.text('申请机位').last);
      await tester.pumpAndSettle();
      expect(option, findsNothing);
      expect(locationField.hitTestable(), findsOneWidget);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(submitted, {
        'requestId': isA<String>(),
        'scenicName': '景区乙',
        'location': '东门观景台',
      });
      expect(find.text('待审核'), findsOneWidget);
      expect(find.text('申请记录（1）'), findsOneWidget);
      await tester.pump(const Duration(minutes: 1));
      expect(refreshes, 0);
      expect(find.text('待审核'), findsOneWidget);
      await tester.tap(find.text('刷新申请状态'));
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      expect(find.text('已驳回'), findsOneWidget);
      expect(find.text('请补充入口位置'), findsOneWidget);
      await tester.pump(const Duration(minutes: 1));
      expect(refreshes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });

  testWidgets('窄窗口可滚动选择更多景区', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 430);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final client = MockClient(
      (_) async => result([
        for (var index = 1; index <= 10; index++)
          {'id': '$index', 'name': '景区 $index'},
      ]),
    );
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: WorkstationEnrollmentPanel(
              api: gateway,
              store: store,
              onBound: () async {},
              onManual: () async {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('申请机位'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('请选择景区'));
      await tester.pumpAndSettle();
      final lastOption = find.text('景区 10');
      expect(lastOption.hitTestable(), findsNothing);
      await tester.scrollUntilVisible(
        lastOption,
        80,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(lastOption.hitTestable(), findsOneWidget);
      await tester.tap(lastOption);
      await tester.pumpAndSettle();
      expect(find.byType(ListView), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '景区 10'), findsOneWidget);
      expect(find.byType(TextField).hitTestable(), findsOneWidget);

      tester.view.physicalSize = const Size(375, 225);
      await tester.pumpAndSettle();
      final close = find.byTooltip('关闭弹窗');
      final submit = find.widgetWithText(FilledButton, '提交申请');
      final closeBefore = tester.getRect(close);
      final submitBefore = tester.getRect(submit);
      final field = find.byType(TextField);
      final fieldBefore = tester.getRect(field);
      final bodyScroll = find.descendant(
        of: find.byType(WorkstationFormDialog),
        matching: find.byType(SingleChildScrollView),
      );
      await tester.drag(bodyScroll, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(tester.getRect(field).top, lessThan(fieldBefore.top));
      expect(field.hitTestable(), findsOneWidget);
      expect(tester.getRect(close), closeBefore);
      expect(tester.getRect(submit), submitBefore);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(WorkstationFormDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });

  test('旧草稿恢复提交时保留原有编码和申请资料', () async {
    const draft = {
      'requestId': 'legacy-application',
      'scenicName': '原景区',
      'location': '原点位',
      'stationCode': 'A01',
    };
    const secret = 'original-secret';
    final id = draft['requestId']!;
    await store.saveEnrollment(gateway, id, {'draft': draft, 'secret': secret});
    final client = MockClient((request) async {
      expect(request.headers['x-workstation-enrollment-token'], secret);
      expect(jsonDecode(request.body), draft);
      return result({'id': id, 'status': 'PENDING'});
    });
    addTearDown(client.close);
    final enrollment = WorkstationEnrollment(gateway, store, client);
    expect((await enrollment.refresh(id))?.status, 'PENDING');
  });

  test('提交响应丢失后，重启用同一编号、凭据和资料重试', () async {
    Map<String, dynamic>? original;
    String? secret;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final token = request.headers['x-workstation-enrollment-token'];
      expect(token, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(request.followRedirects, isFalse);
      if (original == null) {
        original = body;
        secret = token;
        throw http.ClientException('connection dropped');
      }
      expect(body, original);
      expect(token, secret);
      return result({'id': body['requestId'], 'status': 'PENDING'});
    });
    addTearDown(client.close);

    final first = WorkstationEnrollment(gateway, store, client);
    final id = await first.begin('测试景区', '观景台');
    await expectLater(first.refresh(id), throwsA(isA<http.ClientException>()));
    final restarted = WorkstationEnrollment(gateway, store, client);
    expect((await restarted.refresh(id))?.status, 'PENDING');
    expect(await store.loadStations(gateway), isEmpty);
  });

  test('保存待激活密钥后才切换，激活响应丢失后复用本机密钥', () async {
    var claims = 0;
    var activations = 0;
    var approved = false;
    late String id;
    final token = 'f' * 64;
    final binding = {
      'scenicId': '3',
      'scenicName': '测试景区',
      'stationId': '19',
      'stationName': '观景台',
      'stationCode': 'A01',
    };
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/applications')) {
        final draft = jsonDecode(request.body) as Map<String, dynamic>;
        id = draft['requestId'] as String;
        return result({'id': id, 'status': 'PENDING'});
      }
      if (request.url.path.endsWith('/claim')) {
        claims++;
        return result({'stationToken': token, 'binding': binding});
      }
      if (request.url.path.endsWith('/activate')) {
        expect(request.headers['x-workstation-token'], token);
        final local = await store.loadEnrollment(gateway, id);
        expect(local?['pending']['token'], token);
        expect((await store.loadStations(gateway)).single.stationId, '18');
        if (++activations == 1) {
          throw http.ClientException('activation response dropped');
        }
        return result({'id': id, 'status': 'BOUND', 'binding': binding});
      }
      return result({
        'id': id,
        'status': activations == 1
            ? 'BOUND'
            : approved
            ? 'APPROVED'
            : 'PENDING',
        'binding': binding,
      });
    });
    addTearDown(client.close);

    final first = WorkstationEnrollment(gateway, store, client);
    final existing = CosUploadProfile(gateway.origin, '18', 'a' * 64);
    await store.saveCos(existing);
    final application = await first.begin('测试景区', '观景台');
    final other = await first.begin('测试景区', '另一个点位');
    await first.refresh(application);
    approved = true;
    await expectLater(
      first.refresh(application),
      throwsA(isA<http.ClientException>()),
    );
    final restarted = WorkstationEnrollment(gateway, store, client);
    expect((await restarted.refresh(application))?.status, 'BOUND');
    expect(claims, 1);
    expect(activations, 2);
    final stations = await store.loadStations(gateway);
    expect(
      stations.map((profile) => profile.stationId),
      unorderedEquals(['18', '19']),
    );
    expect(
      stations.singleWhere((profile) => profile.stationId == '19').scenicName,
      '测试景区',
    );
    final completed = await store.loadEnrollment(gateway, application);
    expect(completed?['result']['status'], 'BOUND');
    expect(completed?['result']['binding']['stationCode'], 'A01');
    expect(completed?.containsKey('secret'), isFalse);
    expect(completed?.containsKey('pending'), isFalse);
    await store.removeCos(stations.singleWhere((p) => p.stationId == '19'));
    expect((await restarted.refresh(application))?.status, 'BOUND');
    expect((await store.loadStations(gateway)).single.stationId, '18');
    expect(activations, 2);
    expect(await store.loadEnrollment(gateway, other), isNotNull);
  });
}

http.Response result(Object data) => http.Response(
  jsonEncode({'code': 200, 'data': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
