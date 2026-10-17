import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../widgets/sync_banner.dart';
import 'club_screens.dart';
import 'league_screens.dart';
import 'ocean_widgets.dart';
import 'profile_screens.dart';
import 'shop_screens.dart';

/// App root: session gate (sign-in vs tabs), global snackbars, and the
/// always-visible Online / Offline / Syncing / pending indicator.
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
  String? _lastUser;

  @override
  void initState() {
    super.initState();
    _messages = widget.state.messages.listen((m) {
      _messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
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

  @override
  void dispose() {
    _messages?.cancel();
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
          theme: oceanTheme(),
          navigatorKey: _navigatorKey,
          scaffoldMessengerKey: _messengerKey,
          home: !state.ready
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
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

class _ClublineShellState extends State<ClublineShell> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.cart]),
      builder: (context, _) => PopScope(
        canPop: index == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => index = 0);
        },
        child: OceanBackground(
          child: Scaffold(
            body: Stack(
              children: [
                IndexedStack(
                  index: index,
                  children: [
                    FixturesPage(state: state),
                    StandingsPage(state: state),
                    ClubPage(state: state),
                    ShopPage(state: state),
                    ProfilePage(state: state),
                  ],
                ),
                // Spec 8.2: always-visible online / offline / syncing + pending indicator.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10,
                  child: Center(
                    child: SyncPill(
                      state: state,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => SyncPage(state: state)),
                      ),
                    ),
                  ),
                ),
              ],
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
                onDestinationSelected: (value) => setState(() => index = value),
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
