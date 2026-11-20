import 'package:material_ui/material_ui.dart';

/// Shared visual tokens for the workstation shell.
abstract final class WorkstationStyle {
  static const bg = Color(0xffeef2f7);
  static const ink = Color(0xff0f172a);
  static const muted = Color(0xff64748b);
  static const line = Color(0xffe2e8f0);
  static const card = Color(0xffffffff);
  static const accent = Color(0xff1d4ed8);
  static const accentSoft = Color(0xffeff4ff);
  static const ok = Color(0xff047857);
  static const okSoft = Color(0xffecfdf5);
  static const warn = Color(0xffb45309);
  static const warnSoft = Color(0xfffffbeb);
  static const bad = Color(0xffb91c1c);
  static const badSoft = Color(0xfffef2f2);
  static const radius = 14.0;

  static List<BoxShadow> get softShadow => [
    BoxShadow(
      color: ink.withValues(alpha: .035),
      blurRadius: 18,
      offset: const Offset(0, 6),
    ),
  ];

  static BoxDecoration surface({Color color = card}) => BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: line),
    boxShadow: softShadow,
  );
}

class StatusTag extends StatelessWidget {
  const StatusTag({
    super.key,
    required this.label,
    required this.color,
    required this.soft,
  });

  final String label;
  final Color color;
  final Color soft;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: soft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
