import 'package:material_ui/material_ui.dart';

class WorkstationFormDialog extends StatelessWidget {
  const WorkstationFormDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.width = 460,
    this.canClose = true,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;
  final double width;
  final bool canClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
    );
    const buttonPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 8);

    return Dialog(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: colors.shadow.withValues(alpha: 0.24),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      constraints: BoxConstraints.tightFor(width: width),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    namesRoute: true,
                    header: true,
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭弹窗',
                  onPressed: canClose
                      ? () => Navigator.of(context).maybePop()
                      : null,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              primary: false,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: content,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: FilledButtonTheme(
              data: FilledButtonThemeData(
                style: FilledButton.styleFrom(
                  shape: buttonShape,
                  minimumSize: const Size(0, 40),
                  padding: buttonPadding,
                ),
              ),
              child: OutlinedButtonTheme(
                data: OutlinedButtonThemeData(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.onSurface,
                    side: BorderSide(color: colors.outlineVariant),
                    shape: buttonShape,
                    minimumSize: const Size(0, 40),
                    padding: buttonPadding,
                  ),
                ),
                child: OverflowBar(
                  alignment: MainAxisAlignment.end,
                  overflowAlignment: OverflowBarAlignment.end,
                  spacing: 8,
                  overflowSpacing: 8,
                  children: actions,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
