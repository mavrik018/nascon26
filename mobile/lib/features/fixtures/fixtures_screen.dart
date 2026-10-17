import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/format.dart';
import '../../widgets/common.dart';
import '../home/league_picker.dart';
import 'match_screen.dart';

/// Status pill shared by the fixtures list and match detail.
Widget matchStatusPill(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'in_progress' => StatusPill(
      icon: Icons.sensors,
      label: 'Live',
      color: scheme.errorContainer,
      onColor: scheme.onErrorContainer,
    ),
    'completed' => StatusPill(icon: Icons.flag_outlined, label: 'Full time', color: scheme.surfaceContainerHighest),
    _ => StatusPill(
      icon: Icons.schedule,
      label: 'Upcoming',
      color: scheme.primaryContainer,
      onColor: scheme.onPrimaryContainer,
    ),
  };
}

/// Team id + display name from a fixture side (string id or object).
(String, String) fixtureTeam(AppState state, Object? side) {
  if (side is Map) {
    final id = asStr(side['team_id'] ?? side['club_id'] ?? side['id']);
    final name = asStr(side['name']);
    if (name.isNotEmpty) state.rememberTeamName(id, name);
    return (id, name.isNotEmpty ? name : state.teamName(id));
  }
  final id = asStr(side);
  return (id, state.teamName(id));
}

class FixturesScreen extends StatelessWidget {
  const FixturesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: leagueAppBar(context, 'Fixtures'),
      body: Column(
        children: [
          const LeaguePicker(),
          Expanded(
            child: CachedLoader(
              path: '/api/v1/leagues/${state.leagueId}/fixtures',
              isEmpty: (d) => asList(d is Map ? d['fixtures'] ?? d['matches'] : d).isEmpty,
              empty: const EmptyView(
                icon: Icons.event_busy,
                title: 'No matches yet',
                message: 'Fixtures appear here once the organizer schedules them.',
              ),
              builder: (context, data, refresh) {
                final list = [
                  for (final f in asList(data is Map ? data['fixtures'] ?? data['matches'] : data)) asMap(f),
                ];
                int rank(Map<String, dynamic> f) => switch (asStr(f['status'])) {
                  'in_progress' => 0,
                  'upcoming' => 1,
                  _ => 2,
                };
                list.sort((a, b) {
                  final r = rank(a).compareTo(rank(b));
                  if (r != 0) return r;
                  return asStr(a['scheduled_at']).compareTo(asStr(b['scheduled_at']));
                });
                // Save match details too, so scoring works after going offline.
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => state.prefetch([for (final f in list) '/api/v1/matches/${asStr(f['match_id'])}']),
                );
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: list.length,
                  itemBuilder: (context, i) => FixtureCard(fixture: list[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class FixtureCard extends StatelessWidget {
  const FixtureCard({super.key, required this.fixture});
  final Map<String, dynamic> fixture;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final (homeId, home) = fixtureTeam(state, fixture['home'] ?? fixture['home_team_id']);
    final (awayId, away) = fixtureTeam(state, fixture['away'] ?? fixture['away_team_id']);
    final status = asStr(fixture['status'], 'upcoming');
    final matchId = asStr(fixture['match_id']);
    final hasScore = status != 'upcoming' && fixture['home_score'] != null;
    final score = hasScore ? '${fixture['home_score']} – ${fixture['away_score']}' : 'vs';
    final pending = state.pendingFor('score_event', matchId).length;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MatchScreen(
              matchId: matchId,
              homeName: home,
              awayName: away,
              homeId: homeId,
              awayId: awayId,
            ),
          ),
        ),
        child: Semantics(
          button: true,
          label: '$home versus $away, ${status == 'in_progress' ? 'live' : status}, $score. Open match.',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    matchStatusPill(context, status),
                    if (pending > 0) PendingPill(label: '$pending pending'),
                    Text(formatDateTime(asStr(fixture['scheduled_at'])), style: theme.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        home,
                        textAlign: TextAlign.end,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(score, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    ),
                    Expanded(
                      child: Text(
                        away,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
