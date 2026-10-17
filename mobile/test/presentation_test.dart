import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:league_app/core/app_state.dart';
import 'package:league_app/core/local_store.dart';
import 'package:league_app/presentation/clubline_app.dart';

import 'fake_backend.dart';

/// The integrated app: session gate + five tabs backed by the (fake) API.
void main() {
  Future<AppState> boot(WidgetTester tester, {bool loggedIn = true}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tokens = MemoryTokenStore();
    if (loggedIn) {
      tokens.values['session'] = jsonEncode({
        'token': 'tok-1',
        'user': {
          'user_id': 'user-manager', 'email': 'manager@nascon.test', 'role': 'club_manager',
          'display_name': 'Club Manager', 'tenant_id': 'tenant-alpha', 'club_id': 'club-alpha-1',
        },
        'tenant': {'tenant_id': 'tenant-alpha', 'name': 'Alpha Sports', 'primary_color': '#1E40AF'},
      });
    }
    final state = AppState(store: MemoryLocalStore(), tokens: tokens, httpClient: FakeBackend().client,
        probeInterval: const Duration(hours: 1));
    await state.init();
    await tester.pumpWidget(ClublineApp(state: state));
    await tester.pump(const Duration(milliseconds: 300));
    return state;
  }

  testWidgets('signed out -> sign-in page, no tabs', (tester) async {
    final state = await boot(tester, loggedIn: false);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('signed in -> five tabs and the sync indicator', (tester) async {
    final state = await boot(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final tab in ['Fixtures', 'Standings', 'Club', 'Store', 'Profile']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)), findsOneWidget);
    }
    expect(find.textContaining('Online'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
