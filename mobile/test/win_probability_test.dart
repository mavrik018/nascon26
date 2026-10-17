import 'package:flutter_test/flutter_test.dart';
import 'package:league_app/core/win_probability.dart';

Map<String, dynamic> m(String status, int h, int a, {String outcome = 'pending', int goals = 0}) => {
      'status': status, 'outcome': outcome,
      'home': {'score': h}, 'away': {'score': a},
      'events': [for (var i = 0; i < goals; i++) {'type': 'score', 'compensated': false}],
    };

void main() {
  test('not started is even', () => expect(estimateWinProbability(m('upcoming', 0, 0)).home, .5));
  test('final result is certain', () {
    expect(estimateWinProbability(m('completed', 2, 1, outcome: 'home_win')).home, 1);
    expect(estimateWinProbability(m('completed', 0, 3, outcome: 'away_win')).away, 1);
  });
  test('leader is favoured and more so later in the match', () {
    final early = estimateWinProbability(m('in_progress', 1, 0, goals: 1)).home;
    final late = estimateWinProbability(m('in_progress', 1, 0, goals: 20)).home;
    expect(early, greaterThan(.5));
    expect(late, greaterThan(early));
    expect(estimateWinProbability(m('in_progress', 0, 2, goals: 2)).away, greaterThan(.5));
  });
  test('a one-run lead in cricket is near even', () {
    final p = estimateWinProbability(m('in_progress', 151, 150, goals: 10)).home;
    expect(p, inInclusiveRange(.5, .6));
  });
  test('probabilities always sum to 1', () {
    final p = estimateWinProbability(m('in_progress', 3, 1, goals: 4));
    expect(p.home + p.away, closeTo(1, 1e-9));
  });
}
