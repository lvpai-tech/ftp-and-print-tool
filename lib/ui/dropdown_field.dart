import 'package:material_ui/material_ui.dart';

import 'anchored_dropdown.dart';

class DropdownField<T extends Object> extends StatelessWidget {
  const DropdownField({
    super.key,
    required this.label,
    required this.placeholder,
    required this.options,
    required this.labelFor,
    required this.value,
    required this.onChanged,
    this.errorText,
    this.searchHint,
    this.icon,
    this.showLabel = true,
  });

  final String label, placeholder;
  final List<T> options;
  final String Function(T) labelFor;
  final T? value;
  final ValueChanged<T>? onChanged;
  final String? errorText, searchHint;
  final IconData? icon;
  final bool showLabel;

  bool get _enabled => onChanged != null && options.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final radius = BorderRadius.circular(8);
    final selection = value;
    final error = errorText;
    final textStyle = theme.textTheme.bodyMedium;
    final foreground = !_enabled
        ? colors.onSurface.withValues(alpha: 0.38)
        : selection == null
        ? colors.onSurfaceVariant
        : colors.onSurface;
    final rowHeight =
        (MediaQuery.textScalerOf(context).scale(textStyle?.fontSize ?? 14) *
                    (textStyle?.height ?? 1.4) +
                16)
            .clamp(40.0, double.infinity);
    final preferredHeight =
        (options.length * rowHeight + (searchHint == null ? 8 : 66)).clamp(
          0.0,
          288.0,
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showLabel) ...[
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
        ],
        AnchoredDropdown(
          enabled: _enabled,
          preferredHeight: preferredHeight,
          triggerBuilder: (context, focus, open, toggle) => Semantics(
            label: label,
            expanded: open,
            child: OutlinedButton(
              focusNode: focus,
              onPressed: _enabled ? toggle : null,
              style:
                  OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    backgroundColor: colors.surface,
                    foregroundColor: foreground,
                    shape: RoundedRectangleBorder(borderRadius: radius),
                  ).copyWith(
                    side: WidgetStateProperty.resolveWith(
                      (states) => BorderSide(
                        color: error != null
                            ? colors.error
                            : open || states.contains(WidgetState.focused)
                            ? colors.primary
                            : colors.outlineVariant,
                      ),
                    ),
                  ),
              child: Row(
                children: [
                  if (icon case final leading?) ...[
                    Icon(leading, size: 17),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      selection == null ? placeholder : labelFor(selection),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle?.copyWith(color: foreground),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: open ? colors.primary : null,
                  ),
                ],
              ),
            ),
          ),
          menuBuilder: (context, close) => _DropdownOptions<T>(
            field: this,
            rowHeight: rowHeight,
            onSelected: (option) {
              close();
              onChanged?.call(option);
            },
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ),
          ),
      ],
    );
  }
}

class _DropdownOptions<T extends Object> extends StatefulWidget {
  const _DropdownOptions({
    required this.field,
    required this.rowHeight,
    required this.onSelected,
  });

  final DropdownField<T> field;
  final double rowHeight;
  final ValueChanged<T> onSelected;

  @override
  State<_DropdownOptions<T>> createState() => _DropdownOptionsState<T>();
}

class _DropdownOptionsState<T extends Object>
    extends State<_DropdownOptions<T>> {
  final _searchFocus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    if (widget.field.searchHint != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hint = field.searchHint;
    final options = _query.isEmpty
        ? field.options
        : field.options
              .where(
                (item) => field.labelFor(item).toLowerCase().contains(_query),
              )
              .toList();
    final headerCount = hint == null ? 0 : 1;
    return ListView.builder(
      primary: false,
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: headerCount + (options.isEmpty ? 1 : options.length),
      itemBuilder: (context, index) {
        if (hint != null && index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
            child: TextField(
              focusNode: _searchFocus,
              decoration: InputDecoration(
                hintText: hint,
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
              onSubmitted: (_) {
                if (options.length == 1) widget.onSelected(options.single);
              },
            ),
          );
        }
        if (options.isEmpty) {
          return const ListTile(title: Text('无匹配选项'));
        }
        final item = options[index - headerCount];
        final selected = item == field.value;
        return SizedBox(
          height: widget.rowHeight,
          child: ListTile(
            title: Text(
              field.labelFor(item),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: selected ? colors.primary : colors.onSurface,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            selected: selected,
            selectedTileColor: colors.primary.withValues(alpha: 0.08),
            trailing: selected
                ? Icon(Icons.check_rounded, color: colors.primary, size: 17)
                : null,
            onTap: () => widget.onSelected(item),
          ),
        );
      },
    );
  }
}
