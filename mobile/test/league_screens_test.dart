import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:league_app/core/app_state.dart';
import 'package:league_app/core/local_store.dart';
import 'package:league_app/presentation/league_screens.dart';
import 'package:league_app/presentation/ocean_widgets.dart';

import 'fake_backend.dart';

Future<AppState> _state(
  FakeBackend backend,
  MemoryLocalStore store, {
  String role = 'fan',
  bool network = true,
}) async {
  final tokens = MemoryTokenStore();
  tokens.values['session'] = jsonEncode({
    'token': 'tok-123',
    'user': {
      'user_id': 'user-1',
      'email': 'user@nascon.test',
      'role': role,
      'league_id': 'league-alpha-1',
    },
    'tenant': null,
  });
  final state = AppState(
    store: store,
    tokens: tokens,
    httpClient: backend.client,
    checkNetwork: () async => network,
    probeInterval: const Duration(hours: 1),
  );
  await state.init();
  return state;
}

final _match = {
  'match_id': 'm1',
  'sport_id': 'football',
  'league_id': 'league-alpha-1',
  'status': 'in_progress',
  'outcome': null,
  'winner_team_id': null,
  'home': {'team_id': 'club-alpha-1', 'score': 1},
  'away': {'team_id': 'club-alpha-2', 'score': 0},
  'version': 4,
  'scheduled_at': '2026-10-17T13:00:00Z',
  'event_types': ['goal', 'own_goal'],
  'pinned_product': {
    'product_id': 'p1',
    'name': 'Home Jersey',
    'price_minor': 350000,
    'currency': 'PKR',
  },
  'events': [
    {'sequence': 1, 'event_id': 'e1', 'type': 'match_start', 'payload': {}, 'compensated': false},
    {
      'sequence': 2,
      'event_id': 'e2',
      'type': 'score',
      'payload': {'team_id': 'club-alpha-1', 'event_type': 'goal'},
      'compensated': true,
      'compensated_by': 'e3',
    },
    {
      'sequence': 3,
      'event_id': 'e3',
      'type': 'compensation',
      'payload': {'compensates': 'e2', 'reason': 'Offside'},
      'compensated': false,
    },
    {
      'sequence': 4,
      'event_id': 'e4',
      'type': 'score',
      'payload': {'team_id': 'club-alpha-1', 'event_type': 'goal'},
      'compensated': false,
    },
  ],
};

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

Widget _app(Widget home) => MaterialApp(theme: oceanTheme(), home: home);

void main() {
  testWidgets('fixtures load live data and filter by status', (tester) async {
    await _phone(tester);
    final backend = FakeBackend()
      ..fixtures = [
        {
          'match_id': 'm1',
          'league_id': 'league-alpha-1',
          'home': 'club-alpha-1',
          'away': 'club-alpha-2',
          'status': 'in_progress',
          'scheduled_at': '2026-10-17T13:00:00Z',
          'home_score': 2,
          'away_score': 1,
        },
        {
          'match_id': 'm2',
          'league_id': 'league-alpha-1',
          'home': 'club-alpha-2',
          'away': 'club-alpha-1',
          'status': 'upcoming',
          'scheduled_at': '2026-10-18T13:00:00Z',
          'home_score': null,
          'away_score': null,
        },
      ];
    final state = (await tester.runAsync(() => _state(backend, MemoryLocalStore())))!;
    addTearDown(state.dispose);

    await tester.pumpWidget(_app(FixturesPage(state: state)));
    await _settle(tester);

    expect(find.text('2 – 1'), findsOneWidget);
    expect(find.text('● LIVE'), findsOneWidget);
    expect(find.text('Club Alpha 1'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Upcoming').first);
    await tester.pump();
    expect(find.text('2 – 1'), findsNothing);
  });

  testWidgets('fixtures show saved data when offline and empty state', (tester) async {
    await _phone(tester);
    final store = MemoryLocalStore();
    await tester.runAsync(() => store.putCache('/api/v1/leagues/league-alpha-1/fixtures', <dynamic>[]));
    final state = (await tester.runAsync(() => _state(FakeBackend(), store, network: false)))!;
    addTearDown(state.dispose);

    await tester.pumpWidget(_app(FixturesPage(state: state)));
    await _settle(tester);

    expect(find.textContaining('Saved data (offline)'), findsOneWidget);
    expect(find.text('No matches yet'), findsOneWidget);
  });

  testWidgets('match page shows score, corrected event and organizer desk', (tester) async {
    await _phone(tester);
    final backend = FakeBackend()
      ..overrides['/api/v1/matches/m1'] = (http.Request r) => FakeBackend.json(_match, 200);
    final state = (await tester.runAsync(
      () => _state(backend, MemoryLocalStore(), role: 'league_organizer'),
    ))!;
    addTearDown(state.dispose);

    await tester.pumpWidget(_app(MatchPage(state: state, matchId: 'm1')));
    await _settle(tester);

    expect(find.text('1 – 0'), findsOneWidget);
    expect(find.text('Home Jersey'), findsOneWidget);
    expect(find.byKey(const Key('add-score')), findsOneWidget);
    expect(find.byKey(const Key('correct-event')), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Win probability'), 200);
    expect(find.text('Win probability'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('CORRECTED'), 200);
    expect(find.text('CORRECTED'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Dispose the page so its 5 s poll timer is cancelled.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('fans do not see the scoring desk', (tester) async {
    await _phone(tester);
    final backend = FakeBackend()
      ..overrides['/api/v1/matches/m1'] = (http.Request r) => FakeBackend.json(_match, 200);
    final state = (await tester.runAsync(() => _state(backend, MemoryLocalStore())))!;
    addTearDown(state.dispose);

    await tester.pumpWidget(_app(MatchPage(state: state, matchId: 'm1')));
    await _settle(tester);

    expect(find.text('1 – 0'), findsOneWidget);
    expect(find.byKey(const Key('add-score')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('standings show qualification with icon and text', (tester) async {
    await _phone(tester);
    final backend = FakeBackend()
      ..overrides['/api/v1/leagues/league-alpha-1/standings'] = (http.Request r) => FakeBackend.json({
        'table': [
          {
            'rank': 1,
            'team_id': 'club-alpha-1',
            'played': 3,
            'won': 3,
            'drawn': 0,
            'lost': 0,
            'scored': 7,
            'conceded': 1,
            'diff': 6,
            'points': 9,
            'fair_play': 0,
            'status': 'clinched',
            'resolved_by': null,
          },
          {
            'rank': 2,
            'team_id': 'club-alpha-2',
            'played': 3,
            'won': 0,
            'drawn': 0,
            'lost': 3,
            'scored': 1,
            'conceded': 7,
            'diff': -6,
            'points': 0,
            'fair_play': 2,
            'status': 'eliminated',
            'resolved_by': 'h2h_points',
          },
        ],
        'h2h': {},
      }, 200);
    final state = (await tester.runAsync(() => _state(backend, MemoryLocalStore())))!;
    addTearDown(state.dispose);

    await tester.pumpWidget(_app(StandingsPage(state: state)));
    await _settle(tester);

    expect(find.text('LEAGUE LEADERS'), findsOneWidget);
    expect(find.text('Qualified'), findsOneWidget);
    expect(find.text('Out'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
