import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:league_app/core/api_client.dart';
import 'package:league_app/core/errors.dart';

import 'fake_backend.dart';

void main() {
  late FakeBackend backend;
  late ApiClient api;

  setUp(() {
    backend = FakeBackend();
    api = ApiClient(baseUrl: 'http://10.0.2.2:8080/', client: backend.client);
  });

  test('normalizes the server address', () {
    expect(normalizeBaseUrl(' 192.168.1.20:8080/ '), 'http://192.168.1.20:8080');
    expect(normalizeBaseUrl('https://x.test//'), 'https://x.test');
    expect(api.baseUrl, 'http://10.0.2.2:8080');
  });

  test('live events: parses SSE data messages, skips keep-alives, sends the token', () async {
    late http.BaseRequest seen;
    final sse = ApiClient(
      baseUrl: 'http://x.test',
      client: MockClient.streaming((request, _) async {
        seen = request;
        const body = ': keep-alive\n\nevent: match\ndata: {"version": 1}\n\n: keep-alive\n\n'
            'event: match\ndata: {"version": 2,\ndata: "status": "completed"}\n\n';
        return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
      }),
    )..token = 'abc';
    final messages = await sse.events('/api/v1/matches/m1/stream').toList();
    expect(messages, [
      {'version': 1},
      {'version': 2, 'status': 'completed'},
    ]);
    expect(seen.headers['Authorization'], 'Bearer abc');
    expect(seen.headers['Accept'], 'text/event-stream');
  });

  test('live events: a non-200 answer is an error so the page falls back to polling', () async {
    final sse = ApiClient(
      baseUrl: 'http://x.test',
      client: MockClient.streaming((_, _) async => http.StreamedResponse(const Stream.empty(), 404)),
    );
    expect(sse.events('/stream').toList(), throwsA(isA<ApiException>()));
  });

  test('sends the bearer token and JSON body', () async {
    api.token = 'abc';
    await api.post('/api/v1/sync', {'device_id': 'd', 'actions': []});
    final req = backend.requests.single;
    expect(req.headers['Authorization'], 'Bearer abc');
    expect(req.headers['Content-Type'], startsWith('application/json'));
    expect(req.url.toString(), 'http://10.0.2.2:8080/api/v1/sync');
  });

  test('maps an error envelope code to a plain-language message', () async {
    backend.overrides['/api/v1/roster/transfer'] = (_) =>
        FakeBackend.error(409, 'SQUAD_FULL', 'Squad club-alpha-2 is full');
    final error = await api
        .post('/api/v1/roster/transfer', {})
        .then<ApiException?>((_) => null, onError: (Object e) => e as ApiException);
    expect(error, isNotNull);
    expect(error!.code, 'SQUAD_FULL');
    expect(error.status, 409);
    expect(error.isNetwork, isFalse);
    expect(error.message, friendlyByCode['SQUAD_FULL']);
  });

  test('payment errors are explained without codes', () async {
    backend.overrides['/api/v1/store/checkout'] = (_) => FakeBackend.error(402, 'PAYMENT_DECLINED', 'declined');
    await expectLater(
      api.post('/api/v1/store/checkout', {}),
      throwsA(
        isA<ApiException>()
            .having((e) => e.message, 'message', contains('declined'))
            .having((e) => e.message, 'message', isNot(contains('PAYMENT_DECLINED'))),
      ),
    );
  });

  test('a 500 never shows "Error 500"', () async {
    backend.overrides['/api/v1/leagues'] = (_) => FakeBackend.json({'detail': 'boom'}, 500);
    await expectLater(
      api.get('/api/v1/leagues'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.status, 'status', 500)
            .having((e) => e.message, 'message', isNot(contains('500'))),
      ),
    );
  });

  test('unknown codes fall back to the server message, raw codes are hidden', () {
    expect(friendlyMessage(code: 'SOMETHING_NEW', serverMessage: 'Readable text', status: 409), 'Readable text');
    expect(
      friendlyMessage(code: 'SOMETHING_NEW', serverMessage: 'SOMETHING_NEW', status: 409),
      'Something went wrong. Please try again.',
    );
  });

  test('network failure is flagged as offline and reported', () async {
    final reach = <bool>[];
    api.onReachability = reach.add;
    backend.offline = true;
    await expectLater(
      api.get('/api/v1/leagues'),
      throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue)),
    );
    expect(reach, [false]);
    backend.offline = false;
    await api.get('/api/v1/ping');
    expect(reach, [false, true]);
  });

  test('401 on an authenticated call triggers the unauthorized callback', () async {
    var called = 0;
    api.onUnauthorized = () => called++;
    backend.overrides['/api/v1/me'] = (_) => FakeBackend.error(401, 'UNAUTHENTICATED', 'expired');
    api.token = 'expired';
    await expectLater(api.get('/api/v1/me'), throwsA(isA<ApiException>()));
    expect(called, 1);
    api.token = null;
    await expectLater(api.get('/api/v1/me'), throwsA(isA<ApiException>()));
    expect(called, 1, reason: 'login failures must not log the user out');
  });
}
