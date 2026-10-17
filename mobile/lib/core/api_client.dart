import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'errors.dart';

/// Every failure the UI can show. [message] is always plain language.
class ApiException implements Exception {
  const ApiException(this.message, {this.code, this.status, this.isNetwork = false, this.details = const {}});

  final String message;
  final String? code;
  final int? status;

  /// True when the server could not be reached at all (offline, timeout).
  final bool isNetwork;
  final Map<String, dynamic> details;

  bool get isUnauthorized => status == 401;

  @override
  String toString() => 'ApiException($status, $code): $message';
}

/// Normalises what a user types as a server address.
String normalizeBaseUrl(String raw) {
  var url = raw.trim();
  if (url.isEmpty) return url;
  if (!url.startsWith('http://') && !url.startsWith('https://')) url = 'http://$url';
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

/// Thin JSON client for the league backend. One place maps transport and
/// HTTP failures to [ApiException] with friendly messages.
class ApiClient {
  ApiClient({
    required String baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
    this.retries = 2,
    this.retryDelay = const Duration(milliseconds: 600),
  }) : _baseUrl = normalizeBaseUrl(baseUrl),
       _client = client ?? http.Client();

  String _baseUrl;
  final Duration timeout;
  final int retries;
  final Duration retryDelay;
  final http.Client _client;
  String? token;

  /// Called with true after any response, false after a transport failure.
  void Function(bool reachable)? onReachability;

  /// Called when an authenticated request returns 401.
  void Function()? onUnauthorized;

  String get baseUrl => _baseUrl;
  set baseUrl(String value) => _baseUrl = normalizeBaseUrl(value);

  Future<dynamic> get(String path) => send('GET', path);
  Future<dynamic> post(String path, Object? body) => send('POST', path, body);

  Future<dynamic> send(String method, String path, [Object? body]) async {
    final Uri uri;
    try {
      uri = Uri.parse('$_baseUrl$path');
      if (!uri.hasScheme || uri.host.isEmpty) throw const FormatException();
    } on FormatException {
      throw const ApiException('The server address is not valid. Fix it in Settings.', isNetwork: true);
    }
    final request = http.Request(method, uri)..headers['Accept'] = 'application/json';
    final sentToken = token;
    if (sentToken != null) request.headers['Authorization'] = 'Bearer $sentToken';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await _sendWithRetry(request, retries: method == 'GET' ? retries : 0);
    } on TimeoutException {
      onReachability?.call(false);
      throw const ApiException('The server took too long to answer. You may be offline.', isNetwork: true);
    } on SocketException {
      onReachability?.call(false);
      throw const ApiException(offlineMessage, isNetwork: true);
    } on http.ClientException {
      onReachability?.call(false);
      throw const ApiException(offlineMessage, isNetwork: true);
    } on HandshakeException {
      onReachability?.call(false);
      throw const ApiException(offlineMessage, isNetwork: true);
    }
    onReachability?.call(true);

    final decoded = _tryDecode(response.body);
    final status = response.statusCode;
    if (status >= 200 && status < 300) return decoded;
    throw errorFromResponse(status, decoded, hadToken: sentToken != null);
  }

  /// Sends once, then retries brief transport failures (Wi-Fi hiccup, server restarting)
  /// with a short backoff. Only reads are retried automatically: a failed write is
  /// queued offline instead, and every write carries a client id so replays are safe.
  Future<http.Response> _sendWithRetry(http.Request request, {required int retries}) async {
    for (var attempt = 0; ; attempt++) {
      final copy = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      try {
        return await http.Response.fromStream(await _client.send(copy).timeout(timeout)).timeout(timeout);
      } on Exception catch (e) {
        final transient = e is TimeoutException || e is SocketException || e is http.ClientException;
        if (!transient || attempt >= retries) rethrow;
        await Future<void>.delayed(retryDelay * (attempt + 1));
      }
    }
  }

  ApiException errorFromResponse(int status, Object? decoded, {bool hadToken = false}) {
    String? code;
    String? message;
    Map<String, dynamic> details = const {};
    if (decoded is Map && decoded['error'] is Map) {
      final err = decoded['error'] as Map;
      code = err['code']?.toString();
      message = err['message']?.toString();
      if (err['details'] is Map) details = Map<String, dynamic>.from(err['details'] as Map);
    } else if (decoded is Map && decoded['detail'] is String) {
      message = decoded['detail'] as String;
    }
    if (status == 401 && hadToken) onUnauthorized?.call();
    return ApiException(
      friendlyMessage(code: code, serverMessage: message, status: status),
      code: code,
      status: status,
      details: details,
    );
  }

  static Object? _tryDecode(String body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }
}
