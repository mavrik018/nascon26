import 'dart:math' as math;

/// Live win probability for a match, computed from the server's score projection
/// (spec 5.9 JSON). This is a transparent STATISTICAL estimate, not an AI model:
///
///   lead z = (home score − away score) / sqrt(total scoring + 2)
///   weight grows with match progress (number of active scoring events, capped)
///   P(home) = logistic(1.7 · z · weight)
///
/// A lead counts for more the later it is and the lower-scoring the sport is
/// (one goal in football vs. one run in cricket). Finished matches show the result.
class WinProbability {
  const WinProbability(this.home, this.away, this.basis, {this.decided = false});

  final double home;
  final double away;
  final String basis;
  final bool decided;
}

WinProbability estimateWinProbability(Map<String, dynamic> match) {
  final status = '${match['status'] ?? 'upcoming'}';
  final outcome = '${match['outcome'] ?? 'pending'}';
  final home = (match['home'] as Map?) ?? const {};
  final away = (match['away'] as Map?) ?? const {};
  final hs = _num(home['score']);
  final as = _num(away['score']);

  if (status == 'completed') {
    switch (outcome) {
      case 'home_win':
        return const WinProbability(1, 0, 'Final result', decided: true);
      case 'away_win':
        return const WinProbability(0, 1, 'Final result', decided: true);
      case 'draw':
        return const WinProbability(.5, .5, 'Final result: draw', decided: true);
      default:
        return const WinProbability(.5, .5, 'Level – waiting for the tie-break decision');
    }
  }
  if (status != 'in_progress') {
    return const WinProbability(.5, .5, 'Not started – both sides even');
  }

  final events = (match['events'] as List?) ?? const [];
  final scoringEvents = events
      .whereType<Map>()
      .where((e) => e['type'] == 'score' && e['compensated'] != true)
      .length;
  final progress = math.min(scoringEvents, 20) / 20; // 0 … 1
  final z = (hs - as) / math.sqrt(hs + as + 2);
  final weight = 1 + 1.5 * progress;
  final pHome = 1 / (1 + math.exp(-1.7 * z * weight));
  return WinProbability(pHome, 1 - pHome, 'Live estimate from the current margin and $scoringEvents scoring events');
}

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
