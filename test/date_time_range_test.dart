import 'package:flutter_test/flutter_test.dart';
import 'package:lvpai_ftp_client/printing/app.dart';
import 'package:lvpai_ftp_client/printing/job_query_time.dart';
import 'package:lvpai_ftp_client/printing/ui/date_time_range_field.dart';
import 'package:material_ui/material_ui.dart';

import 'printing_workstation_test.dart';

void main() {
  test('上海时间用选中的钟点并带 +08:00', () {
    expect(
      shanghaiDateTime(DateTime(2026, 1, 2, 3, 4, 5)),
      '2026-01-02T03:04:05+08:00',
    );
    expect(
      formatWallClock(DateTime(2026, 11, 21, 9, 30, 0)),
      '2026-11-21 09:30:00',
    );
  });

  testWidgets('确定后交出开始和结束的日期与时分秒', (tester) async {
    tester.view.physicalSize = const Size(900, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    DateTimeRange? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DateTimeRangePanel(
            initial: null,
            firstDate: DateTime(2024),
            lastDate: DateTime(2027, 6),
            now: DateTime(2026, 11, 21, 15),
            onConfirm: (range) => picked = range,
            onClear: () {},
          ),
        ),
      ),
    );
    expect(find.text('2026年11月'), findsOneWidget);
    expect(find.text('2026年12月'), findsOneWidget);
    expect(find.text('开始时间'), findsOneWidget);
    expect(find.text('结束时间'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('created-range-confirm')));
    await tester.pump();
    expect(find.text('请选择开始和结束日期'), findsOneWidget);
    expect(picked, isNull);

    await tester.tap(
      find.byKey(const ValueKey('created-range-left-2026-11-10')),
    );
    await tester.tap(
      find.byKey(const ValueKey('created-range-left-2026-11-21')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('created-range-left-hour')),
      '9',
    );
    await tester.enterText(
      find.byKey(const ValueKey('created-range-left-minute')),
      '30',
    );
    await tester.enterText(
      find.byKey(const ValueKey('created-range-right-hour')),
      '18',
    );
    await tester.enterText(
      find.byKey(const ValueKey('created-range-right-second')),
      '45',
    );
    await tester.tap(find.byKey(const ValueKey('created-range-confirm')));
    await tester.pump();
    expect(picked?.start, DateTime(2026, 11, 10, 9, 30));
    expect(picked?.end, DateTime(2026, 11, 21, 18, 59, 45));

    await tester.enterText(
      find.byKey(const ValueKey('created-range-right-hour')),
      '8',
    );
    await tester.tap(
      find.byKey(const ValueKey('created-range-left-2026-11-10')),
    );
    await tester.tap(
      find.byKey(const ValueKey('created-range-left-2026-11-10')),
    );
    await tester.tap(find.byKey(const ValueKey('created-range-confirm')));
    await tester.pump();
    expect(find.text('结束时间不能早于开始时间'), findsOneWidget);
  });

  testWidgets('打印页按所选时分秒查询，清空后去掉时间条件', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = ControlledBridge();
    final now = DateTime.now();
    await tester.pumpWidget(MaterialApp(home: Workstation(bridge: bridge)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始时间 至 结束时间'));
    await tester.pumpAndSettle();
    expect(find.text('确定'), findsOneWidget);
    expect(find.text('Select range'), findsNothing);

    await tester.tap(
      find.byKey(ValueKey('created-range-left-${now.year}-${now.month}-1')),
    );
    await tester.tap(
      find.byKey(ValueKey('created-range-left-${now.year}-${now.month}-2')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('created-range-left-hour')),
      '08',
    );
    await tester.enterText(
      find.byKey(const ValueKey('created-range-left-minute')),
      '15',
    );
    await tester.enterText(
      find.byKey(const ValueKey('created-range-right-hour')),
      '18',
    );
    await tester.enterText(
      find.byKey(const ValueKey('created-range-right-minute')),
      '45',
    );
    await tester.tap(find.byKey(const ValueKey('created-range-confirm')));
    await tester.pumpAndSettle();

    final month = now.month.toString().padLeft(2, '0');
    expect(bridge.arguments['queryJobs'], [
      {
        'printStatus': 'UNPRINTED',
        'pageNum': 1,
        'pageSize': 20,
        'createdFrom': '${now.year}-$month-01T08:15:00+08:00',
        'createdTo': '${now.year}-$month-02T18:45:59+08:00',
      },
    ]);
    expect(find.text('确定'), findsNothing);

    await tester.tap(find.byIcon(Icons.cancel));
    await tester.pumpAndSettle();
    expect(bridge.arguments['queryJobs'], [
      {
        'printStatus': 'UNPRINTED',
        'pageNum': 1,
        'pageSize': 20,
        'createdFrom': '',
        'createdTo': '',
      },
    ]);
    expect(find.text('开始时间 至 结束时间'), findsOneWidget);
    expect(find.text('确定'), findsNothing);
  });
}
