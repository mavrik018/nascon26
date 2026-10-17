import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Makes any widget tappable with a tactile press: it shrinks slightly (and
/// optionally dims) while the finger is down, with a selection haptic on tap.
///
/// Source: Cookly `core/motion/pressable.dart` (scale) merged with the
/// `_IosPressable` row from StudyBuddies/Cookly `ios_ui.dart` (dim). Use it
/// instead of `InkWell` on custom cards, where a grey ripple looks foreign.
///
/// ```dart
/// Pressable(onTap: openRecipe, child: RecipeCard(recipe))
/// ```
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.98,
    this.dimOnPress = false,
    this.haptic = true,
    this.duration = const Duration(milliseconds: 110),
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale while pressed. 1.0 disables the shrink.
  final double scale;

  /// Fades to 60% opacity while pressed — the quieter iOS list-row style.
  final bool dimOnPress;
  final bool haptic;
  final Duration duration;

  /// Read by screen readers. Set it when [child] is an icon or image.
  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _setDown(bool value) {
    if (!_enabled || _down == value) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    final onLongPress = widget.onLongPress;

    return Semantics(
      button: _enabled,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setDown(true),
        onTapUp: (_) => _setDown(false),
        onTapCancel: () => _setDown(false),
        onTap: onTap == null
            ? null
            : () {
                if (widget.haptic) HapticFeedback.selectionClick();
                onTap();
              },
        onLongPress: onLongPress == null
            ? null
            : () {
                if (widget.haptic) HapticFeedback.mediumImpact();
                onLongPress();
              },
        child: AnimatedOpacity(
          opacity: widget.dimOnPress && _down ? 0.6 : 1,
          duration: widget.duration,
          child: AnimatedScale(
            scale: _down ? widget.scale : 1,
            duration: widget.duration,
            curve: Curves.easeOut,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
