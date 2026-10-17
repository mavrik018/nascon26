import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../widgets/common.dart';
import 'roster_action_screen.dart';

/// Club tab: the user's own club, or a list of clubs to choose from.
class ClubTab extends StatelessWidget {
  const ClubTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final own = state.user?.clubId;
    if (own != null && own.isNotEmpty) return ClubScreen(clubId: own, isTab: true);
    final ids = <String>{...AppState.demoClubs};
    return Scaffold(
      appBar: leagueAppBar(context, 'Clubs'),
      body: CachedLoader(
        path: '/api/v1/leagues/${state.leagueId}/standings',
        builder: (context, data, refresh) {
          for (final r in asList(asMap(data)['table'])) {
            ids.add(asStr(asMap(r)['team_id']));
          }
          return _ClubList(ids: ids.where((e) => e.isNotEmpty).toList()..sort());
        },
      ),
    );
  }
}

class _ClubList extends StatelessWidget {
  const _ClubList({required this.ids});
  final List<String> ids;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListView(
      children: [
        const SectionTitle('Choose a club'),
        for (final id in ids)
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text(state.teamName(id)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ClubScreen(clubId: id))),
          ),
      ],
    );
  }
}

class ClubScreen extends StatelessWidget {
  const ClubScreen({super.key, required this.clubId, this.isTab = false});
  final String clubId;
  final bool isTab;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: leagueAppBar(context, isTab ? 'My club' : 'Club profile'),
      body: CachedLoader(
        path: '/api/v1/clubs/$clubId',
        builder: (context, data, refresh) => _ClubBody(
          club: asMap(data),
          clubId: clubId,
          canManage: state.user?.canManageClub(clubId) ?? false,
          refresh: refresh,
        ),
      ),
    );
  }
}

class _ClubBody extends StatelessWidget {
  const _ClubBody({required this.club, required this.clubId, required this.canManage, required this.refresh});
  final Map<String, dynamic> club;
  final String clubId;
  final bool canManage;
  final Future<void> Function() refresh;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final name = asStr(club['name'], state.teamName(clubId));
    state.rememberTeamName(clubId, name);
    final venue = asMap(club['home_venue']);
    final social = asMap(club['social']);
    final staff = [for (final s in asList(club['staff'])) asMap(s)];
    final stats = [for (final s in asList(club['stats'])) asMap(s)];
    final roster = [for (final p in asList(club['roster'])) asMap(p)];

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          color: theme.colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: theme.colorScheme.primary,
                  child: Icon(Icons.shield, color: theme.colorScheme.onPrimary, size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                      ),
                      if (venue.isNotEmpty)
                        Text(
                          'Home: ${asStr(venue['name'], 'Unknown venue')}',
                          style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SectionTitle('Home venue'),
        ListTile(
          leading: const Icon(Icons.stadium_outlined),
          title: Text(asStr(venue['name'], 'No venue listed')),
          subtitle: venue['lat'] == null ? null : Text('Location ${venue['lat']}, ${venue['lng']}'),
        ),
        if (social.isNotEmpty) ...[
          const SectionTitle('Social'),
          for (final e in social.entries)
            ListTile(leading: const Icon(Icons.link), title: Text(humanize(e.key)), subtitle: Text(asStr(e.value))),
        ],
        const SectionTitle('Staff'),
        if (staff.isEmpty) const ListTile(title: Text('No staff listed')),
        for (final s in staff)
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(asStr(s['name'])),
            subtitle: Text(humanize(asStr(s['role']))),
          ),
        if (stats.isNotEmpty) ...[
          const SectionTitle('Season stats'),
          for (final s in stats)
            ListTile(
              leading: const Icon(Icons.bar_chart),
              title: Text('Season ${asStr(s['season'])}'),
              subtitle: Text('Played ${s['played']} · Won ${s['won']} · Drawn ${s['drawn']} · Lost ${s['lost']}'),
            ),
        ],
        SectionTitle('Roster (${roster.length})'),
        if (canManage)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Tap "Manage" on a player to transfer, loan or release them.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (roster.isEmpty) const EmptyView(icon: Icons.groups_outlined, title: 'No players yet'),
        for (final p in roster) _PlayerTile(player: p, clubId: clubId, canManage: canManage, onChanged: refresh),
      ],
    );
  }
}

class _PlayerTile extends StatelessWidget {
  const _PlayerTile({required this.player, required this.clubId, required this.canManage, required this.onChanged});
  final Map<String, dynamic> player;
  final String clubId;
  final bool canManage;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pid = asStr(player['player_id']);
    final name = asStr(player['name'], humanize(pid));
    final pending = state.pendingFor(ActionTypes.rosterTransfer, pid);
    final loanEnd = player['loan_end_date'];
    final isLoan = asStr(player['registration_type']) == 'loan';
    return ListTile(
      leading: CircleAvatar(child: Text(name.isEmpty ? '?' : name[0].toUpperCase())),
      title: Text(name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${humanize(asStr(player['position'])).toUpperCase()} · ${humanize(asStr(player['role']))}'),
          if (isLoan || loanEnd != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: StatusPill(
                icon: Icons.swap_horiz,
                label: loanEnd == null ? 'On loan' : 'On loan until $loanEnd',
                color: Theme.of(context).colorScheme.tertiaryContainer,
                onColor: Theme.of(context).colorScheme.onTertiaryContainer,
              ),
            ),
          if (pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: PendingPill(label: '${pending.length} change(s) pending sync'),
            ),
        ],
      ),
      trailing: canManage
          ? TextButton(
              onPressed: () async {
                final changed = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => RosterActionScreen(player: player, clubId: clubId),
                  ),
                );
                if (changed == true) await onChanged();
              },
              child: Text('Manage', semanticsLabel: 'Manage $name'),
            )
          : null,
    );
  }
}
