import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class AnchoredDropdown extends StatefulWidget {
  const AnchoredDropdown({
    super.key,
    required this.enabled,
    required this.preferredHeight,
    required this.triggerBuilder,
    required this.menuBuilder,
    this.menuWidth,
  });

  final bool enabled;
  final double preferredHeight;
  final double? menuWidth;
  final Widget Function(BuildContext, FocusNode, bool, VoidCallback)
  triggerBuilder;
  final Widget Function(BuildContext, VoidCallback) menuBuilder;

  @override
  State<AnchoredDropdown> createState() => _AnchoredDropdownState();
}

class _AnchoredDropdownState extends State<AnchoredDropdown> {
  final _controller = MenuController();
  final _focus = FocusNode();

  @override
  void didUpdateWidget(covariant AnchoredDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _controller.isOpen) _controller.close();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _toggle() =>
      _controller.isOpen ? _controller.close() : _controller.open();

  void _closeAndFocusTrigger() {
    _controller.close();
    _focus.requestFocus();
  }

  Widget _withEscape(Widget child) => CallbackShortcuts(
    bindings: {
      if (_controller.isOpen)
        const SingleActivator(LogicalKeyboardKey.escape): _closeAndFocusTrigger,
    },
    child: child,
  );

  @override
  Widget build(BuildContext context) => RawMenuAnchor(
    controller: _controller,
    childFocusNode: _focus,
    builder: (context, controller, child) => _withEscape(
      widget.triggerBuilder(context, _focus, controller.isOpen, _toggle),
    ),
    overlayBuilder: _buildOverlay,
  );

  Widget _buildOverlay(BuildContext context, RawMenuOverlayInfo info) {
    const edge = 8.0;
    const gap = 6.0;
    final media = MediaQuery.of(context);
    final anchor = info.anchorRect;
    final minX = media.padding.left + media.viewInsets.left + edge;
    final maxX =
        info.overlaySize.width -
        media.padding.right -
        media.viewInsets.right -
        edge;
    final minY = media.padding.top + media.viewInsets.top + edge;
    final maxY =
        info.overlaySize.height -
        media.padding.bottom -
        media.viewInsets.bottom -
        edge;
    final below = maxY - anchor.bottom - gap;
    final above = anchor.top - gap - minY;
    final openAbove = below < widget.preferredHeight && above > below;
    final maxHeight = math.min(
      widget.preferredHeight,
      openAbove ? above : below,
    );
    final width = math.min(widget.menuWidth ?? anchor.width, maxX - minX);
    if (width <= 0 || maxHeight <= 0) return const SizedBox.shrink();

    final left =
        widget.menuWidth != null &&
            Directionality.of(context) == TextDirection.ltr
        ? anchor.right - width
        : anchor.left;
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned(
          left: left.clamp(minX, maxX - width),
          width: width,
          top: openAbove ? null : anchor.bottom + gap,
          bottom: openAbove ? info.overlaySize.height - anchor.top + gap : null,
          child: TapRegion(
            groupId: info.tapRegionGroupId,
            onTapOutside: (_) => _controller.close(),
            child: _withEscape(
              Material(
                color: colors.surface,
                elevation: 5,
                shadowColor: colors.shadow.withValues(alpha: 0.20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: colors.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: widget.menuBuilder(context, _closeAndFocusTrigger),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
