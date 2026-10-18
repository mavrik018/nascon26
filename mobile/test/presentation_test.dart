import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:league_app/core/app_state.dart';
import 'package:league_app/core/local_store.dart';
import 'package:league_app/presentation/clubline_app.dart';

import 'fake_backend.dart';

/// The integrated app: session gate + five tabs backed by the (fake) API.
void main() {
  Future<AppState> boot(WidgetTester tester, {bool loggedIn = true, Size size = const Size(360, 640)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
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

  testWidgets('signed out -> onboarding on new download, then sign-in page, no tabs', (tester) async {
    final state = await boot(tester, loggedIn: false);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const Key('onboarding-page')), findsOneWidget);
    expect(find.text('Start Your Dream Journey!'), findsOneWidget);

    // Step through the 4 onboarding screens
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Tactical Lineups & Squads'), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Live Analytics & Offline Sync'), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Official Club Store & Merch'), findsOneWidget);

    // Finish onboarding -> persists in store and opens SignInPage
    await tester.tap(find.byKey(const Key('onboarding-start')));
    await tester.pumpAndSettle();
    expect(state.onboardingSeen, isTrue);
    expect(await state.store.getSetting('onboarding_seen'), 'true');
    expect(find.byKey(const Key('onboarding-page')), findsNothing);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.byKey(const Key('login-sports-hero')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('signed in -> five tabs and the sync indicator', (tester) async {
    final state = await boot(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final tab in ['Fixtures', 'Standings', 'Club', 'Store', 'Profile']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)), findsOneWidget);
    }
    // Spec 8.2: the connection state is always visible in the page header, even when all is well.
    expect(find.byKey(const Key('sync-dot')), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('tenant brand colour drives the theme', (tester) async {
    final state = await boot(tester);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme!.colorScheme.primary, const Color(0xFF1E40AF));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('club manager sees both Add merchandise and the cart', (tester) async {
    final state = await boot(tester);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Store')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Add merchandise'), findsOneWidget);
    expect(find.byTooltip('Shopping cart, empty'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  for (final size in const [Size(360, 640), Size(640, 360)]) {
    testWidgets('every tab renders without overflow at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
      final state = await boot(tester, size: size);
      for (final tab in ['Fixtures', 'Standings', 'Club', 'Store', 'Profile']) {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab)));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: '$tab at $size');
        expect(find.byKey(const Key('sync-dot')), findsWidgets, reason: tab);
      }
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }
}
