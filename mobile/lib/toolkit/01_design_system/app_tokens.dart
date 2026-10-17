/// Layout, shape, motion and elevation tokens shared by every component.
///
/// Source: Cookly `app_spacing.dart` + `app_shadows.dart`, TaskFlow
/// `app_animations.dart`. Values are plain logical pixels — the source apps
/// scaled them through `flutter_screenutil` against their own 411×914 design
/// frame, which would tie every component to that frame.
library;

import 'package:flutter/material.dart';

/// Spacing scale on a 4/8 rhythm. Each step is larger than the one before it.
abstract final class Gap {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Horizontal page margin.
  static const double gutter = 20;
}

/// Corner radii. Use [pill] for chips and fully rounded buttons.
abstract final class Radii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;
}

/// Standard paddings built from [Gap].
abstract final class Insets {
  static const EdgeInsets page = EdgeInsets.symmetric(horizontal: Gap.gutter);
  static const EdgeInsets card = EdgeInsets.all(Gap.md);
  static const EdgeInsets sheet = EdgeInsets.fromLTRB(
    Gap.gutter,
    Gap.lg,
    Gap.gutter,
    Gap.lg,
  );

  /// Generous vertical padding for list rows that must stay easy to tap.
  static const EdgeInsets listRow = EdgeInsets.symmetric(
    horizontal: Gap.gutter,
    vertical: Gap.md,
  );
}

/// Animation durations and curves.
abstract final class Motion {
  /// Press feedback — short enough to feel instant.
  static const Duration press = Duration(milliseconds: 110);
  static const Duration short = Duration(milliseconds: 200);
  static const Duration medium = Duration(milliseconds: 300);
  static const Duration long = Duration(milliseconds: 450);

  static const Curve standard = Curves.easeOutCubic;

  /// Slight overshoot — for things that "pop" into place.
  static const Curve emphasized = Curves.easeOutBack;
}

/// Soft, colour-tinted shadows.
///
/// Tinting the shadow with the brand colour at low opacity reads warmer than
/// grey/black shadows and keeps elevation subtle. Pass
/// `Theme.of(context).colorScheme.primary` (or `shadow`) as [tint].
abstract final class AppShadows {
  /// Resting cards.
  static List<BoxShadow> soft(Color tint) => [
    BoxShadow(
      color: tint.withValues(alpha: 0.06),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];

  /// Hero surfaces and pressed/raised states — lifts rather than darkens.
  static List<BoxShadow> lifted(Color tint) => [
    BoxShadow(
      color: tint.withValues(alpha: 0.10),
      blurRadius: 28,
      offset: const Offset(0, 12),
    ),
  ];

  /// A coloured glow under a filled button or selected chip.
  static List<BoxShadow> glow(Color color) => [
    BoxShadow(
      color: color.withValues(alpha: 0.30),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];
}
