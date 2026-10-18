import 'package:flutter_test/flutter_test.dart';
import 'package:league_app/core/deep_links.dart';

void main() {
  test('spec 6.3 links map to the Match Live and Co-Stream screens', () {
    expect(parseDeepLink('nascon://entity/match-m1'), const DeepLink(DeepLinkKind.match, 'match-m1'));
    expect(parseDeepLink('nascon://stream/cs-session-101'), const DeepLink(DeepLinkKind.costream, 'cs-session-101'));
    expect(parseDeepLink('nascon://entity/cs-session-101'), const DeepLink(DeepLinkKind.costream, 'cs-session-101'));
    expect(parseDeepLink('nascon://entity/player-beta-2'), const DeepLink(DeepLinkKind.entity, 'player-beta-2'));
  });

  test('anything else is ignored', () {
    expect(parseDeepLink(null), isNull);
    expect(parseDeepLink('https://example.com/entity/match-m1'), isNull);
    expect(parseDeepLink('nascon://entity'), isNull);
    expect(parseDeepLink('nascon://unknown/x'), isNull);
  });
}
