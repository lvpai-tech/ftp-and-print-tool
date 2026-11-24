import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/ui/dropdown_field.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('空间不足时向上展开，点外关闭并执行点击', (tester) async {
    tester.view.physicalSize = const Size(400, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var outsideClicks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed: () => outsideClicks++,
                  child: const Text('外部按钮'),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: 220,
                  child: DropdownField<int>(
                    label: '选项',
                    showLabel: false,
                    placeholder: '请选择',
                    options: List.generate(12, (index) => index + 1),
                    labelFor: (index) => '选项 $index',
                    value: null,
                    onChanged: (_) {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final trigger = find.widgetWithText(OutlinedButton, '请选择');
    final before = tester.getRect(trigger);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    final popup = find.byType(ListView);
    final menu = tester.getRect(popup);
    expect(menu.bottom, lessThan(before.top));
    expect(menu.left, before.left);
    expect(menu.width, before.width);
    expect(menu.top, greaterThanOrEqualTo(8));
    expect(tester.getRect(trigger), before);

    await tester.tap(find.text('外部按钮'));
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    expect(outsideClicks, 1);
    expect(tester.getRect(trigger), before);

    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(12, 160));
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
