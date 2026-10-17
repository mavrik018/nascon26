import 'package:flutter/material.dart';

import '../01_design_system/app_tokens.dart';
import 'pressable.dart';

/// A soft, tinted pill for categories, filters and modes.
///
/// Source: Cookly `CooklyChip` (`core/widgets/states.dart`). Unselected it is
/// a 10%-opacity tint with full-colour text; selected it fills with the tint
/// and glows. Each chip can carry its own colour, so categories can be
/// colour-coded (e.g. vegetables teal, desserts pink).
///
/// ```dart
/// AppChip(
///   label: 'Vegan',
///   icon: Icons.eco,
///   selected: filters.contains('vegan'),
///   onTap: () => toggle('vegan'),
/// )
/// ```
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.icon,
    this.selected = false,
    this.onTap,
    this.color,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onTap;

  /// Tint for this chip. Defaults to the theme's secondary colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.secondary;
    final foreground = selected
        ? (ThemeData.estimateBrightnessForColor(tint) == Brightness.dark
              ? Colors.white
              : Colors.black)
        : tint;

    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.short,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.md - 4,
            vertical: Gap.sm + 2,
          ),
          decoration: BoxDecoration(
            color: selected ? tint : tint.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(Radii.pill),
            boxShadow: selected ? AppShadows.glow(tint) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: foreground),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
