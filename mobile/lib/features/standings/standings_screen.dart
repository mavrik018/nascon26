import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/format.dart';
import '../../widgets/common.dart';
import '../club/club_screen.dart';
import '../home/league_picker.dart';

String formatDiff(Object? v) {
  if (v is int) return v > 0 ? '+$v' : '$v';
  if (v is num) return v > 0 ? '+${v.toStringAsFixed(3)}' : v.toStringAsFixed(3);
  return asStr(v, '0');
}

Widget qualificationPill(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'clinched' => StatusPill(
      icon: Icons.verified,
      label: 'Qualified',
      color: scheme.primaryContainer,
      onColor: scheme.onPrimaryContainer,
    ),
    'eliminated' => StatusPill(
      icon: Icons.block,
      label: 'Eliminated',
      color: scheme.errorContainer,
      onColor: scheme.onErrorContainer,
    ),
    _ => StatusPill(icon: Icons.hourglass_empty, label: 'Still in contention', color: scheme.surfaceContainerHighest),
  };
}

const _criteria = {
  'h2h_points': 'head-to-head points',
  'h2h_diff': 'head-to-head difference',
  'overall_diff': 'overall difference',
  'scored': 'scored',
  'fair_play': 'fair play',
  'draw_lots': 'drawing lots',
};

class StandingsScreen extends StatelessWidget {
  const StandingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: leagueAppBar(context, 'Standings'),
      body: Column(
        children: [
          const LeaguePicker(),
          Expanded(
            child: CachedLoader(
              path: '/api/v1/leagues/${state.leagueId}/standings',
              isEmpty: (d) => asList(asMap(d)['table']).isEmpty,
              empty: const EmptyView(
                icon: Icons.leaderboard_outlined,
                title: 'No standings yet',
                message: 'The table fills in once teams are in the league.',
              ),
              builder: (context, data, refresh) {
                final m = asMap(data);
                final rows = [for (final r in asList(m['table'])) asMap(r)];
                final spots = m['qualification_spots'];
                return ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        spots == null
                            ? 'Tap a team for details and head-to-head.'
                            : 'Top $spots qualify. Tap a team for details and head-to-head.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    for (final r in rows) _StandingRow(row: r, onTap: () => _showTeam(context, r, m)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showTeam(BuildContext context, Map<String, dynamic> row, Map<String, dynamic> standings) {
    final state = AppScope.read(context);
    final teamId = asStr(row['team_id']);
    final h2h = asMap(asMap(standings['h2h'])[teamId]);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text(state.teamName(teamId), style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: qualificationPill(ctx, asStr(row['status']))),
            const SizedBox(height: 12),
            Text('Rank ${row['rank']} · ${row['points']} points'),
            Text('Played ${row['played']} · Won ${row['won']} · Drawn ${row['drawn']} · Lost ${row['lost']}'),
            Text('Scored ${row['scored']} · Conceded ${row['conceded']} · Difference ${formatDiff(row['diff'])}'),
            Text('Fair play ${row['fair_play']}'),
            if (row['resolved_by'] != null)
              Text('Placed above a tied team by ${_criteria[row['resolved_by']] ?? row['resolved_by']}.'),
            const SizedBox(height: 16),
            Text('Head-to-head', style: Theme.of(ctx).textTheme.titleMedium),
            if (h2h.isEmpty) const Text('No head-to-head data yet.'),
            for (final e in h2h.entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.compare_arrows),
                title: Text('vs ${state.teamName(e.key)}'),
                subtitle: Text(
                  'Played ${asMap(e.value)['played']} · Points ${asMap(e.value)['points']} · '
                  '${asMap(e.value)['scored']}–${asMap(e.value)['conceded']}',
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => ClubScreen(clubId: teamId)));
              },
              icon: const Icon(Icons.shield_outlined),
              label: const Text('Open club profile'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StandingRow extends StatelessWidget {
  const _StandingRow({required this.row, required this.onTap});
  final Map<String, dynamic> row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final name = state.teamName(asStr(row['team_id']));
    final status = asStr(row['status']);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          label:
              'Rank ${row['rank']}, $name, ${row['points']} points, '
              '${status == 'clinched'
                  ? 'qualified'
                  : status == 'eliminated'
                  ? 'eliminated'
                  : 'still in contention'}',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  child: Text(
                    '${row['rank']}',
                    style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.onSecondaryContainer),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(
                        'P ${row['played']} · W ${row['won']} · D ${row['drawn']} · L ${row['lost']} · '
                        'Diff ${formatDiff(row['diff'])}',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      qualificationPill(context, status),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  children: [
                    Text(
                      '${row['points']}',
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text('pts', style: theme.textTheme.labelSmall),
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
