import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory stand-in for the league backend's /api/v1 routes (tests only).
class FakeBackend {
  bool offline = false;
  final requests = <http.Request>[];
  List<Map<String, dynamic>> fixtures = [];
  Map<String, dynamic> syncResponse = const {};
  Map<String, http.Response Function(http.Request)> overrides = {};

  static http.Response json(Object? body, int status) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  static http.Response error(int status, String code, String message) => json({
    'error': {'code': code, 'message': message, 'details': {}},
  }, status);

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    if (offline) throw const SocketException('Network is unreachable');
    final path = request.url.path;
    final override = overrides[path];
    if (override != null) return override(request);
    if (path == '/api/v1/ping') return json({'pong': true}, 200);
    if (path == '/api/v1/auth/login') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['password'] != 'Nascon@26') return error(401, 'INVALID_CREDENTIALS', 'Bad credentials');
      return json({
        'token': 'tok-123',
        'user': {
          'user_id': 'user-org',
          'email': body['email'],
          'role': 'league_organizer',
          'display_name': 'Olivia Organizer',
          'tenant_id': 'tenant-alpha',
          'league_id': 'league-alpha-1',
          'club_id': null,
          'player_id': null,
        },
        'tenant': {
          'tenant_id': 'tenant-alpha',
          'name': 'Alpha Sports',
          'logo_url': null,
          'primary_color': '#0D47A1',
          'secondary_color': '#FFC107',
        },
      }, 200);
    }
    if (path == '/api/v1/leagues') {
      return json([
        {'league_id': 'league-alpha-1', 'name': 'Alpha Premier', 'tenant_id': 'tenant-alpha', 'sport_id': 'football'},
      ], 200);
    }
    if (path.endsWith('/fixtures')) return json(fixtures, 200);
    if (path == '/api/v1/sync') return json(syncResponse, 200);
    return error(404, 'NOT_FOUND', 'No route');
  });
}
