import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:league_app/core/app_state.dart';
import 'package:league_app/core/local_store.dart';
import 'package:league_app/core/models.dart';

import 'fake_backend.dart';

Future<AppState> makeState(FakeBackend backend, MemoryLocalStore store,
    {bool network = true, String userId = 'user-77', String role = 'club_manager'}) async {
  final tokens = MemoryTokenStore();
  tokens.values['session'] = jsonEncode({
    'token': 'tok-$userId',
    'user': {'user_id': userId, 'email': '$userId@nascon.test', 'role': role, 'club_id': 'club-alpha-1'},
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

void main() {
  test('PendingAction serializes to exactly the 5.14 action format', () {
    const action = PendingAction(
      actionId: 'a1',
      type: 'score_event',
      queuedAt: '2026-10-17T11:00:00Z',
      baseVersion: 3,
      payload: {
        'event_id': 'evt-9',
        'match_id': 'm1',
        'type': 'score',
        'payload': {'team_id': 't1', 'event_type': 'goal'},
      },
      label: 'Goal for T1 (local only)',
    );
    expect(
      jsonEncode(buildSyncRequest('dev-1', [action])),
      '{"device_id":"dev-1","actions":[{"action_id":"a1","type":"score_event",'
      '"queued_at":"2026-10-17T11:00:00Z","base_version":3,"payload":{"event_id":"evt-9",'
      '"match_id":"m1","type":"score","payload":{"team_id":"t1","event_type":"goal"}}}]}',
    );
    final back = PendingAction.fromJson(jsonDecode(jsonEncode(action.toJson())) as Map<String, dynamic>);
    expect(back.toJson(), action.toJson());
    expect(action.targetId, 'm1');
  });

  test('offline score event is queued with the cached match version as base_version', () async {
    final backend = FakeBackend();
    final store = MemoryLocalStore();
    await store.putCache('/api/v1/matches/m1', {'match_id': 'm1', 'version': 3, 'events': []});
    final state = await makeState(backend, store, network: false);
    addTearDown(state.dispose);

    final body = {
      'event_id': 'm-1-x',
      'match_id': 'm1',
      'type': 'score',
      'payload': {'team_id': 't1', 'event_type': 'goal'},
    };
    final outcome = await state.submitMatchEvent(matchId: 'm1', body: body, label: 'Goal for T1');
    expect(outcome.queued, isTrue);
    expect(backend.requests, isEmpty, reason: 'offline actions must not hit the network');
    final queued = store.queue.single;
    expect(queued.type, 'score_event');
    expect(queued.baseVersion, 3);
    expect(queued.payload, body);
    expect(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$').hasMatch(queued.queuedAt), isTrue);
    expect(state.pendingFor('score_event', 'm1'), hasLength(1));
  });

  test('roster base_version is the number of cached history entries (0 when unknown)', () async {
    final backend = FakeBackend();
    final store = MemoryLocalStore();
    await store.putCache('/api/v1/roster/players/p2/history', {
      'player_id': 'p2',
      'history': [
        {'audit_id': 'au-1'},
        {'audit_id': 'au-2'},
      ],
    });
    final state = await makeState(backend, store, network: false);
    addTearDown(state.dispose);
    expect(await state.playerBaseVersion('p2'), 2);
    expect(await state.playerBaseVersion('nobody'), 0);
    expect(AppState.historyLength([1, 2, 3]), 3);

    await state.submitRosterAction(
      body: {'request_id': 'tr-1', 'player_id': 'p2', 'type': 'release'},
      label: 'Release P2',
    );
    expect(store.queue.single.type, 'roster_transfer');
    expect(store.queue.single.baseVersion, 2);
  });

  test('network failure while online falls back to the queue', () async {
    final backend = FakeBackend();
    final store = MemoryLocalStore();
    final state = await makeState(backend, store);
    addTearDown(state.dispose);
    backend.offline = true;
    final outcome = await state.submitRosterAction(body: {'player_id': 'p1'}, label: 'Transfer P1');
    expect(outcome.queued, isTrue);
    expect(state.isOnline, isFalse);
    expect(state.status, NetStatus.offline);
  });

  test('queue survives a restart, sync logs per-action results and clears the queue', () async {
    final backend = FakeBackend();
    final store = MemoryLocalStore();
    final first = await makeState(backend, store, network: false);
    await first.queueAction(
      const PendingAction(
        actionId: 'a1',
        type: 'score_event',
        queuedAt: '2026-10-17T11:00:00Z',
        baseVersion: 3,
        payload: {'match_id': 'm1'},
        label: 'Goal',
        owner: 'user-77',
      ),
    );
    await first.queueAction(
      const PendingAction(
        actionId: 'a2',
        type: 'roster_transfer',
        queuedAt: '2026-10-17T11:01:00Z',
        baseVersion: 1,
        payload: {'player_id': 'p2'},
        label: 'Transfer P2',
        owner: 'user-77',
      ),
    );
    first.dispose();

    // "Force-close and reopen": a new AppState on the same store.
    final state = await makeState(backend, store, network: false);
    addTearDown(state.dispose);
    expect(state.pending.map((a) => a.actionId), ['a1', 'a2']);

    backend.syncResponse = {
      'device_id': state.deviceId,
      'results': [
        {
          'action_id': 'a1',
          'status': 'applied',
          'resolution': 'rebased_append',
          'error_code': null,
          'processed_order': 1,
          'server_version': 5,
          'signature': 'ab',
        },
        {
          'action_id': 'a2',
          'status': 'rejected',
          'resolution': 'server_wins',
          'error_code': 'SQUAD_FULL',
          'processed_order': 2,
          'server_version': 1,
          'signature': null,
        },
      ],
      'summary': {'applied': 1, 'rejected': 1, 'duplicate': 0},
    };
    state.debugSetNetwork(true);
    final summary = await state.syncNow(announce: false);
    expect(summary!.applied, 1);
    expect(summary.rejected, 1);

    final sent = jsonDecode(backend.requests.last.body) as Map<String, dynamic>;
    expect(backend.requests.last.url.path, '/api/v1/sync');
    expect(sent['device_id'], state.deviceId);
    expect((sent['actions'] as List).map((a) => (a as Map)['action_id']), ['a1', 'a2']);
    expect(((sent['actions'] as List).first as Map).keys, [
      'action_id',
      'type',
      'queued_at',
      'base_version',
      'payload',
    ]);

    expect(state.pending, isEmpty);
    expect(store.queue, isEmpty);
    final rejected = state.log.firstWhere((e) => e.actionId == 'a2');
    expect(rejected.status, 'rejected');
    expect(rejected.message, contains('squad is already full'));
    expect(rejected.message, isNot(contains('SQUAD_FULL')));
    expect(state.log.firstWhere((e) => e.actionId == 'a1').message, startsWith('Applied'));
  });

  test('a failed sync keeps every action in the queue', () async {
    final backend = FakeBackend();
    final store = MemoryLocalStore();
    final state = await makeState(backend, store);
    addTearDown(state.dispose);
    await state.queueAction(
      const PendingAction(
        actionId: 'a1',
        type: 'score_event',
        queuedAt: '2026-10-17T11:00:00Z',
        baseVersion: 0,
        payload: {},
        owner: 'user-77',
      ),
    );
    backend.offline = true;
    await state.syncNow(announce: false);
    expect(store.queue, hasLength(1));
    expect(state.lastSyncError, contains('kept on this phone'));
  });

  test('each account has its own queue: a viewer never sees or syncs the manager offline actions', () async {
    final backend = FakeBackend();
    final store = MemoryLocalStore();
    final manager = await makeState(backend, store, network: false);
    await manager.submitRosterAction(body: {'request_id': 'tr-9', 'player_id': 'p9'}, label: 'Transfer P9');
    expect(manager.pending, hasLength(1));
    manager.dispose();

    final viewer = await makeState(backend, store, userId: 'user-viewer', role: 'viewer');
    expect(viewer.pending, isEmpty);
    await viewer.syncNow(announce: false);
    expect(backend.requests.where((r) => r.url.path == '/api/v1/sync'), isEmpty);
    expect(store.queue, hasLength(1), reason: 'kept for the manager');
    viewer.dispose();

    final back = await makeState(backend, store, network: false);
    addTearDown(back.dispose);
    expect(back.pending.single.label, 'Transfer P9');
  });
}
