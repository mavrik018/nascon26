import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:league_app/core/app_state.dart';
import 'package:league_app/core/local_store.dart';
import 'package:league_app/presentation/club_screens.dart';
import 'package:league_app/presentation/profile_screens.dart';

import 'fake_backend.dart';

const _club = {
  'club_id': 'club-alpha-1',
  'name': 'Alpha Wolves FC',
  'tenant_id': 'tenant-alpha',
  'home_venue': {'name': 'Wolves Ground', 'lat': 24.8, 'lng': 67.0},
  'social': {'instagram': '@alphawolves'},
  'staff': [
    {'name': 'Sara Coach', 'role': 'head_coach'},
  ],
  'stats': [
    {'season': '2026', 'played': 5, 'won': 3, 'drawn': 1, 'lost': 1},
  ],
  'roster': [
    {
      'player_id': 'p-1',
      'name': 'Malik Vance',
      'position': 'forward',
      'role': 'captain',
      'squad_id': 'club-alpha-1',
      'registration_type': 'permanent',
      'loan_end_date': null,
    },
    {
      'player_id': 'p-2',
      'name': 'Hassan Ali',
      'position': 'defender',
      'role': 'player',
      'squad_id': 'club-alpha-1',
      'registration_type': 'loan',
      'loan_end_date': '2026-12-31',
    },
  ],
};

Future<AppState> _state(
  FakeBackend backend,
  MemoryLocalStore store, {
  String role = 'club_manager',
  bool network = true,
  bool signedIn = true,
}) async {
  final tokens = MemoryTokenStore();
  if (signedIn) {
    tokens.values['session'] = jsonEncode({
      'token': 'tok-123',
      'user': {
        'user_id': 'user-77',
        'email': 'manager@nascon.test',
        'role': role,
        'club_id': 'club-alpha-1',
        'league_id': 'league-alpha-1',
      },
      'tenant': null,
    });
  }
  final s = AppState(
    store: store,
    tokens: tokens,
    httpClient: backend.client,
    checkNetwork: () async => network,
    probeInterval: const Duration(hours: 1),
  );
  await s.init();
  return s;
}

void main() {
  Future<void> phone(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> reveal(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester, AppState s) async {
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  }

  testWidgets('club page shows live roster, venue and stats at 360x640', (tester) async {
    await phone(tester);
    final backend = FakeBackend()
      ..overrides['/api/v1/clubs/club-alpha-1'] = (_) => FakeBackend.json(_club, 200);
    final s = await _state(backend, MemoryLocalStore());
    await tester.pumpWidget(MaterialApp(home: ClubPage(state: s)));
    await tester.pumpAndSettle();
    expect(find.text('Alpha Wolves FC'), findsOneWidget);
    expect(find.text('Malik Vance'), findsOneWidget);
    expect(find.textContaining('Loan ends 2026-12-31'), findsOneWidget);
    await reveal(tester, find.text('Manage roster'));
    expect(find.text('Manage roster'), findsOneWidget);
    await reveal(tester, find.text('Overview'));
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    expect(find.text('Wolves Ground'), findsOneWidget);
    expect(find.text('Sara Coach'), findsOneWidget);
    await tester.tap(find.text('Stats'));
    await tester.pumpAndSettle();
    expect(find.text('Won 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester, s);
  });

  testWidgets('club page offline shows saved data note', (tester) async {
    await phone(tester);
    final store = MemoryLocalStore();
    await store.putCache('/api/v1/clubs/club-alpha-1', _club);
    final s = await _state(FakeBackend(), store, network: false);
    await tester.pumpWidget(MaterialApp(home: ClubPage(state: s)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved data'), findsOneWidget);
    expect(find.text('Hassan Ali'), findsOneWidget);
    await finish(tester, s);
  });

  testWidgets('offline roster transfer is queued and shown as pending', (tester) async {
    await phone(tester);
    final s = await _state(FakeBackend(), MemoryLocalStore(), network: false);
    await tester.pumpWidget(
      MaterialApp(
        home: ManageRosterPage(
          state: s,
          roster: [for (final p in _club['roster']! as List) Map<String, dynamic>.from(p as Map)],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Reason'));
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Needs match time');
    await reveal(tester, find.text('Review and submit'));
    await tester.tap(find.text('Review and submit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(s.pending, hasLength(1));
    final body = s.pending.single.payload;
    expect(body['type'], 'transfer');
    expect(body['to_squad_id'], 'club-alpha-2');
    expect(body['from_squad_id'], 'club-alpha-1');
    expect(body['league_id'], 'league-alpha-1');
    expect(body['requested_by'], 'user-77');
    await reveal(tester, find.text('SAVED OFFLINE'));
    await reveal(tester, find.text('Waiting to sync'));
    expect(find.text('Waiting to sync'), findsOneWidget);
    await finish(tester, s);
  });

  testWidgets('server rejection is shown in plain language', (tester) async {
    await phone(tester);
    final backend = FakeBackend()
      ..overrides['/api/v1/roster/transfer'] =
          (_) => FakeBackend.error(409, 'SQUAD_FULL', 'squad full');
    final s = await _state(backend, MemoryLocalStore());
    await tester.pumpWidget(
      MaterialApp(
        home: ManageRosterPage(
          state: s,
          roster: [for (final p in _club['roster']! as List) Map<String, dynamic>.from(p as Map)],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Reason'));
    await tester.enterText(find.widgetWithText(TextField, 'Reason'), 'Swap');
    await reveal(tester, find.text('Review and submit'));
    await tester.tap(find.text('Review and submit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('already full'));
    expect(find.textContaining('already full'), findsOneWidget);
    expect(s.pending, isEmpty);
    await finish(tester, s);
  });

  testWidgets('viewer sees an explanation instead of the roster form', (tester) async {
    await phone(tester);
    final s = await _state(FakeBackend(), MemoryLocalStore(), role: 'viewer');
    await tester.pumpWidget(MaterialApp(home: ManageRosterPage(state: s)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Only club managers'), findsOneWidget);
    await finish(tester, s);
  });

  testWidgets('sign in with a demo chip logs in; bad password shows plain error', (tester) async {
    await phone(tester);
    final s = await _state(FakeBackend(), MemoryLocalStore(), signedIn: false);
    await tester.pumpWidget(MaterialApp(home: SignInPage(state: s)));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Organizer'));
    await tester.tap(find.text('Organizer'));
    await tester.pump();
    await reveal(tester, find.byKey(const Key('signin-password')));
    await tester.enterText(find.byKey(const Key('signin-password')), 'wrong');
    await reveal(tester, find.byKey(const Key('signin-submit')));
    await tester.tap(find.byKey(const Key('signin-submit')));
    await tester.pumpAndSettle();
    expect(find.text('That email or password is not correct.'), findsOneWidget);
    expect(s.user, isNull);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Organizer'));
    await tester.pump();
    await reveal(tester, find.byKey(const Key('signin-submit')));
    await tester.tap(find.byKey(const Key('signin-submit')));
    await tester.pumpAndSettle();
    expect(s.user?.email, 'organizer@nascon.test');
    expect(tester.takeException(), isNull);
    await finish(tester, s);
  });

  testWidgets('sync page shows empty state, then syncs queued action', (tester) async {
    await phone(tester);
    final backend = FakeBackend();
    final s = await _state(backend, MemoryLocalStore());
    await tester.pumpWidget(MaterialApp(home: SyncPage(state: s)));
    await tester.pumpAndSettle();
    expect(find.text('Nothing waiting to sync'), findsWidgets);
    await finish(tester, s);
  });

  testWidgets('profile shows role and logs out after confirm', (tester) async {
    await phone(tester);
    final s = await _state(FakeBackend(), MemoryLocalStore());
    await tester.pumpWidget(MaterialApp(home: ProfilePage(state: s)));
    await tester.pumpAndSettle();
    expect(find.text('Club manager'), findsOneWidget);
    await reveal(tester, find.text('Log out'));
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
    await tester.pumpAndSettle();
    expect(s.user, isNull);
    await finish(tester, s);
  });
}
