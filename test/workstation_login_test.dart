import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/printing/print_bridge.dart';
import 'package:lvpai_ftp_client/ui/workstation_login.dart';
import 'package:lvpai_ftp_client/workstation_account.dart';
import 'package:lvpai_ftp_client/workstation_session.dart';
import 'package:material_ui/material_ui.dart';

class ControlledAccount extends WorkstationAccount {
  ControlledAccount() : super(Uri.https('workstation.example.test'));

  final sent = <String>[];
  final attempts = <(String, String)>[];

  @override
  Future<int> sendCode(String phone) async {
    sent.add(phone);
    return 60;
  }

  @override
  Future<WorkstationIdentity> login(String phone, String code) async {
    attempts.add((phone, code));
    return const WorkstationIdentity('1', '测试员工', 'operator', []);
  }
}

void main() {
  testWidgets('窄窗手机号校验、获取验证码、倒计时和回车提交', (tester) async {
    tester.view.physicalSize = const Size(320, 440);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final account = ControlledAccount();
    WorkstationIdentity? signedIn;
    await tester.pumpWidget(
      MaterialApp(
        home: WorkstationLogin(
          account: account,
          onLogin: (user) async => signedIn = user,
        ),
      ),
    );
    await tester.pump();
    final fields = find.byType(TextField);
    final send = find.widgetWithText(OutlinedButton, '获取验证码');
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pump();
    expect(find.text('请输入有效的 11 位手机号'), findsOneWidget);
    expect(account.sent, isEmpty);
    await tester.enterText(fields.first, '13800138000');
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pump();
    expect(account.sent, ['13800138000']);
    expect(find.textContaining('秒后重发'), findsOneWidget);
    expect(tester.widget<TextField>(fields.last).focusNode!.hasFocus, isTrue);
    await tester.enterText(fields.last, '012345');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(account.attempts, [('13800138000', '012345')]);
    expect(signedIn?.name, '测试员工');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('退出拦截包含空闲监听和已开启的自动打印', () {
    final bridge = PrintBridge()
      ..snapshot = {
        'state': {'autoPrint': true},
      };
    final session = WorkstationSession(bridge)
      ..transferConfigured = true
      ..transferActive = true
      ..activeStations = ['A08', 'A99'];
    expect(session.signOutBlockers, [contains('A08、A99'), contains('关闭自动打印')]);
    session.transferActive = false;
    session.activeStations = [];
    bridge.snapshot = {};
    expect(session.signOutBlockers, isEmpty);
    session.dispose();
    bridge.dispose();
  });
}
