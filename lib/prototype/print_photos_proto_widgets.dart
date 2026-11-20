import 'package:material_ui/material_ui.dart';

import '../printing/ui/design.dart' as print_ui;
import '../ui/design.dart';
import 'print_photos_fake_data.dart';

/// Shared building blocks for the print-photos UI prototype.
class ProtoThumbs extends StatelessWidget {
  const ProtoThumbs({
    super.key,
    required this.count,
    this.more = 0,
    this.size = const Size(44, 56),
  });

  final int count;
  final int more;
  final Size size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Container(
            width: size.width,
            height: size.height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size.width > 60 ? 8 : 6),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  HSLColor.fromAHSL(1, 175 + i * 16, .18, .72).toColor(),
                  HSLColor.fromAHSL(1, 195 + i * 16, .22, .48).toColor(),
                ],
              ),
              border: Border.all(color: Colors.black.withValues(alpha: .08)),
            ),
          ),
        ],
        if (more > 0) ...[
          const SizedBox(width: 6),
          Text(
            '另 $more 张',
            style: const TextStyle(
              fontSize: 12,
              color: WorkstationStyle.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

class ProtoSearchField extends StatelessWidget {
  const ProtoSearchField({
    super.key,
    required this.controller,
    required this.onSubmit,
    this.hint = '输入取片码或手机号',
    this.actionLabel = '找单',
    this.dense = false,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  final String hint;
  final String actionLabel;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: dense ? 42 : 48,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WorkstationStyle.line),
        boxShadow: WorkstationStyle.softShadow,
      ),
      padding: const EdgeInsets.only(left: 14, right: 6),
      child: Row(
        children: [
          const Icon(Icons.search, size: 20, color: WorkstationStyle.muted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onSubmitted: (_) => onSubmit(),
              decoration: InputDecoration(
                hintText: hint,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintStyle: TextStyle(
                  color: WorkstationStyle.muted.withValues(alpha: .85),
                  fontSize: dense ? 13 : 15,
                ),
              ),
              style: TextStyle(fontSize: dense ? 13 : 15),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: onSubmit,
            style: FilledButton.styleFrom(
              backgroundColor: print_ui.accent,
              minimumSize: Size(dense ? 72 : 84, dense ? 32 : 36),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

class ProtoAutoToggle extends StatelessWidget {
  const ProtoAutoToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '自动打印',
          style: TextStyle(fontSize: 13, color: WorkstationStyle.ink),
        ),
        const SizedBox(width: 8),
        Switch(
          value: value,
          activeThumbColor: Colors.white,
          activeTrackColor: print_ui.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class ProtoPanel extends StatelessWidget {
  const ProtoPanel({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.footer,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: WorkstationStyle.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: WorkstationStyle.ink,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          const Divider(height: 1, color: WorkstationStyle.line),
          child,
          if (footer != null) ...[
            const Divider(height: 1, color: WorkstationStyle.line),
            footer!,
          ],
        ],
      ),
    );
  }
}

String protoJobLabel(ProtoJob job) => '#${job.id}';
