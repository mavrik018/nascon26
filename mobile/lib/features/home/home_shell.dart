import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../club/club_screen.dart';
import '../fixtures/fixtures_screen.dart';
import '../profile/profile_screen.dart';
import '../standings/standings_screen.dart';
import '../store/store_screen.dart';

/// Role-aware home: bottom navigation between the main areas.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final _visited = <int>{0};

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final user = state.user;
    final ownClub = user?.clubId != null && user!.clubId!.isNotEmpty;
    final pending = state.pending.length;
    final tabs = <(Widget, NavigationDestination)>[
      (
        const FixturesScreen(),
        const NavigationDestination(
          icon: Icon(Icons.sports_soccer_outlined),
          selectedIcon: Icon(Icons.sports_soccer),
          label: 'Fixtures',
        ),
      ),
      (
        const StandingsScreen(),
        const NavigationDestination(
          icon: Icon(Icons.leaderboard_outlined),
          selectedIcon: Icon(Icons.leaderboard),
          label: 'Standings',
        ),
      ),
      (
        const StoreScreen(),
        const NavigationDestination(
          icon: Icon(Icons.storefront_outlined),
          selectedIcon: Icon(Icons.storefront),
          label: 'Store',
        ),
      ),
      (
        const ClubTab(),
        NavigationDestination(
          icon: const Icon(Icons.shield_outlined),
          selectedIcon: const Icon(Icons.shield),
          label: ownClub ? 'My club' : 'Clubs',
        ),
      ),
      (
        const ProfileScreen(),
        NavigationDestination(
          icon: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.person_outline)),
          selectedIcon: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.person)),
          label: 'Profile',
          tooltip: pending > 0 ? 'Profile and sync, $pending pending' : 'Profile and sync',
        ),
      ),
    ];
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _index = 0);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [for (var i = 0; i < tabs.length; i++) _visited.contains(i) ? tabs[i].$1 : const SizedBox.shrink()],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) => setState(() {
            _index = i;
            _visited.add(i);
          }),
          destinations: [for (final t in tabs) t.$2],
        ),
      ),
    );
  }
}
