import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import 'ios_ui.dart' show Motion;
import 'ocean_widgets.dart' show ink, muted;

/// Four first-launch onboarding screens shown only on a new app download.
/// Visual design takes direct inspiration from the three reference mocks:
/// 1. Midnight navy + flowing sky/coral waves, oversized "Club Line" typography & soccer ball hero
/// 2. Dual-tone navy/crimson "Starting Lineup" tactical pitch with interactive 4-2-3-1 / 4-4-2 formation
/// 3. Pearl + dark midnight "Heat map Results" & "Covered 99.42%" 3D isometric pitch telemetry card
/// 4. Diagonal tri-tone Club Store showcase with 3D striped jersey card & interactive size selector
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.state, this.onFinish});
  final AppState state;
  final VoidCallback? onFinish;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _controller = PageController();
  int _index = 0;
  String _formation = '4-2-3-1';
  String _selectedSize = 'L';
  String _metricTab = 'Avg. Pace';

  static const int _pageCount = 4;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    HapticFeedback.mediumImpact();
    await widget.state.completeOnboarding();
    widget.onFinish?.call();
  }

  void _next() {
    HapticFeedback.selectionClick();
    if (_index < _pageCount - 1) {
      _controller.nextPage(duration: Motion.enter, curve: Motion.curve);
    } else {
      _complete();
    }
  }

  void _goTo(int page) {
    HapticFeedback.selectionClick();
    _controller.animateToPage(page, duration: Motion.enter, curve: Motion.curve);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('onboarding-page'),
      backgroundColor: const Color(0xFF060E24),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Dynamic full-bleed background that morphs per slide
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            child: _buildSlideBackdrop(_index),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  children: [
                    // Top header bar: brand pill + Skip action
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 16, 4),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .14),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: Colors.white.withValues(alpha: .28)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.sports_soccer, size: 14, color: Colors.white),
                                const SizedBox(width: 6),
                                Text(
                                  'CLUBLINE · ${_index + 1}/$_pageCount',
                                  style: const TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.2,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            key: const Key('onboarding-skip'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              minimumSize: const Size(64, 40),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                              backgroundColor: Colors.black.withValues(alpha: .22),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                            ),
                            onPressed: _complete,
                            child: const Text(
                              'Skip',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Main swipeable onboarding slides
                    Expanded(
                      child: PageView(
                        controller: _controller,
                        onPageChanged: (i) {
                          HapticFeedback.selectionClick();
                          setState(() => _index = i);
                        },
                        children: [
                          _SlideFrame(child: _buildDreamJourneySlide()),
                          _SlideFrame(child: _buildStartingLineupSlide()),
                          _SlideFrame(child: _buildHeatMapTelemetrySlide()),
                          _SlideFrame(child: _buildClubKitStoreSlide()),
                        ],
                      ),
                    ),
                    // Bottom navigation bar: interactive dots + Next / Become a Player CTA
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
                      child: Row(
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < _pageCount; i++)
                                GestureDetector(
                                  onTap: () => _goTo(i),
                                  behavior: HitTestBehavior.opaque,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 240),
                                      curve: Curves.easeOutCubic,
                                      width: i == _index ? 26 : 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: i == _index
                                            ? Colors.white
                                            : Colors.white.withValues(alpha: .35),
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: FilledButton(
                                  key: Key(_index == _pageCount - 1 ? 'onboarding-start' : 'onboarding-next'),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _index == _pageCount - 1
                                        ? const Color(0xFF0051FF)
                                        : Colors.white,
                                    foregroundColor: _index == _pageCount - 1
                                        ? Colors.white
                                        : const Color(0xFF07132C),
                                    minimumSize: const Size(136, 48),
                                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                                    elevation: 4,
                                    shadowColor: Colors.black.withValues(alpha: .35),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                                  ),
                                  onPressed: _next,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _index == _pageCount - 1 ? 'Become a Player' : 'Next',
                                        style: const TextStyle(
                                          fontFamily: 'Inter',
                                          fontSize: 13,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        _index == _pageCount - 1
                                            ? CupertinoIcons.check_mark_circled_solid
                                            : CupertinoIcons.arrow_right,
                                        size: 16,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlideBackdrop(int index) {
    switch (index) {
      case 0:
        return CustomPaint(
          key: const ValueKey('bg-0'),
          painter: _WaveSplashBackdropPainter(),
          child: const SizedBox.expand(),
        );
      case 1:
        return Container(
          key: const ValueKey('bg-1'),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF071B42),
                Color(0xFF1A254B),
                Color(0xFF6B1E29),
                Color(0xFF8C1D24),
              ],
              stops: [0.0, 0.42, 0.78, 1.0],
            ),
          ),
        );
      case 2:
        return Container(
          key: const ValueKey('bg-2'),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF0D2847),
                Color(0xFF08152C),
                Color(0xFF050B1A),
              ],
            ),
          ),
        );
      default:
        return CustomPaint(
          key: const ValueKey('bg-3'),
          painter: _DiagonalKitBackdropPainter(),
          child: const SizedBox.expand(),
        );
    }
  }

  // ===========================================================================
  // SLIDE 1: Hero Splash ("Foot Ball / Start Your Dream Journey!")
  // ===========================================================================
  Widget _buildDreamJourneySlide() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Hero artwork card inspired by Reference Image 2 (Left)
        Container(
          height: 310,
          decoration: BoxDecoration(
            color: const Color(0xFF050C24),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: .18), width: 1.2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .42),
                blurRadius: 28,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Organic sky-blue & coral waves inside the hero card
              Positioned.fill(
                child: CustomPaint(painter: _HeroCardWavePainter()),
              ),
              // Oversized "Club / Line" display typography on top-right
              Positioned(
                top: 28,
                right: 22,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text(
                      'Club',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 46,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 0.95,
                        letterSpacing: -2.0,
                      ),
                    ),
                    const Text(
                      'Line',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 38,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFD6F0FF),
                        height: 1.0,
                        letterSpacing: -1.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0051FF),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '4 SPORTS · LIVE',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Giant graphic soccer ball on the left edge
              Positioned(
                left: -34,
                top: 68,
                width: 196,
                height: 196,
                child: CustomPaint(painter: _SoccerBallPainter()),
              ),
              // Dynamic kicking athlete silhouette in center-right
              Positioned(
                right: 54,
                bottom: 54,
                width: 104,
                height: 118,
                child: CustomPaint(painter: _PlayerKickSilhouettePainter()),
              ),
              // Bottom sport badge strip inside the card
              Positioned(
                left: 12,
                right: 12,
                bottom: 14,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final (icon, label) in const [
                        (Icons.sports_soccer, 'Football'),
                        (Icons.sports_esports, 'Esports'),
                        (Icons.sports_basketball, 'Basketball'),
                        (Icons.sports_cricket, 'Cricket'),
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: Colors.white.withValues(alpha: .22)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(icon, size: 12, color: const Color(0xFF66CCFF)),
                                const SizedBox(width: 4),
                                Text(
                                  label,
                                  style: const TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Start Your Dream Journey!',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 25,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: -0.7,
          ),
        ),
        const SizedBox(height: 6),
        RichText(
          textAlign: TextAlign.center,
          text: const TextSpan(
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: Color(0xFFB8CDE0),
              height: 1.45,
            ),
            children: [
              TextSpan(text: 'All-in-one operations for '),
              TextSpan(
                text: 'Leagues, Clubs & Players',
                style: TextStyle(
                  color: Color(0xFFFFD54F),
                  fontWeight: FontWeight.w800,
                ),
              ),
              TextSpan(text: ' — from live kick-off to final standings.'),
            ],
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // SLIDE 2: Tactical Pitch & Starting Lineup (Inspired by Reference Image 1)
  // ===========================================================================
  Widget _buildStartingLineupSlide() {
    final is4231 = _formation == '4-2-3-1';
    final players = is4231 ? _lineup4231 : _lineup442;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Frosted glass tactical pitch container
        ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: Colors.white.withValues(alpha: .24)),
              ),
              child: Column(
                children: [
                  // Top match status row ("Starting Soon")
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _miniFlagCircle(const Color(0xFF1E40AF), 'AW'),
                      const Column(
                        children: [
                          Text(
                            'Starting Soon',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            'Starting Lineup',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 10,
                              color: Color(0xFFD0DCE8),
                            ),
                          ),
                        ],
                      ),
                      _miniFlagCircle(const Color(0xFFB91C1C), 'RF'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Segmented formation toggle pill (4-2-3-1 vs 4-4-2)
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .26),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      children: [
                        for (final f in const ['4-2-3-1', '4-4-2'])
                          Expanded(
                            child: GestureDetector(
                              key: Key('formation-$f'),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _formation = f);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                decoration: BoxDecoration(
                                  color: _formation == f
                                      ? Colors.white.withValues(alpha: .22)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.shield,
                                      size: 12,
                                      color: f == '4-2-3-1'
                                          ? const Color(0xFF60A5FA)
                                          : const Color(0xFFF87171),
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      f,
                                      style: TextStyle(
                                        fontFamily: 'Inter',
                                        fontSize: 11,
                                        fontWeight: _formation == f ? FontWeight.w800 : FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Pitch diagram with 11 animated player nodes
                  SizedBox(
                    height: 205,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final w = constraints.maxWidth;
                        final h = constraints.maxHeight;
                        return Stack(
                          children: [
                            Positioned.fill(
                              child: CustomPaint(painter: _TacticalPitchPainter()),
                            ),
                            for (final p in players)
                              AnimatedPositioned(
                                key: ValueKey(p.number),
                                duration: const Duration(milliseconds: 320),
                                curve: Curves.easeOutCubic,
                                left: (p.x * w) - 28,
                                top: (p.y * h) - 18,
                                width: 56,
                                child: _PlayerNodeWidget(player: p),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Bench / Subs preview strip
                  Row(
                    children: [
                      Text(
                        'Bench',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: .65),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          '4  C. Roldan   ·   18  M. Arfsten',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      Text(
                        'Subs',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: .65),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Tactical Lineups & Squads',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Tap 4-2-3-1 or 4-4-2 above — manage club rosters, transfers, loans and matchday squads with a full audit trail.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 12.5,
            color: Color(0xFFE2D4D8),
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _miniFlagCircle(Color color, String code) => Container(
    width: 28,
    height: 28,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 1.5),
    ),
    child: Text(
      code,
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 9,
        fontWeight: FontWeight.w800,
        color: Colors.white,
      ),
    ),
  );

  // ===========================================================================
  // SLIDE 3: Heat Map & 3D Pitch Telemetry (Inspired by Reference Image 2 Right)
  // ===========================================================================
  Widget _buildHeatMapTelemetrySlide() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Split light-top + dark-bottom card inspired by Reference Image 2 (Right)
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF3F6F9),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .38),
                blurRadius: 26,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // Pearl-white top section: Distance / Avg. Pace pills + 4 squircle icons
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final tab in const ['Distance', 'Avg. Pace'])
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _metricTab = tab);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                                decoration: BoxDecoration(
                                  color: _metricTab == tab
                                      ? const Color(0xFF060E24)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: _metricTab == tab
                                        ? const Color(0xFF060E24)
                                        : const Color(0xFFC5D1DD),
                                  ),
                                ),
                                child: Text(
                                  tab,
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: _metricTab == tab ? Colors.white : ink,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Four organic squircle feature icons: Map, Goals, Schedules, Sync
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        for (final (icon, label, active) in const [
                          (Icons.map_outlined, 'Map', false),
                          (Icons.emoji_events, 'Goals', true),
                          (Icons.schedule, 'Schedules', true),
                          (Icons.cloud_sync, 'Sync', true),
                        ])
                          Column(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: active ? const Color(0xFF060E24) : const Color(0xFFE1E8F0),
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(14),
                                    topRight: Radius.circular(18),
                                    bottomLeft: Radius.circular(16),
                                    bottomRight: Radius.circular(12),
                                  ),
                                ),
                                child: Icon(
                                  icon,
                                  size: 18,
                                  color: active ? Colors.white : muted,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                label,
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: ink,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Heat map Results',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: ink,
                                ),
                              ),
                              Text(
                                'LIVE MATCH TELEMETRY · SSE STREAM',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w700,
                                  color: muted,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF060E24),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'See More',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Dark midnight bottom telemetry sheet ("Covered 99.42% ▲" + 3D pitch)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: const BoxDecoration(
                  color: Color(0xFF060E24),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Covered',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                _metricTab == 'Distance'
                                    ? '10 out of 32 km · 100% offline-ready'
                                    : 'Live events synced · H2H tables active',
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 10,
                                  color: Color(0xFF9FB3C8),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF04438),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.trending_up, size: 12, color: Colors.white),
                              SizedBox(width: 4),
                              Text(
                                '99.42% ▲',
                                style: TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 3D Isometric Pitch with goalposts & heat zones
                    SizedBox(
                      height: 86,
                      width: double.infinity,
                      child: CustomPaint(painter: _IsometricPitchPainter()),
                    ),
                    const SizedBox(height: 8),
                    // Three stat pills at bottom of dark card
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: _telemetryStat(Icons.local_fire_department, '74 cal', false),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: _telemetryStat(Icons.check, '2/4 Won', true),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: _telemetryStat(Icons.timer_outlined, '60 min', true),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Live Analytics & Offline Sync',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Real-time score streams, automatic head-to-head tie-breaks, and a durable offline queue that syncs when you reconnect.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 12.5,
            color: Color(0xFFB8CDE0),
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _telemetryStat(IconData icon, String label, bool bright) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: bright ? Colors.white : Colors.white.withValues(alpha: .16),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 14,
          color: bright ? const Color(0xFF060E24) : Colors.white,
        ),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    ],
  );

  // ===========================================================================
  // SLIDE 4: Club Store & 3D Jersey Showcase (Inspired by Reference Image 3)
  // ===========================================================================
  Widget _buildClubKitStoreSlide() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Floating dark slate-navy 3D kit card from Reference Image 3
        Container(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF243B55), Color(0xFF142334)],
            ),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: .22)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .40),
                blurRadius: 26,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            children: [
              // Red top ribbon tab + circular Club Crest
              Container(
                width: 44,
                height: 28,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFFD91E36),
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                ),
                child: const Icon(Icons.bolt, size: 18, color: Colors.white),
              ),
              const SizedBox(height: 6),
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF0F2942),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: const Icon(Icons.shield, size: 20, color: Color(0xFF60A5FA)),
              ),
              const SizedBox(height: 3),
              const Text(
                'A L P H A   F C',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                  color: Color(0xFF9FB3C8),
                ),
              ),
              // 3D Club Jersey custom illustration with side pills
              SizedBox(
                width: double.infinity,
                height: 138,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      left: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'Away',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white70),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD91E36).withValues(alpha: .85),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'Home',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 140,
                      height: 132,
                      child: CustomPaint(painter: _ClubJerseyPainter()),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              // Price + Interactive Size Selector Pill (S M L XL XXL)
              Row(
                children: [
                  const Text(
                    '£220',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E1B2A),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          for (final size in const ['S', 'M', 'L', 'XL', 'XXL'])
                            GestureDetector(
                              key: Key('kit-size-$size'),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _selectedSize = size);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: 26,
                                height: 26,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: _selectedSize == size
                                      ? const Color(0xFF8FA8C6)
                                      : Colors.transparent,
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  size,
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: _selectedSize == size
                                        ? const Color(0xFF0E1B2A)
                                        : const Color(0xFF9FB3C8),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Popular Club Kits mini row (Atletico, Roma, City)
              Row(
                children: [
                  for (final (club, price, tint) in const [
                    ('Atletico', '£200', Color(0xFFB91C1C)),
                    ('Roma', '£210', Color(0xFF7F1D1D)),
                    ('City', '£220', Color(0xFF0284C7)),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white.withValues(alpha: .16)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '$club · $price',
                                    maxLines: 1,
                                    style: const TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Official Club Store & Merch',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Shop authentic club kits, pick your size with atomic stock reservation, and download signed PDF receipts.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 12.5,
            color: Colors.white,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// Keeps every onboarding slide overflow-free on both tall phones and compact landscape screens.
class _SlideFrame extends StatelessWidget {
  const _SlideFrame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: math.max(0, constraints.maxHeight - 8)),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [child],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Formation Data & Widgets for Slide 2
// =============================================================================

class _FormationPlayer {
  const _FormationPlayer(this.name, this.number, this.x, this.y, {this.isGk = false});
  final String name;
  final String number;
  final double x;
  final double y;
  final bool isGk;
}

const _lineup4231 = <_FormationPlayer>[
  _FormationPlayer('F. Balogun', '20', 0.50, 0.14),
  _FormationPlayer('C. Pulisic', '10', 0.24, 0.34),
  _FormationPlayer('W. McKennie', '8', 0.50, 0.34),
  _FormationPlayer('M. Tillman', '17', 0.76, 0.34),
  _FormationPlayer('T. Tessmann', '11', 0.37, 0.54),
  _FormationPlayer('J. Cardoso', '15', 0.63, 0.54),
  _FormationPlayer('A. Robinson', '3', 0.16, 0.73),
  _FormationPlayer('T. Ream', '13', 0.38, 0.73),
  _FormationPlayer('M. McKenzie', '22', 0.62, 0.73),
  _FormationPlayer('T. Weah', '21', 0.84, 0.73),
  _FormationPlayer('M. Freese', 'GK · 1', 0.50, 0.90, isGk: true),
];

const _lineup442 = <_FormationPlayer>[
  _FormationPlayer('F. Balogun', '20', 0.36, 0.16),
  _FormationPlayer('C. Pulisic', '10', 0.64, 0.16),
  _FormationPlayer('M. Tillman', '17', 0.18, 0.44),
  _FormationPlayer('W. McKennie', '8', 0.39, 0.44),
  _FormationPlayer('J. Cardoso', '15', 0.61, 0.44),
  _FormationPlayer('T. Tessmann', '11', 0.82, 0.44),
  _FormationPlayer('A. Robinson', '3', 0.16, 0.72),
  _FormationPlayer('T. Ream', '13', 0.38, 0.72),
  _FormationPlayer('M. McKenzie', '22', 0.62, 0.72),
  _FormationPlayer('T. Weah', '21', 0.84, 0.72),
  _FormationPlayer('M. Freese', 'GK · 1', 0.50, 0.90, isGk: true),
];

class _PlayerNodeWidget extends StatelessWidget {
  const _PlayerNodeWidget({required this.player});
  final _FormationPlayer player;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: player.isGk ? const Color(0xFF065F46) : const Color(0xFF0F294E),
            shape: BoxShape.circle,
            border: Border.all(
              color: player.isGk ? const Color(0xFF34D399) : const Color(0xFF60A5FA),
              width: 1.5,
            ),
          ),
          child: const Icon(Icons.person, size: 12, color: Colors.white),
        ),
        const SizedBox(height: 1),
        Text(
          player.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 7.5,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            height: 1.1,
          ),
        ),
        Text(
          player.number,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 7,
            fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: .72),
            height: 1.0,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Custom Vector Painters
// =============================================================================

/// Slide 1 full-screen wave background
class _WaveSplashBackdropPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF050C24);
    canvas.drawRect(Offset.zero & size, bg);

    final topWave = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height * 0.16)
      ..cubicTo(
        size.width * 0.72,
        size.height * 0.24,
        size.width * 0.32,
        size.height * 0.08,
        0,
        size.height * 0.20,
      )
      ..close();
    canvas.drawPath(
      topWave,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFF0E4B80), Color(0xFF0077B6)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Organic waves + coral blob inside Slide 1's hero card (Reference Image 2 Left)
class _HeroCardWavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Top white/sky-blue wave ribbon
    final skyWave = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width * 0.88, 0)
      ..cubicTo(
        size.width * 0.65,
        size.height * 0.22,
        size.width * 0.30,
        size.height * 0.04,
        0,
        size.height * 0.20,
      )
      ..close();
    canvas.drawPath(skyWave, Paint()..color = const Color(0xFF64C7FF));

    // Top-left white highlight curve
    final whiteCap = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width * 0.56, 0)
      ..cubicTo(
        size.width * 0.42,
        size.height * 0.11,
        size.width * 0.18,
        size.height * 0.02,
        0,
        size.height * 0.11,
      )
      ..close();
    canvas.drawPath(whiteCap, Paint()..color = Colors.white);

    // Signature coral-red organic blob on the right side
    final coralBlob = Path()
      ..moveTo(size.width, size.height * 0.46)
      ..cubicTo(
        size.width * 0.78,
        size.height * 0.48,
        size.width * 0.80,
        size.height * 0.78,
        size.width,
        size.height * 0.88,
      )
      ..close();
    canvas.drawPath(coralBlob, Paint()..color = const Color(0xFFF04438));

    // Bottom sky-blue wave ribbon
    final bottomWave = Path()
      ..moveTo(size.width * 0.28, size.height)
      ..cubicTo(
        size.width * 0.48,
        size.height * 0.88,
        size.width * 0.76,
        size.height * 0.96,
        size.width,
        size.height * 0.85,
      )
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(bottomWave, Paint()..color = const Color(0xFF64C7FF).withValues(alpha: .75));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Bold vector football graphic (Reference Image 2 Left)
class _SoccerBallPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.5);
    final radius = size.width * 0.45;

    // Outer white sphere
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.2, -0.3),
          colors: const [Colors.white, Color(0xFFDCE6F2)],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );

    final darkPanel = Paint()
      ..color = const Color(0xFF07122B)
      ..style = PaintingStyle.fill;
    final seam = Paint()
      ..color = const Color(0xFF07122B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    // Central pentagon
    final centerPoly = _regularPolygon(center, radius * 0.30, 5, -math.pi / 2);
    canvas.drawPath(centerPoly, darkPanel);

    // Surrounding pentagons + connecting seams
    for (var i = 0; i < 5; i++) {
      final angle = -math.pi / 2 + i * (2 * math.pi / 5);
      final p1 = Offset(
        center.dx + math.cos(angle) * radius * 0.29,
        center.dy + math.sin(angle) * radius * 0.29,
      );
      final p2 = Offset(
        center.dx + math.cos(angle) * radius * 0.68,
        center.dy + math.sin(angle) * radius * 0.68,
      );
      canvas.drawLine(p1, p2, seam);

      final outerCenter = Offset(
        center.dx + math.cos(angle) * radius * 0.82,
        center.dy + math.sin(angle) * radius * 0.82,
      );
      canvas.save();
      canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: radius)));
      canvas.drawPath(_regularPolygon(outerCenter, radius * 0.25, 5, angle + math.pi), darkPanel);
      canvas.restore();
    }

    canvas.drawCircle(center, radius, seam);
  }

  Path _regularPolygon(Offset center, double r, int sides, double startAngle) {
    final path = Path();
    for (var i = 0; i < sides; i++) {
      final a = startAngle + (2 * math.pi * i / sides);
      final pt = Offset(center.dx + r * math.cos(a), center.dy + r * math.sin(a));
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Dynamic white athlete silhouette kicking (Reference Image 2 Left)
class _PlayerKickSilhouettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final w = size.width;
    final h = size.height;

    // Head
    canvas.drawCircle(Offset(w * 0.58, h * 0.16), w * 0.085, paint);

    // Torso & kicking legs
    final body = Path()
      ..moveTo(w * 0.50, h * 0.26)
      ..quadraticBezierTo(w * 0.68, h * 0.28, w * 0.72, h * 0.46)
      // Right arm extended back
      ..lineTo(w * 0.90, h * 0.42)
      ..lineTo(w * 0.88, h * 0.49)
      ..lineTo(w * 0.68, h * 0.52)
      // Planted right leg going down
      ..lineTo(w * 0.62, h * 0.92)
      ..lineTo(w * 0.51, h * 0.94)
      ..lineTo(w * 0.53, h * 0.62)
      // High kicking left leg going left-up
      ..lineTo(w * 0.12, h * 0.48)
      ..lineTo(w * 0.16, h * 0.38)
      ..lineTo(w * 0.48, h * 0.50)
      // Left arm forward
      ..lineTo(w * 0.30, h * 0.36)
      ..lineTo(w * 0.35, h * 0.29)
      ..close();
    canvas.drawPath(body, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Tactical pitch markings for Slide 2 (Reference Image 1)
class _TacticalPitchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.white.withValues(alpha: .22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final rect = Offset.zero & size;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(14)), line);

    // Halfway line & center circle
    final midY = size.height * 0.5;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), line);
    canvas.drawCircle(Offset(size.width * 0.5, midY), 24, line);

    // Top penalty box & 6-yard box
    canvas.drawRect(
      Rect.fromCenter(center: Offset(size.width * 0.5, 18), width: size.width * 0.48, height: 36),
      line,
    );
    canvas.drawRect(
      Rect.fromCenter(center: Offset(size.width * 0.5, 8), width: size.width * 0.24, height: 16),
      line,
    );

    // Bottom penalty box & 6-yard box
    canvas.drawRect(
      Rect.fromCenter(center: Offset(size.width * 0.5, size.height - 18), width: size.width * 0.48, height: 36),
      line,
    );
    canvas.drawRect(
      Rect.fromCenter(center: Offset(size.width * 0.5, size.height - 8), width: size.width * 0.24, height: 16),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 3D Isometric Pitch with goalposts & heat zones for Slide 3 (Reference Image 2 Right)
class _IsometricPitchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Perspective trapezoid corners
    final topL = Offset(w * 0.16, h * 0.14);
    final topR = Offset(w * 0.84, h * 0.14);
    final botR = Offset(w * 0.96, h * 0.88);
    final botL = Offset(w * 0.04, h * 0.88);

    final pitchPath = Path()
      ..moveTo(topL.dx, topL.dy)
      ..lineTo(topR.dx, topR.dy)
      ..lineTo(botR.dx, botR.dy)
      ..lineTo(botL.dx, botL.dy)
      ..close();

    // Pitch dark surface fill
    canvas.drawPath(
      pitchPath,
      Paint()..color = const Color(0xFF030816),
    );

    // Glowing heat-map blobs inside the 3D pitch
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.38, h * 0.52), width: w * 0.24, height: h * 0.34),
      Paint()
        ..color = const Color(0xFFF04438).withValues(alpha: .32)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.64, h * 0.48), width: w * 0.22, height: h * 0.30),
      Paint()
        ..color = const Color(0xFF38BDF8).withValues(alpha: .30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: .65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    canvas.drawPath(pitchPath, stroke);

    // Center line & perspective oval
    canvas.drawLine(Offset(w * 0.5, topL.dy), Offset(w * 0.5, botL.dy), stroke);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.5, h * 0.51), width: w * 0.16, height: h * 0.26),
      stroke,
    );

    // Left & right penalty boxes in perspective
    final leftBox = Path()
      ..moveTo(w * 0.12, h * 0.34)
      ..lineTo(w * 0.23, h * 0.34)
      ..lineTo(w * 0.20, h * 0.70)
      ..lineTo(w * 0.07, h * 0.70);
    canvas.drawPath(leftBox, stroke);

    final rightBox = Path()
      ..moveTo(w * 0.88, h * 0.34)
      ..lineTo(w * 0.77, h * 0.34)
      ..lineTo(w * 0.80, h * 0.70)
      ..lineTo(w * 0.93, h * 0.70);
    canvas.drawPath(rightBox, stroke);

    // 3D Goalposts on left and right ends
    final goalStroke = Paint()
      ..color = Colors.white.withValues(alpha: .85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final leftGoal = Path()
      ..moveTo(w * 0.08, h * 0.60)
      ..lineTo(w * 0.08, h * 0.38)
      ..lineTo(w * 0.11, h * 0.28)
      ..lineTo(w * 0.11, h * 0.46);
    canvas.drawPath(leftGoal, goalStroke);

    final rightGoal = Path()
      ..moveTo(w * 0.92, h * 0.60)
      ..lineTo(w * 0.92, h * 0.38)
      ..lineTo(w * 0.89, h * 0.28)
      ..lineTo(w * 0.89, h * 0.46);
    canvas.drawPath(rightGoal, goalStroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Diagonal tri-tone backdrop for Slide 4 (Reference Image 3 Left)
class _DiagonalKitBackdropPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Base slate-blue
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF7B94B2));

    // White diagonal center stripe
    final whiteStripe = Path()
      ..moveTo(size.width * 0.26, 0)
      ..lineTo(size.width * 0.68, 0)
      ..lineTo(size.width * 0.95, size.height)
      ..lineTo(size.width * 0.52, size.height)
      ..close();
    canvas.drawPath(whiteStripe, Paint()..color = const Color(0xFFEAF0F6).withValues(alpha: .28));

    // Vibrant crimson right section
    final redSection = Path()
      ..moveTo(size.width * 0.66, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width * 0.90, size.height)
      ..close();
    canvas.drawPath(redSection, Paint()..color = const Color(0xFFD91E36));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 3D Striped Club Jersey illustration for Slide 4 (Reference Image 3 Left)
class _ClubJerseyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final jersey = Path()
      // Left shoulder
      ..moveTo(w * 0.34, h * 0.08)
      ..lineTo(w * 0.14, h * 0.20)
      // Left sleeve outer
      ..lineTo(w * 0.04, h * 0.46)
      ..lineTo(w * 0.20, h * 0.52)
      // Left armpit to hem
      ..lineTo(w * 0.24, h * 0.38)
      ..lineTo(w * 0.24, h * 0.94)
      // Bottom hem
      ..quadraticBezierTo(w * 0.50, h * 0.98, w * 0.76, h * 0.94)
      // Right hem to armpit
      ..lineTo(w * 0.76, h * 0.38)
      ..lineTo(w * 0.80, h * 0.52)
      ..lineTo(w * 0.96, h * 0.46)
      // Right shoulder
      ..lineTo(w * 0.86, h * 0.20)
      ..lineTo(w * 0.66, h * 0.08)
      // V-neck collar
      ..lineTo(w * 0.50, h * 0.20)
      ..close();

    // Jersey shadow
    canvas.drawShadow(jersey, Colors.black.withValues(alpha: .55), 10, true);

    // Navy body gradient
    canvas.drawPath(
      jersey,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E3A5F), Color(0xFF0F2138)],
        ).createShader(Offset.zero & size),
    );

    // Clip to jersey shape to draw the iconic PSG-style center vertical crimson & white stripe
    canvas.save();
    canvas.clipPath(jersey);

    // White flanking pinstripes
    canvas.drawRect(
      Rect.fromLTWH(w * 0.42, 0, w * 0.16, h),
      Paint()..color = Colors.white.withValues(alpha: .90),
    );
    // Center crimson stripe
    canvas.drawRect(
      Rect.fromLTWH(w * 0.45, 0, w * 0.10, h),
      Paint()..color = const Color(0xFFB91C1C),
    );

    // Red sleeve cuffs
    final cuffPaint = Paint()
      ..color = const Color(0xFFD91E36)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5;
    canvas.drawLine(Offset(w * 0.04, h * 0.46), Offset(w * 0.20, h * 0.52), cuffPaint);
    canvas.drawLine(Offset(w * 0.80, h * 0.52), Offset(w * 0.96, h * 0.46), cuffPaint);
    canvas.restore();

    // Collar trim
    final collar = Path()
      ..moveTo(w * 0.34, h * 0.08)
      ..lineTo(w * 0.50, h * 0.20)
      ..lineTo(w * 0.66, h * 0.08);
    canvas.drawPath(
      collar,
      Paint()
        ..color = const Color(0xFFD91E36)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0,
    );

    // Chest crest & swoosh-style tick
    canvas.drawCircle(
      Offset(w * 0.63, h * 0.32),
      w * 0.055,
      Paint()..color = Colors.white.withValues(alpha: .9),
    );
    canvas.drawCircle(
      Offset(w * 0.63, h * 0.32),
      w * 0.035,
      Paint()..color = const Color(0xFF1E3A5F),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// =============================================================================
// Reusable In-App Widgets (Starting Lineup Tactical Card & Telemetry Card)
// =============================================================================

/// Interactive Starting Lineup & Tactical Formation Pitch Card (4-2-3-1 / 4-4-2)
/// used on Match Centre (`MatchPage`) and Club (`ClubPage`) screens.
class TacticalLineupCard extends StatefulWidget {
  const TacticalLineupCard({
    super.key,
    this.homeCode = 'AW',
    this.awayCode = 'RF',
    this.title = 'Starting Soon',
    this.subtitle = 'Starting Lineup',
  });

  final String homeCode;
  final String awayCode;
  final String title;
  final String subtitle;

  @override
  State<TacticalLineupCard> createState() => _TacticalLineupCardState();
}

class _TacticalLineupCardState extends State<TacticalLineupCard> {
  String _formation = '4-2-3-1';

  Widget _badge(Color color, String code) => Container(
    width: 30,
    height: 30,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 1.6),
      boxShadow: [
        BoxShadow(
          color: color.withValues(alpha: .40),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    ),
    child: Text(
      code,
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        color: Colors.white,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final players = _formation == '4-2-3-1' ? _lineup4231 : _lineup442;
    return Container(
      key: const Key('tactical-lineup-card'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF16223F),
            Color(0xFF282846),
            Color(0xFF4B243B),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: .28), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF040D1E).withValues(alpha: .34),
            blurRadius: 30,
            spreadRadius: 1,
            offset: const Offset(0, 16),
          ),
          BoxShadow(
            color: const Color(0xFF006D9F).withValues(alpha: .16),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _badge(const Color(0xFF1E40AF), widget.homeCode),
              Column(
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    widget.subtitle,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 10.5,
                      color: Color(0xFFD0DCE8),
                    ),
                  ),
                ],
              ),
              _badge(const Color(0xFFB91C1C), widget.awayCode),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .28),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: [
                for (final f in const ['4-2-3-1', '4-4-2'])
                  Expanded(
                    child: GestureDetector(
                      key: Key('inapp-formation-$f'),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _formation = f);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        decoration: BoxDecoration(
                          color: _formation == f
                              ? Colors.white.withValues(alpha: .22)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.shield,
                              size: 13,
                              color: f == '4-2-3-1'
                                  ? const Color(0xFF60A5FA)
                                  : const Color(0xFFF87171),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              f,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 11.5,
                                fontWeight: _formation == f ? FontWeight.w800 : FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 215,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;
                return Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _TacticalPitchPainter()),
                    ),
                    for (final p in players)
                      AnimatedPositioned(
                        key: ValueKey(p.number),
                        duration: const Duration(milliseconds: 320),
                        curve: Curves.easeOutCubic,
                        left: (p.x * w) - 28,
                        top: (p.y * h) - 18,
                        width: 56,
                        child: _PlayerNodeWidget(player: p),
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                'Bench',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: .68),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '4  C. Roldan   ·   18  M. Arfsten',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              Text(
                'Subs',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: .68),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Interactive Match Telemetry & 3D Isometric Pitch Coverage Card (`Covered 99.42% ▲`)
/// used on Match Centre and Club Stats screens.
class MatchTelemetryCard extends StatefulWidget {
  const MatchTelemetryCard({super.key});

  @override
  State<MatchTelemetryCard> createState() => _MatchTelemetryCardState();
}

class _MatchTelemetryCardState extends State<MatchTelemetryCard> {
  String _metricTab = 'Avg. Pace';

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('match-telemetry-card'),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6F9),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white, width: 1.4),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF040D1E).withValues(alpha: .28),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final tab in const ['Distance', 'Avg. Pace'])
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: GestureDetector(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setState(() => _metricTab = tab);
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: _metricTab == tab
                                    ? const Color(0xFF060E24)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: _metricTab == tab
                                      ? const Color(0xFF060E24)
                                      : const Color(0xFFC5D1DD),
                                ),
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  tab,
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: _metricTab == tab ? Colors.white : ink,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    for (final (icon, label, active) in const [
                      (Icons.map_outlined, 'Map', false),
                      (Icons.emoji_events, 'Goals', true),
                      (Icons.schedule, 'Schedules', true),
                      (Icons.cloud_sync, 'Sync', true),
                    ])
                      Flexible(
                        child: Column(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: active ? const Color(0xFF060E24) : const Color(0xFFE1E8F0),
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(14),
                                  topRight: Radius.circular(18),
                                  bottomLeft: Radius.circular(16),
                                  bottomRight: Radius.circular(12),
                                ),
                              ),
                              child: Icon(
                                icon,
                                size: 18,
                                color: active ? Colors.white : muted,
                              ),
                            ),
                            const SizedBox(height: 4),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                label,
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Heat map Results',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: ink,
                            ),
                          ),
                          Text(
                            'LIVE MATCH TELEMETRY · SSE STREAM',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 8.5,
                              fontWeight: FontWeight.w700,
                              color: muted,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF060E24),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'Live',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: const BoxDecoration(
              color: Color(0xFF060E24),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Covered',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            _metricTab == 'Distance'
                                ? '10 out of 32 km · 100% offline-ready'
                                : 'Live events synced · H2H tables active',
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 10,
                              color: Color(0xFF9FB3C8),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF04438).withValues(alpha: .16),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFFF04438).withValues(alpha: .45),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '99.42%',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 4),
                          Icon(
                            Icons.change_history,
                            size: 11,
                            color: Color(0xFFF04438),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 115,
                  width: double.infinity,
                  child: CustomPaint(painter: _IsometricPitchPainter()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

