import 'dart:ui';
import 'package:flutter/material.dart';

import '../toolkit/01_design_system/app_tokens.dart';
import '../toolkit/02_ui_elements/pressable.dart';
import 'sample_data.dart';

const ocean = Color(0xFF006D9F);
const ink = Color(0xFF102A43);
const muted = Color(0xFF52606D);
const green = Color(0xFF087453);

ThemeData oceanTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'Inter',
  colorScheme: ColorScheme.fromSeed(seedColor: ocean).copyWith(
    primary: ocean,
    secondary: ocean,
    onSurface: ink,
    surface: const Color(0xFFF1F7FB),
  ),
  scaffoldBackgroundColor: Colors.transparent,
  textTheme: const TextTheme(
    headlineLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 34,
      fontWeight: FontWeight.w800,
      color: ink,
      letterSpacing: -1.2,
    ),
    headlineMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 26,
      fontWeight: FontWeight.w800,
      color: ink,
      letterSpacing: -.8,
    ),
    titleLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 20,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    titleMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 15,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    bodyMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 13,
      color: ink,
      height: 1.5,
    ),
    bodySmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 11,
      color: muted,
      height: 1.5,
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white.withValues(alpha: .82),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFFBCD2DF)),
    ),
    contentPadding: const EdgeInsets.all(16),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: ocean,
      foregroundColor: Colors.white,
      minimumSize: const Size(48, 50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  ),
  dividerTheme: const DividerThemeData(color: Color(0xFFCBDFE8), space: 24),
  snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
);

class OceanBackground extends StatelessWidget {
  const OceanBackground({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF005F8C),
          Color(0xFF008EC4),
          Color(0xFFA8CADB),
          Color(0xFFE8F0F5),
        ],
        stops: [0, .24, .62, 1],
      ),
    ),
    child: child,
  );
}

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.opacity = .72,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double opacity;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(Radii.xl),
      boxShadow: AppShadows.lifted(ocean),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(Radii.xl),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: opacity),
            borderRadius: BorderRadius.circular(Radii.xl),
            border: Border.all(color: Colors.white.withValues(alpha: .82)),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    ),
  );
}

class OceanPage extends StatelessWidget {
  const OceanPage({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.actions = const [],
    this.bottom,
  });
  final String title;
  final String? subtitle;
  final List<Widget> children, actions;
  final Widget? bottom;
  @override
  Widget build(BuildContext context) => OceanBackground(
    child: Scaffold(
      bottomNavigationBar: bottom,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 16, 20),
                    child: Row(
                      children: [
                        if (Navigator.canPop(context))
                          IconButton(
                            tooltip: 'Back',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(
                              Icons.arrow_back,
                              color: Colors.white,
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                subtitle ?? 'ALPHA SPORTS LEAGUE',
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                title,
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 26,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: -.8,
                                ),
                              ),
                            ],
                          ),
                        ),
                        ...actions,
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  sliver: SliverList.list(
                    children: [
                      for (final child in children)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: child,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.color = ocean, this.icon});
  final String label;
  final Color color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}

class Crest extends StatelessWidget {
  const Crest(this.name, {super.key, this.size = 48, this.color = ocean});
  final String name;
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    padding: const EdgeInsets.all(5),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .85),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white),
    ),
    child: Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        initials(name),
        style: TextStyle(
          fontFamily: 'Inter',
          color: Colors.white,
          fontSize: size * .25,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        ?trailing,
      ],
    ),
  );
}

class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.light = false,
  });
  final List<String> items;
  final String value;
  final ValueChanged<String> onChanged;
  final bool light;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(item),
              selected: item == value,
              onSelected: (_) => onChanged(item),
              showCheckmark: false,
              color: WidgetStatePropertyAll(
                item == value
                    ? (light ? Colors.white : ocean)
                    : (light
                          ? const Color(0xFF247EA3)
                          : const Color(0xFFEDF5FA)),
              ),
              selectedColor: light ? Colors.white : ocean,
              backgroundColor: Colors.white.withValues(alpha: light ? .18 : .5),
              side: BorderSide(color: Colors.white.withValues(alpha: .5)),
              labelStyle: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: item == value
                    ? (light ? ocean : Colors.white)
                    : (light ? Colors.white : muted),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
          ),
      ],
    ),
  );
}

class MatchCard extends StatelessWidget {
  const MatchCard(this.fixture, {super.key, this.onTap});
  final Fixture fixture;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    semanticLabel: '${fixture.home} versus ${fixture.away}, ${fixture.status}',
    child: GlassCard(
      child: Column(
        children: [
          Row(
            children: [
              Tag(
                fixture.status == 'Live'
                    ? '● LIVE'
                    : fixture.status.toUpperCase(),
                color: fixture.status == 'Live'
                    ? const Color(0xFFBE3450)
                    : ocean,
              ),
              const Spacer(),
              Text(fixture.sport, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: _team(fixture.home, 'Home', ocean)),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .8),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    children: [
                      FittedBox(
                        child: Text(
                          fixture.status == 'Upcoming'
                              ? fixture.time
                              : '${fixture.homeScore} – ${fixture.awayScore}',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            color: ink,
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        fixture.status == 'Upcoming'
                            ? 'PKT'
                            : fixture.status == 'Live'
                            ? 'IN PROGRESS'
                            : 'FINAL',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 8,
                          letterSpacing: 1,
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _team(fixture.away, 'Away', const Color(0xFFA86C2E)),
              ),
            ],
          ),
          const Divider(),
          Row(
            children: [
              const Icon(Icons.sports, size: 16, color: ocean),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Alpha ${fixture.sport} League',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    color: muted,
                  ),
                ),
              ),
              if (onTap != null) const Flexible(child: Tag('Match detail →')),
            ],
          ),
        ],
      ),
    ),
  );
  Widget _team(String name, String label, Color color) => Column(
    children: [
      Crest(name, color: color),
      const SizedBox(height: 8),
      Text(
        name,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        label,
        style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: muted),
      ),
    ],
  );
}

void openPage(BuildContext context, Widget page) =>
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
void notice(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class DetailRow extends StatelessWidget {
  const DetailRow(this.label, this.value, {super.key, this.bold = false});
  final String label, value;
  final bool bold;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              color: muted,
              fontSize: 12,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontFamily: 'Inter',
              color: ink,
              fontSize: bold ? 16 : 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

class EmptyCard extends StatelessWidget {
  const EmptyCard(this.title, this.message, {super.key});
  final String title, message;
  @override
  Widget build(BuildContext context) => GlassCard(
    child: Column(
      children: [
        const Icon(Icons.event_available_outlined, size: 40, color: ocean),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
      ],
    ),
  );
}
