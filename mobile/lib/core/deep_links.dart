import 'dart:async';

import 'package:flutter/services.dart';

enum DeepLinkKind { match, costream, entity }

/// A parsed `nascon://` link (spec 6.3): `nascon://entity/match-m1`, `nascon://stream/cs-session-101`.
class DeepLink {
  const DeepLink(this.kind, this.id);
  final DeepLinkKind kind;
  final String id;

  @override
  bool operator ==(Object other) => other is DeepLink && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'DeepLink($kind, $id)';
}

DeepLink? parseDeepLink(String? raw) {
  if (raw == null) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'nascon') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  final id = segments.first;
  switch (uri.host) {
    case 'stream':
    case 'costream':
      return DeepLink(DeepLinkKind.costream, id);
    case 'entity':
      if (id.startsWith('cs-session-')) return DeepLink(DeepLinkKind.costream, id);
      if (id.startsWith('match-')) return DeepLink(DeepLinkKind.match, id);
      return DeepLink(DeepLinkKind.entity, id);
    case 'match':
    case 'matches':
      return DeepLink(DeepLinkKind.match, id);
  }
  return null;
}

/// Platform side lives in MainActivity.kt (channel `nascon/deeplink`); no plugin dependency.
class DeepLinks {
  DeepLinks._();
  static const _channel = MethodChannel('nascon/deeplink');
  static final _links = StreamController<DeepLink>.broadcast();
  static bool _wired = false;

  /// Every link the app is opened with: the launch link first (if any), then links that arrive while running.
  static Stream<DeepLink> get links {
    if (!_wired) {
      _wired = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onLink') {
          final link = parseDeepLink(call.arguments as String?);
          if (link != null) _links.add(link);
        }
      });
      scheduleMicrotask(() async {
        try {
          final link = parseDeepLink(await _channel.invokeMethod<String>('getInitialLink'));
          if (link != null) _links.add(link);
        } on MissingPluginException {
          // Not on Android (tests, desktop): no launch link.
        } on PlatformException {
          // Same: no launch link.
        }
      });
    }
    return _links.stream;
  }
}
