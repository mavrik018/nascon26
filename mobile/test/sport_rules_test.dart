import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:league_app/core/app_state.dart';
import 'package:league_app/core/format.dart';
import 'package:league_app/core/local_store.dart';
import 'package:league_app/presentation/ocean_widgets.dart';
import 'package:league_app/presentation/sport_screens.dart';

import 'fake_backend.dart';

const _football = {
  'sport_id': 'football',
  'name': 'Football',
  'scoring_model': 'event',
  'periods': {'count': 2, 'duration_minutes': 45},
  'scoring_events': {
    'goal': {'points': 1},
  },
  'draw_allowed': true,
  'overtime': {'policy': 'none'},
  'tie_break_order': ['h2h_points', 'draw_lots'],
  'roster': {
    'min_squad_size': 11,
    'max_squad_size': 25,
    'required_positions': {'gk': 1},
  },
  'baseline': true,
};

Future<AppState> _state(FakeBackend backend, String role) async {
  final tokens = MemoryTokenStore()
    ..values['session'] = jsonEncode({
      'token': 't',
      'user': {'user_id': 'u-$role', 'email': '$role@nascon.test', 'role': role},
      'tenant': null,
    });
  final s = AppState(
    store: MemoryLocalStore(),
    tokens: tokens,
    httpClient: backend.client,
    checkNetwork: () async => true,
    probeInterval: const Duration(hours: 1),
  );
  await s.init();
  return s;
}

void main() {
  Future<void> phone(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('organizer edits rules: adds a scoring rule and picks a tie-break from the iOS sheet', (tester) async {
    await phone(tester);
    Map<String, dynamic>? sent;
    String? method;
    final backend = FakeBackend()
      ..overrides['/api/v1/sports/football'] = (r) {
        method = r.method;
        sent = jsonDecode(r.body) as Map<String, dynamic>;
        return FakeBackend.json({'sport_id': 'football', 'status': 'updated', 'config': sent}, 200);
      };
    final s = await _state(backend, 'league_organizer');
    await tester.pumpWidget(MaterialApp(theme: oceanTheme(), home: SportEditorPage(state: s, sport: _football)));
    await tester.pumpAndSettle();
    expect(find.text('Edit rules'), findsOneWidget);
    expect(find.byKey(const Key('delete-sport')), findsNothing); // organizers edit, only the admin deletes

    await tester.ensureVisible(find.byKey(const Key('add-scoring-rule')));
    await tester.tap(find.byKey(const Key('add-scoring-rule')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Rule 2'), 'Own Goal');

    await tester.ensureVisible(find.text('Overtime / tie-break'));
    await tester.tap(find.text('Overtime / tie-break'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shootout'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('save-sport')));
    await tester.tap(find.byKey(const Key('save-sport')));
    await tester.pumpAndSettle();

    expect(method, 'PUT');
    expect(asMap(sent!['scoring_events']).keys, ['goal', 'own_goal']);
    expect(asMap(sent!['overtime'])['policy'], 'shootout');
    expect(asMap(asMap(sent!['roster'])['required_positions']), {'gk': 1});
    expect(sent!.containsKey('sport_id'), isFalse, reason: 'the server owns sport ids');
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });

  testWidgets('admin sees delete for a custom sport, never for a built-in one', (tester) async {
    await phone(tester);
    final s = await _state(FakeBackend(), 'super_admin');
    await tester.pumpWidget(MaterialApp(theme: oceanTheme(), home: SportEditorPage(state: s, sport: _football)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-sport')), findsNothing);
    await tester.pumpWidget(MaterialApp(
      theme: oceanTheme(),
      home: SportEditorPage(
        key: const ValueKey('custom'),
        state: s,
        sport: {..._football, 'sport_id': 'x', 'baseline': false},
      ),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('delete-sport')), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('delete-sport')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });

  test('client ids are RFC 4122 v4 UUIDs', () {
    final ids = {for (var i = 0; i < 200; i++) newId()};
    expect(ids, hasLength(200));
    for (final id in ids) {
      expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(id), isTrue);
    }
  });
}
