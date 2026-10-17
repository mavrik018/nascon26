import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:league_app/app.dart';
import 'package:league_app/core/app_state.dart';
import 'package:league_app/core/local_store.dart';
import 'package:league_app/core/models.dart';

import 'fake_backend.dart';

Future<AppState> pumpApp(
  WidgetTester tester,
  FakeBackend backend, {
  bool loggedIn = false,
  bool network = true,
  MemoryLocalStore? store,
}) async {
  final tokens = MemoryTokenStore();
  if (loggedIn) {
    tokens.values['session'] = jsonEncode({
      'token': 'tok-123',
      'user': {
        'user_id': 'user-org',
        'email': 'organizer@nascon.test',
        'role': 'league_organizer',
        'display_name': 'Olivia',
        'league_id': 'league-alpha-1',
      },
      'tenant': {'tenant_id': 'tenant-alpha', 'name': 'Alpha Sports', 'primary_color': '#0D47A1'},
    });
  }
  final state = AppState(
    store: store ?? MemoryLocalStore(),
    tokens: tokens,
    httpClient: backend.client,
    checkNetwork: () async => network,
    probeInterval: const Duration(hours: 1),
  );
  await tester.pumpWidget(LeagueApp(state: state));
  await state.init();
  await tester.pumpAndSettle();
  return state;
}

Future<void> unmount(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
}

void main() {
  testWidgets('login screen quick-fill chips fill email and password', (tester) async {
    final backend = FakeBackend();
    final state = await pumpApp(tester, backend);

    expect(find.text('Sign in'), findsWidgets);
    await tester.tap(find.byKey(const Key('demo-manager@nascon.test')));
    await tester.pump();

    final email = tester.widget<TextFormField>(find.byKey(const Key('email')));
    final password = tester.widget<TextFormField>(find.byKey(const Key('password')));
    expect(email.controller!.text, 'manager@nascon.test');
    expect(password.controller!.text, 'Nascon@26');
    await unmount(tester, state);
  });

  testWidgets('signing in opens the role-aware home with tenant branding', (tester) async {
    final backend = FakeBackend();
    final state = await pumpApp(tester, backend);
    await tester.tap(find.byKey(const Key('demo-organizer@nascon.test')));
    await tester.tap(find.byKey(const Key('sign-in')));
    await tester.pumpAndSettle();

    expect(state.user?.role, 'league_organizer');
    expect(find.text('Alpha Sports'), findsWidgets);
    expect(find.text('Fixtures'), findsWidgets);
    expect(find.text('Standings'), findsOneWidget);
    expect(find.text('Store'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    await unmount(tester, state);
  });

  testWidgets('wrong password shows a plain-language error', (tester) async {
    final backend = FakeBackend();
    final state = await pumpApp(tester, backend);
    await tester.enterText(find.byKey(const Key('email')), 'viewer@nascon.test');
    await tester.enterText(find.byKey(const Key('password')), 'nope');
    await tester.tap(find.byKey(const Key('sign-in')));
    await tester.pumpAndSettle();
    expect(find.text('That email or password is not correct.'), findsOneWidget);
    await unmount(tester, state);
  });

  testWidgets('empty fixtures list shows "No matches yet"', (tester) async {
    final backend = FakeBackend()..fixtures = [];
    final state = await pumpApp(tester, backend, loggedIn: true);
    expect(find.text('No matches yet'), findsOneWidget);
    expect(find.byKey(const Key('sync-banner')), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    await unmount(tester, state);
  });

  testWidgets('offline: banner says Offline, cached fixtures still show with a notice', (tester) async {
    final backend = FakeBackend();
    final store = MemoryLocalStore();
    await store.putCache('/api/v1/leagues/league-alpha-1/fixtures', [
      {
        'match_id': 'm1',
        'league_id': 'league-alpha-1',
        'home': 'club-alpha-1',
        'away': 'club-alpha-2',
        'status': 'in_progress',
        'scheduled_at': '2026-10-17T10:00:00Z',
        'home_score': 2,
        'away_score': 1,
      },
    ]);
    await store.enqueue(
      const PendingAction(
        actionId: 'a1',
        type: 'score_event',
        queuedAt: '2026-10-17T11:00:00Z',
        baseVersion: 1,
        payload: {'match_id': 'm1'},
        label: 'Goal',
      ),
    );
    final state = await pumpApp(tester, backend, loggedIn: true, network: false, store: store);

    expect(find.text('Offline · 1 pending'), findsOneWidget);
    expect(find.textContaining('Offline – showing saved data'), findsOneWidget);
    expect(find.text('Club Alpha 1'), findsOneWidget);
    expect(find.text('2 – 1'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('1 pending'), findsOneWidget);
    expect(backend.requests, isEmpty);

    // Banner opens the sync queue with the pending action listed.
    await tester.tap(find.byKey(const Key('sync-banner')));
    await tester.pumpAndSettle();
    expect(find.text('Pending actions (1)'), findsOneWidget);
    expect(find.text('Goal'), findsOneWidget);
    await unmount(tester, state);
  });

  testWidgets('home has no overflow on a 360x640 phone, portrait and landscape', (tester) async {
    for (final size in [const Size(360, 640), const Size(640, 360)]) {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      final backend = FakeBackend()
        ..fixtures = [
          {
            'match_id': 'm1',
            'home': 'a-club-with-a-really-long-name-for-testing',
            'away': 'another-club-with-a-very-very-long-name',
            'status': 'upcoming',
            'scheduled_at': '2026-10-18T10:00:00Z',
            'home_score': null,
            'away_score': null,
          },
        ];
      final state = await pumpApp(tester, backend, loggedIn: true);
      expect(tester.takeException(), isNull);
      await unmount(tester, state);
    }
    tester.view.reset();
  });
}
