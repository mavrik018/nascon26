// Live smoke test of the app's AppState against a REAL running backend (not a fake).
// Not part of `flutter test` (outside test/). Run with the stack up:
//   flutter test integration_smoke/live_backend_test.dart --dart-define=LIVE_API=http://localhost:8080
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:league_app/core/app_state.dart';
import 'package:league_app/core/local_store.dart';

const api = String.fromEnvironment('LIVE_API', defaultValue: 'http://localhost:8080');

void main() {

  Future<AppState> signIn(String who) async {
    final state = AppState(store: MemoryLocalStore(), tokens: MemoryTokenStore(), httpClient: http.Client(),
        probeInterval: const Duration(hours: 1));
    await state.init();
    await state.setBaseUrl(api);
    await state.login('$who@nascon.test', 'Nascon@26');
    expect(state.user, isNotNull);
    return state;
  }

  test('task A: leagues -> fixtures -> standings -> match', () async {
    final s = await signIn('viewer');
    final fixtures = (await s.load('/api/v1/leagues/league-alpha-1/fixtures')).data as List;
    expect(fixtures, isNotEmpty);
    final standings = (await s.load('/api/v1/leagues/league-alpha-1/standings')).data as Map;
    expect((standings['table'] as List).length, 4);
    final match = (await s.load('/api/v1/matches/${fixtures.first['match_id']}')).data as Map;
    expect(match['events'], isNotEmpty);
    s.dispose();
  });

  test('task B: products -> checkout -> signed receipt with PDF', () async {
    final s = await signIn('player');
    final products = (await s.load('/api/v1/store/products')).data as List;
    final variant = (products.first['variants'] as List).firstWhere((v) => (v['stock'] as int) > 0);
    final order = await s.api.post('/api/v1/store/checkout', {
      'order_id': 'smoke-${DateTime.now().millisecondsSinceEpoch}',
      'items': [{'variant_id': variant['variant_id'], 'quantity': 1}],
      'discount_code': null,
      'payment': {'token': 'tok_success'},
    }) as Map;
    expect(order['status'], 'paid');
    expect((order['receipt']['pdf_base64'] as String).isNotEmpty, isTrue);
    s.dispose();
  });

  test('task C: club roster + manager transfer online', () async {
    final s = await signIn('manager');
    final club = (await s.load('/api/v1/clubs/club-alpha-1')).data as Map;
    final player = (club['roster'] as List).firstWhere((p) => p['position'] != 'gk' && p['role'] != 'captain');
    final out = await s.submitRosterAction(body: {
      'request_id': 'smoke-${DateTime.now().millisecondsSinceEpoch}', 'league_id': 'league-alpha-1',
      'player_id': player['player_id'], 'type': 'transfer', 'from_squad_id': 'club-alpha-1',
      'to_squad_id': 'club-alpha-2', 'effective_date': '2026-10-17', 'loan_end_date': null,
      'reason': 'smoke test', 'requested_by': s.user!.userId,
    }, label: 'smoke transfer');
    expect(out.queued, isFalse);
    s.dispose();
  });
}
