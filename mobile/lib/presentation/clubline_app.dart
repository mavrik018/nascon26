import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/deep_links.dart';
import '../core/format.dart';
import 'club_screens.dart';
import 'guest_screens.dart';
import 'league_screens.dart';
import 'ocean_widgets.dart';
import 'onboarding_screens.dart';
import 'profile_screens.dart';
import 'shop_screens.dart';

/// App root: session gate (onboarding -> sign-in -> tabs), global snackbars and the tenant-branded theme.
class ClublineApp extends StatefulWidget {
  const ClublineApp({super.key, required this.state});
  final AppState state;

  @override
  State<ClublineApp> createState() => _ClublineAppState();
}

class _ClublineAppState extends State<ClublineApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<String>? _messages;
  StreamSubscription<DeepLink>? _links;
  String? _lastUser;

  @override
  void initState() {
    super.initState();
    _links = DeepLinks.links.listen(_openLink);
    _messages = widget.state.messages.listen((m) {
      final messenger = _messengerKey.currentState;
      if (messenger != null) toastOn(messenger, m, kind: m.contains('rejected') ? ToastKind.error : ToastKind.success);
    });
    widget.state.addListener(_onState);
  }

  void _onState() {
    final user = widget.state.user?.userId;
    if (user != _lastUser) {
      _lastUser = user;
      _navigatorKey.currentState?.popUntil((r) => r.isFirst); // login/logout: drop pushed screens
    }
  }

  /// nascon:// links open their screen on top of whatever is showing (sign-in included): read-only as guest.
  Future<void> _openLink(DeepLink link) async {
    final state = widget.state;
    if (!state.ready) {
      final ready = Completer<void>();
      void check() {
        if (state.ready && !ready.isCompleted) ready.complete();
      }
      state.addListener(check);
      await ready.future;
      state.removeListener(check);
    }
    final Widget page;
    switch (link.kind) {
      case DeepLinkKind.match:
        page = GuestMatchLivePage(state: state, matchId: link.id);
      case DeepLinkKind.costream:
        page = CoStreamPage(state: state, sessionId: link.id);
      case DeepLinkKind.entity:
        return;
    }
    // After the frame that applied `ready` (and any session-change popUntil in _onState).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => page));
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    _messages?.cancel();
    _links?.cancel();
    widget.state.removeListener(_onState);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScope(
    state: widget.state,
    child: ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final state = widget.state;
        return MaterialApp(
          title: state.tenant?.name ?? 'Clubline',
          debugShowCheckedModeBanner: false,
          theme: oceanTheme(primary: parseHexColor(state.tenant?.primaryColor) ?? ocean),
          navigatorKey: _navigatorKey,
          scaffoldMessengerKey: _messengerKey,
          home: !state.ready
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : !state.onboardingSeen && state.session == null
              ? OnboardingPage(state: state)
              : state.session == null
              ? SignInPage(state: state)
              : ClublineShell(key: ValueKey(state.user?.userId), state: state),
        );
      },
    ),
  );
}

class ClublineShell extends StatefulWidget {
  const ClublineShell({super.key, required this.state});
  final AppState state;

  @override
  State<ClublineShell> createState() => _ClublineShellState();
}

class _ClublineShellState extends State<ClublineShell> with SingleTickerProviderStateMixin {
  int index = 0;
  // Tab switch: the new tab fades and lifts in (state of every tab is kept by the IndexedStack).
  late final AnimationController _tab = AnimationController(vsync: this, duration: Motion.enter, value: 1);

  void _select(int value) {
    if (value == index) return;
    HapticFeedback.selectionClick();
    setState(() => index = value);
    if (!Motion.reduced(context)) _tab.forward(from: 0);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.cart]),
      builder: (context, _) => PopScope(
        canPop: index == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _select(0);
        },
        child: OceanBackground(
          child: Scaffold(
            // Spec 8.2 status indicator: every page header (OceanPage) shows SyncDot.
            body: AnimatedBuilder(
              animation: _tab,
              builder: (context, child) {
                final t = Motion.curve.transform(_tab.value);
                return Opacity(
                  opacity: .35 + .65 * t,
                  child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: child),
                );
              },
              child: IndexedStack(
                index: index,
                children: [
                  FixturesPage(state: state),
                  StandingsPage(state: state),
                  ClubPage(state: state),
                  ShopPage(state: state),
                  ProfilePage(state: state),
                ],
              ),
            ),
            bottomNavigationBar: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFE8F3F9).withValues(alpha: .95),
                border: const Border(top: BorderSide(color: Colors.white)),
              ),
              child: NavigationBar(
                height: 72,
                backgroundColor: Colors.transparent,
                elevation: 0,
                indicatorColor: ocean.withValues(alpha: .12),
                selectedIndex: index,
                onDestinationSelected: _select,
                labelTextStyle: WidgetStateProperty.resolveWith(
                  (states) => TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    color: states.contains(WidgetState.selected) ? ocean : muted,
                    fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                destinations: [
                  const NavigationDestination(
                    icon: Icon(Icons.calendar_month_outlined),
                    selectedIcon: Icon(Icons.calendar_month, color: ocean),
                    label: 'Fixtures',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.format_list_numbered),
                    selectedIcon: Icon(Icons.format_list_numbered, color: ocean),
                    label: 'Standings',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.shield_outlined),
                    selectedIcon: Icon(Icons.shield, color: ocean),
                    label: 'Club',
                  ),
                  NavigationDestination(
                    icon: Badge(
                      isLabelVisible: state.cart.count > 0,
                      label: Text('${state.cart.count}'),
                      child: const Icon(Icons.storefront_outlined),
                    ),
                    selectedIcon: const Icon(Icons.storefront, color: ocean),
                    label: 'Store',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    selectedIcon: Icon(Icons.person, color: ocean),
                    label: 'Profile',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
