import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ui/design.dart';
import '../job_query_time.dart';

/// 打印任务创建时间范围。点开后在按钮下方弹出双月历，左右分别选开始、结束的日期和时分秒。
class JobCreatedRangeField extends StatefulWidget {
  const JobCreatedRangeField({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.now,
  });

  final DateTimeRange? value;
  final ValueChanged<DateTimeRange?> onChanged;
  final bool enabled;

  /// 测试注入的当前时间。缺省为打开面板时的本机时间。
  final DateTime? now;

  @override
  State<JobCreatedRangeField> createState() => _JobCreatedRangeFieldState();
}

class _JobCreatedRangeFieldState extends State<JobCreatedRangeField> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _fieldKey = GlobalKey();
  int _session = 0;

  void _toggle() {
    if (_portal.isShowing) {
      _portal.hide();
      return;
    }
    setState(() => _session++);
    _portal.show();
  }

  void _close() {
    if (_portal.isShowing) _portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final label = value == null
        ? '开始时间 至 结束时间'
        : '${formatWallClock(value.start)} 至 ${formatWallClock(value.end)}';
    final maxLabel = math.min(360.0, MediaQuery.sizeOf(context).width - 48);
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _overlay,
        child: Material(
          key: _fieldKey,
          color: WorkstationStyle.card,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            onTap: widget.enabled ? _toggle : null,
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 32,
              padding: const EdgeInsets.only(left: 10, right: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: _portal.isShowing
                      ? WorkstationStyle.accent
                      : const Color(0xffdcdfe6),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxLabel),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: value == null
                            ? WorkstationStyle.muted
                            : WorkstationStyle.ink,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (value != null) ...[
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: widget.enabled
                          ? () {
                              _close();
                              widget.onChanged(null);
                            }
                          : null,
                      child: const Icon(
                        Icons.cancel,
                        size: 14,
                        color: WorkstationStyle.muted,
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.calendar_today_outlined,
                    size: 14,
                    color: WorkstationStyle.muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _overlay(BuildContext overlayContext) {
    final screen = MediaQuery.sizeOf(overlayContext);
    final stacked = screen.width < 720;
    final panelWidth = stacked ? math.min(360.0, screen.width - 16) : 640.0;
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    var dx = 0.0;
    var above = false;
    if (box != null && box.hasSize && box.attached) {
      final origin = box.localToGlobal(Offset.zero);
      final targetRight = origin.dx + box.size.width;
      var panelLeft = targetRight - panelWidth;
      if (panelLeft < 8) panelLeft = 8;
      if (panelLeft + panelWidth > screen.width - 8) {
        panelLeft = math.max(8, screen.width - 8 - panelWidth);
      }
      dx = panelLeft - (targetRight - panelWidth);
      final below = screen.height - origin.dy - box.size.height;
      final estimated = stacked ? 680.0 : 420.0;
      above = below < estimated && origin.dy > below;
    }
    final now = widget.now ?? DateTime.now();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: above ? Alignment.topRight : Alignment.bottomRight,
          followerAnchor: above ? Alignment.bottomRight : Alignment.topRight,
          offset: Offset(dx, above ? -6 : 6),
          child: GestureDetector(
            onTap: () {},
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: panelWidth,
              child: DateTimeRangePanel(
                key: ValueKey(_session),
                initial: widget.value,
                firstDate: DateTime(2024),
                lastDate: now.add(const Duration(days: 1)),
                now: now,
                onConfirm: (range) {
                  _close();
                  widget.onChanged(range);
                },
                onClear: () {
                  _close();
                  if (widget.value != null) widget.onChanged(null);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 双月历与开始、结束时分秒。确定后才把范围交出去。
class DateTimeRangePanel extends StatefulWidget {
  const DateTimeRangePanel({
    super.key,
    required this.initial,
    required this.firstDate,
    required this.lastDate,
    required this.now,
    required this.onConfirm,
    required this.onClear,
  });

  final DateTimeRange? initial;
  final DateTime firstDate;
  final DateTime lastDate;
  final DateTime now;
  final ValueChanged<DateTimeRange> onConfirm;
  final VoidCallback onClear;

  @override
  State<DateTimeRangePanel> createState() => _DateTimeRangePanelState();
}

class _DateTimeRangePanelState extends State<DateTimeRangePanel> {
  late DateTime _leftMonth;
  DateTime? _startDay;
  DateTime? _endDay;
  DateTime? _hover;
  String? _error;
  late final TextEditingController _startHour;
  late final TextEditingController _startMinute;
  late final TextEditingController _startSecond;
  late final TextEditingController _endHour;
  late final TextEditingController _endMinute;
  late final TextEditingController _endSecond;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _startDay = _dateOnly(initial?.start);
    _endDay = _dateOnly(initial?.end);
    final start = initial?.start;
    final end = initial?.end;
    _startHour = TextEditingController(text: _two(start?.hour ?? 0));
    _startMinute = TextEditingController(text: _two(start?.minute ?? 0));
    _startSecond = TextEditingController(text: _two(start?.second ?? 0));
    _endHour = TextEditingController(text: _two(end?.hour ?? 23));
    _endMinute = TextEditingController(text: _two(end?.minute ?? 59));
    _endSecond = TextEditingController(text: _two(end?.second ?? 59));
    final anchor = _startDay ?? widget.now;
    _leftMonth = DateTime(anchor.year, anchor.month);
  }

  @override
  void dispose() {
    _startHour.dispose();
    _startMinute.dispose();
    _startSecond.dispose();
    _endHour.dispose();
    _endMinute.dispose();
    _endSecond.dispose();
    super.dispose();
  }

  DateTime get _rightMonth => DateTime(_leftMonth.year, _leftMonth.month + 1);

  void _shift(int months) {
    final next = DateTime(_leftMonth.year, _leftMonth.month + months);
    final earliest = DateTime(widget.firstDate.year, widget.firstDate.month);
    final latest = DateTime(widget.lastDate.year, widget.lastDate.month);
    if (next.isBefore(earliest) || next.isAfter(latest)) return;
    setState(() => _leftMonth = next);
  }

  void _pick(DateTime day) {
    if (!_enabled(day)) return;
    final picked = _dateOnly(day)!;
    setState(() {
      _error = null;
      _hover = null;
      if (_startDay != null && _endDay != null) {
        _startDay = picked;
        _endDay = null;
        return;
      }
      if (_startDay == null || picked.isBefore(_startDay!)) {
        _startDay = picked;
        _endDay = null;
        return;
      }
      _endDay = picked;
    });
  }

  void _confirm() {
    final startClock = _clock(_startHour, _startMinute, _startSecond);
    final endClock = _clock(_endHour, _endMinute, _endSecond);
    if (_startDay == null || _endDay == null) {
      setState(() => _error = '请选择开始和结束日期');
      return;
    }
    if (startClock == null || endClock == null) {
      setState(() => _error = '请填写有效的时分秒');
      return;
    }
    final start = DateTime(
      _startDay!.year,
      _startDay!.month,
      _startDay!.day,
      startClock.$1,
      startClock.$2,
      startClock.$3,
    );
    final end = DateTime(
      _endDay!.year,
      _endDay!.month,
      _endDay!.day,
      endClock.$1,
      endClock.$2,
      endClock.$3,
    );
    if (end.isBefore(start)) {
      setState(() => _error = '结束时间不能早于开始时间');
      return;
    }
    widget.onConfirm(DateTimeRange(start: start, end: end));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 640.0;
        final stacked = width < 600;
        final months = [
          _MonthPane(
            side: 'left',
            month: _leftMonth,
            showPrevious: true,
            showNext: false,
            canRetreat: !DateTime(_leftMonth.year, _leftMonth.month)
                .isAtSameMomentAs(
                  DateTime(widget.firstDate.year, widget.firstDate.month),
                ),
            canAdvance: false,
            onRetreat: () => _shift(-1),
            onAdvance: () {},
            startDay: _startDay,
            endDay: _endDay,
            hover: _hover,
            now: widget.now,
            enabled: _enabled,
            onPick: _pick,
            onHover: (day) => setState(() => _hover = day),
            timeLabel: '开始时间',
            hour: _startHour,
            minute: _startMinute,
            second: _startSecond,
          ),
          _MonthPane(
            side: 'right',
            month: _rightMonth,
            showPrevious: false,
            showNext: true,
            canRetreat: false,
            canAdvance: !DateTime(_leftMonth.year, _leftMonth.month)
                .isAtSameMomentAs(
                  DateTime(widget.lastDate.year, widget.lastDate.month),
                ),
            onRetreat: () {},
            onAdvance: () => _shift(1),
            startDay: _startDay,
            endDay: _endDay,
            hover: _hover,
            now: widget.now,
            enabled: _enabled,
            onPick: _pick,
            onHover: (day) => setState(() => _hover = day),
            timeLabel: '结束时间',
            hour: _endHour,
            minute: _endMinute,
            second: _endSecond,
          ),
        ];
        final monthsView = stacked
            ? Column(children: months)
            : IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: months[0]),
                    const VerticalDivider(
                      width: 1,
                      color: WorkstationStyle.line,
                    ),
                    Expanded(child: months[1]),
                  ],
                ),
              );
        return Material(
          color: WorkstationStyle.card,
          elevation: 8,
          shadowColor: WorkstationStyle.ink.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: WorkstationStyle.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.max(
                      160,
                      MediaQuery.sizeOf(context).height - 88,
                    ),
                  ),
                  child: SingleChildScrollView(child: monthsView),
                ),
                const Divider(height: 1, color: WorkstationStyle.line),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                  child: Row(
                    children: [
                      if (_error != null)
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(
                              color: WorkstationStyle.bad,
                              fontSize: 12,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      TextButton(
                        key: const ValueKey('created-range-clear'),
                        onPressed: widget.onClear,
                        style: TextButton.styleFrom(
                          foregroundColor: WorkstationStyle.muted,
                          minimumSize: const Size(64, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          textStyle: const TextStyle(fontSize: 13),
                        ),
                        child: const Text('清空'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('created-range-confirm'),
                        onPressed: _confirm,
                        style: FilledButton.styleFrom(
                          backgroundColor: WorkstationStyle.accent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(64, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(Radius.circular(4)),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _enabled(DateTime day) {
    final date = _dateOnly(day)!;
    final first = _dateOnly(widget.firstDate)!;
    final last = _dateOnly(widget.lastDate)!;
    return !date.isBefore(first) && !date.isAfter(last);
  }
}

class _MonthPane extends StatelessWidget {
  const _MonthPane({
    required this.side,
    required this.month,
    required this.showPrevious,
    required this.showNext,
    required this.canRetreat,
    required this.canAdvance,
    required this.onRetreat,
    required this.onAdvance,
    required this.startDay,
    required this.endDay,
    required this.hover,
    required this.now,
    required this.enabled,
    required this.onPick,
    required this.onHover,
    required this.timeLabel,
    required this.hour,
    required this.minute,
    required this.second,
  });

  final String side;
  final DateTime month;
  final bool showPrevious;
  final bool showNext;
  final bool canRetreat;
  final bool canAdvance;
  final VoidCallback onRetreat;
  final VoidCallback onAdvance;
  final DateTime? startDay;
  final DateTime? endDay;
  final DateTime? hover;
  final DateTime now;
  final bool Function(DateTime day) enabled;
  final ValueChanged<DateTime> onPick;
  final ValueChanged<DateTime?> onHover;
  final String timeLabel;
  final TextEditingController hour;
  final TextEditingController minute;
  final TextEditingController second;

  @override
  Widget build(BuildContext context) {
    final cells = _monthCells(month);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: Column(
        children: [
          Row(
            children: [
              _MonthArrow(
                tooltip: '上个月',
                icon: Icons.chevron_left,
                visible: showPrevious,
                enabled: canRetreat,
                onPressed: onRetreat,
              ),
              Expanded(
                child: Text(
                  '${month.year}年${month.month}月',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: WorkstationStyle.ink,
                  ),
                ),
              ),
              _MonthArrow(
                tooltip: '下个月',
                icon: Icons.chevron_right,
                visible: showNext,
                enabled: canAdvance,
                onPressed: onAdvance,
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Row(
            children: [
              _Weekday('日'),
              _Weekday('一'),
              _Weekday('二'),
              _Weekday('三'),
              _Weekday('四'),
              _Weekday('五'),
              _Weekday('六'),
            ],
          ),
          for (var week = 0; week < 6; week++)
            Row(
              children: [
                for (var column = 0; column < 7; column++)
                  _DayCell(
                    side: side,
                    day: cells[week * 7 + column],
                    inMonth: cells[week * 7 + column].month == month.month,
                    startDay: startDay,
                    endDay: endDay,
                    hover: hover,
                    today: _dateOnly(now),
                    enabled: enabled(cells[week * 7 + column]),
                    onPick: onPick,
                    onHover: onHover,
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                timeLabel,
                style: const TextStyle(
                  fontSize: 12,
                  color: WorkstationStyle.muted,
                ),
              ),
              const SizedBox(width: 8),
              _ClockField(
                fieldKey: ValueKey('created-range-$side-hour'),
                controller: hour,
              ),
              const _ClockColon(),
              _ClockField(
                fieldKey: ValueKey('created-range-$side-minute'),
                controller: minute,
              ),
              const _ClockColon(),
              _ClockField(
                fieldKey: ValueKey('created-range-$side-second'),
                controller: second,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MonthArrow extends StatelessWidget {
  const _MonthArrow({
    required this.tooltip,
    required this.icon,
    required this.visible,
    required this.enabled,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool visible;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: visible
          ? IconButton(
              tooltip: tooltip,
              onPressed: enabled ? onPressed : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              icon: Icon(icon, size: 18),
              color: WorkstationStyle.ink,
              disabledColor: WorkstationStyle.line,
            )
          : null,
    );
  }
}

class _Weekday extends StatelessWidget {
  const _Weekday(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: SizedBox(
        height: 28,
        child: Center(
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: WorkstationStyle.muted),
          ),
        ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.side,
    required this.day,
    required this.inMonth,
    required this.startDay,
    required this.endDay,
    required this.hover,
    required this.today,
    required this.enabled,
    required this.onPick,
    required this.onHover,
  });

  final String side;
  final DateTime day;
  final bool inMonth;
  final DateTime? startDay;
  final DateTime? endDay;
  final DateTime? hover;
  final DateTime? today;
  final bool enabled;
  final ValueChanged<DateTime> onPick;
  final ValueChanged<DateTime?> onHover;

  @override
  Widget build(BuildContext context) {
    final date = _dateOnly(day)!;
    final endpoint =
        (startDay != null && date == startDay) ||
        (endDay != null && date == endDay);
    final band = _inBand(date);
    final isToday = today != null && date == today;
    final Color textColor;
    if (!enabled) {
      textColor = WorkstationStyle.muted.withValues(alpha: .35);
    } else if (endpoint) {
      textColor = Colors.white;
    } else if (!inMonth) {
      textColor = WorkstationStyle.muted;
    } else if (isToday) {
      textColor = WorkstationStyle.accent;
    } else {
      textColor = WorkstationStyle.ink;
    }
    return Expanded(
      child: MouseRegion(
        onEnter: enabled ? (_) => onHover(date) : null,
        onExit: (_) => onHover(null),
        child: GestureDetector(
          key: ValueKey(
            'created-range-$side-${date.year}-${date.month}-${date.day}',
          ),
          onTap: enabled ? () => onPick(date) : null,
          child: SizedBox(
            height: 32,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: band && !endpoint ? WorkstationStyle.accentSoft : null,
              ),
              child: Center(
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: endpoint ? WorkstationStyle.accent : null,
                    shape: BoxShape.circle,
                    border: isToday && !endpoint
                        ? Border.all(color: WorkstationStyle.accent)
                        : null,
                  ),
                  child: Text(
                    '${date.day}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: endpoint || isToday
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: textColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _inBand(DateTime date) {
    final start = startDay;
    if (start == null) return false;
    final finish = endDay ?? hover;
    if (finish == null) return false;
    final from = start.isBefore(finish) ? start : finish;
    final to = start.isBefore(finish) ? finish : start;
    return !date.isBefore(from) && !date.isAfter(to);
  }
}

class _ClockField extends StatelessWidget {
  const _ClockField({required this.fieldKey, required this.controller});

  final ValueKey<String> fieldKey;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: TextField(
        key: fieldKey,
        controller: controller,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 13,
          color: WorkstationStyle.ink,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 6),
          border: _border(const Color(0xffdcdfe6)),
          enabledBorder: _border(const Color(0xffdcdfe6)),
          focusedBorder: _border(WorkstationStyle.accent),
        ),
        onChanged: (value) {
          final digits = value.replaceAll(RegExp(r'\D'), '');
          final next = digits.length > 2 ? digits.substring(0, 2) : digits;
          if (next == value) return;
          controller.text = next;
          controller.selection = TextSelection.collapsed(offset: next.length);
        },
      ),
    );
  }

  OutlineInputBorder _border(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(4),
    borderSide: BorderSide(color: color),
  );
}

class _ClockColon extends StatelessWidget {
  const _ClockColon();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 2),
      child: Text(':', style: TextStyle(color: WorkstationStyle.muted)),
    );
  }
}

List<DateTime> _monthCells(DateTime month) {
  final first = DateTime(month.year, month.month);
  final lead = first.weekday % 7;
  final start = first.subtract(Duration(days: lead));
  return List.generate(
    42,
    (index) => DateTime(start.year, start.month, start.day + index),
  );
}

DateTime? _dateOnly(DateTime? value) =>
    value == null ? null : DateTime(value.year, value.month, value.day);

String _two(int value) => value.toString().padLeft(2, '0');

(int, int, int)? _clock(
  TextEditingController hour,
  TextEditingController minute,
  TextEditingController second,
) {
  final h = _part(hour.text, 23);
  final m = _part(minute.text, 59);
  final s = _part(second.text, 59);
  if (h == null || m == null || s == null) return null;
  return (h, m, s);
}

int? _part(String text, int max) {
  final value = int.tryParse(text.trim());
  if (value == null || value < 0 || value > max) return null;
  return value;
}
