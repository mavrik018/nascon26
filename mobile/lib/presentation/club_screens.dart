import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../toolkit/02_ui_elements/search_field.dart';

import '../core/api_client.dart';
import '../core/app_state.dart';
import '../core/errors.dart';
import '../core/format.dart';
import '../core/models.dart';
import 'ocean_widgets.dart';

const _loanColor = Color(0xFF9B6318);
const _danger = Color(0xFFB3261E);

/// Plain-language text for any error thrown while loading or sending.
String plainError(Object e) {
  if (e is ApiException) {
    if (e.code != null && friendlyByCode.containsKey(e.code)) {
      return friendlyByCode[e.code]!;
    }
    return e.message;
  }
  return 'Something went wrong. Please try again.';
}

String _registrationLabel(String raw) => switch (raw) {
  'loan' => 'Loan',
  'permanent' => 'Permanent',
  '' => 'Registered',
  _ => humanize(raw),
};

String _actionLabel(String raw) => switch (raw) {
  'transfer' => 'Transfer',
  'loan' => 'Loan',
  'release' => 'Release',
  'loan_return' => 'Loan return',
  'add' => 'Added',
  'register' || 'registration' => 'Registered',
  _ => humanize(raw),
};

class _Busy extends StatelessWidget {
  const _Busy(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => GlassCard(
    child: Column(
      children: [
        const SizedBox(height: 8),
        const CircularProgressIndicator(),
        const SizedBox(height: 14),
        Text(text, textAlign: TextAlign.center),
      ],
    ),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard(this.message, {required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => GlassCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.cloud_off_outlined, size: 40, color: ocean),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Inter', color: ink),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      ],
    ),
  );
}

class _SavedNote extends StatelessWidget {
  const _SavedNote(this.savedAt);
  final DateTime? savedAt;
  @override
  Widget build(BuildContext context) {
    final ago = formatSavedAgo(savedAt);
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.offline_pin_outlined, color: _loanColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Saved data${ago.isEmpty ? '' : ' from $ago'}. '
              'You are offline, so this may not be the latest.',
              style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _refreshAction(VoidCallback onPressed) => IconButton(
  tooltip: 'Refresh',
  onPressed: onPressed,
  icon: const Icon(Icons.refresh, color: Colors.white),
);

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  return parts.take(2).map((p) => p[0].toUpperCase()).join();
}

// ===================================================================== Club

class ClubPage extends StatefulWidget {
  const ClubPage({super.key, required this.state, this.clubId});
  final AppState state;

  /// Defaults to the signed-in user's club, else the demo club.
  final String? clubId;
  @override
  State<ClubPage> createState() => _ClubPageState();
}

class _ClubPageState extends State<ClubPage> {
  String tab = 'Roster', query = '';
  Loaded? loaded;
  String? error;
  bool loading = true;
  int _seenLog = 0;

  String get clubId =>
      widget.clubId ?? widget.state.user?.clubId ?? AppState.demoClubs.first;
  String get path => '/api/v1/clubs/$clubId';

  @override
  void initState() {
    super.initState();
    _seenLog = widget.state.log.length;
    widget.state.addListener(_onState);
    _load();
  }

  @override
  void didUpdateWidget(ClubPage old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      old.state.removeListener(_onState);
      widget.state.addListener(_onState);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  /// Reload after a sync finished so applied roster moves show up.
  void _onState() {
    if (!mounted) return;
    final n = widget.state.log.length;
    if (n != _seenLog) {
      _seenLog = n;
      _load();
    } else {
      setState(() {});
    }
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final r = await widget.state.load(path);
      if (!mounted) return;
      setState(() {
        loaded = r;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = plainError(e);
        loading = false;
      });
    }
  }

  Future<void> _openManage(List<Map<String, dynamic>> roster) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ManageRosterPage(
          state: widget.state,
          clubId: clubId,
          roster: roster,
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loaded == null) {
      return OceanPage(
        title: 'Club',
        actions: [_refreshAction(_load)],
        children: [
          if (loading)
            const _Busy('Loading your club…')
          else
            _ErrorCard(error ?? 'Could not load the club.', onRetry: _load),
        ],
      );
    }
    final data = asMap(loaded!.data);
    final name = asStr(data['name'], humanize(clubId));
    widget.state.rememberTeamName(clubId, name);
    final roster = [for (final p in asList(data['roster'])) asMap(p)];
    final canManage = widget.state.user?.canManageClub(clubId) ?? false;
    final q = query.toLowerCase();
    final visible = roster
        .where(
          (p) => '${asStr(p['name'])} ${asStr(p['position'])}'
              .toLowerCase()
              .contains(q),
        )
        .toList();
    return OceanPage(
      title: 'Club',
      subtitle: (widget.state.tenant?.name ?? 'ALPHA SPORTS LEAGUE').toUpperCase(),
      actions: [_refreshAction(_load)],
      children: [
        if (loading) const LinearProgressIndicator(minHeight: 3),
        if (error != null) _ErrorCard(error!, onRetry: _load),
        if (loaded!.fromCache) _SavedNote(loaded!.savedAt),
        _header(name, data),
        ChoiceRow(
          items: const ['Roster', 'Overview', 'Stats'],
          value: tab,
          light: true,
          onChanged: (v) => setState(() => tab = v),
        ),
        if (tab == 'Roster') ...[
          SearchField(
            hintText: 'Find a player or position',
            onChanged: (v) => setState(() => query = v),
          ),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeading(
                  'Squad',
                  trailing: Tag('${roster.length} REGISTERED'),
                ),
                if (roster.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No players are registered with this club yet.'),
                  )
                else if (visible.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No players match your search.'),
                  ),
                for (final p in visible) _playerTile(p, name),
              ],
            ),
          ),
          if (canManage)
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => _openManage(roster),
              icon: const Icon(Icons.manage_accounts_outlined),
              label: const Text('Manage roster'),
            ),
        ] else if (tab == 'Overview')
          ..._overview(data)
        else
          _stats(data),
        if (widget.state.user?.role == 'super_admin')
          TextButton.icon(
            key: const Key('delete-club'),
            style: TextButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size(48, 48)),
            onPressed: () => _deleteClub(name),
            icon: const Icon(CupertinoIcons.trash),
            label: const Text('Delete club'),
          ),
      ],
    );
  }

  Future<void> _deleteClub(String name) async {
    final ok = await confirmIos(
      context,
      title: 'Delete $name?',
      message: 'Only a club with no fixtures and no registered players can be deleted. This cannot be undone.',
      confirm: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await widget.state.api.send('DELETE', '/api/v1/clubs/$clubId');
      if (!mounted) return;
      notice(context, '$name deleted', kind: ToastKind.success);
      if (Navigator.canPop(context)) Navigator.pop(context);
    } catch (e) {
      if (mounted) notice(context, plainError(e), kind: ToastKind.error);
    }
  }

  Widget _header(String name, Map<String, dynamic> data) {
    final venue = asMap(data['home_venue']);
    final line = [
      widget.state.tenant?.name ?? humanize(asStr(data['tenant_id'])),
      if (venue.isNotEmpty) asStr(venue['name']),
    ].where((s) => s.isNotEmpty).join(' · ');
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: .55), width: 1.4),
        gradient: const LinearGradient(
          colors: [Color(0xFF074569), Color(0xFF149FBE)],
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF041524).withValues(alpha: .28),
            blurRadius: 28,
            spreadRadius: 1,
            offset: const Offset(0, 14),
          ),
          BoxShadow(
            color: ocean.withValues(alpha: .20),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Crest(name, size: 60),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                if (line.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    line,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: .85),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _playerTile(Map<String, dynamic> p, String clubName) {
    final name = asStr(p['name'], 'Unnamed player');
    final reg = asStr(p['registration_type']);
    final isLoan = reg == 'loan';
    final loanEnd = asStr(p['loan_end_date']);
    final waiting = widget.state
        .pendingFor(ActionTypes.rosterTransfer, asStr(p['player_id']))
        .isNotEmpty;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 8,
      leading: CircleAvatar(
        backgroundColor: ocean.withValues(alpha: .09),
        child: Text(
          _initials(name),
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: ocean,
          ),
        ),
      ),
      title: Text(
        name,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        [
          humanize(asStr(p['position'])),
          humanize(asStr(p['role'])),
          if (isLoan && loanEnd.isNotEmpty) 'Loan ends $loanEnd',
          if (waiting) 'Change waiting to sync',
        ].where((s) => s.isNotEmpty).join(' · '),
        style: const TextStyle(fontFamily: 'Inter', fontSize: 11),
      ),
      trailing: Tag(
        _registrationLabel(reg),
        color: isLoan ? _loanColor : green,
      ),
      onTap: () => openPage(
        context,
        PlayerPage(
          state: widget.state,
          playerId: asStr(p['player_id']),
          player: p,
          clubName: clubName,
        ),
      ),
    );
  }

  List<Widget> _overview(Map<String, dynamic> data) {
    final venue = asMap(data['home_venue']);
    final social = asMap(data['social']);
    final staff = [for (final s in asList(data['staff'])) asMap(s)];
    return [
      GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeading('Home venue'),
            if (venue.isEmpty)
              const Text('No home venue has been set for this club.')
            else ...[
              DetailRow('Ground', asStr(venue['name'], 'Unnamed ground')),
              if (venue['lat'] != null && venue['lng'] != null)
                DetailRow('Location', '${venue['lat']}, ${venue['lng']}'),
            ],
          ],
        ),
      ),
      GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeading('Staff'),
            if (staff.isEmpty) const Text('No staff listed yet.'),
            for (final s in staff)
              DetailRow(humanize(asStr(s['role'], 'Staff')), asStr(s['name'])),
          ],
        ),
      ),
      GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeading('Social'),
            if (social.values.every((v) => asStr(v).isEmpty))
              const Text('No social links listed yet.'),
            for (final e in social.entries)
              if (asStr(e.value).isNotEmpty)
                DetailRow(humanize(e.key), asStr(e.value)),
          ],
        ),
      ),
    ];
  }

  Widget _stats(Map<String, dynamic> data) {
    final stats = [for (final s in asList(data['stats'])) asMap(s)];
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading('Season record'),
          if (stats.isEmpty) const Text('No season results recorded yet.'),
          for (final s in stats) ...[
            Text(
              asStr(s['season'], 'Season'),
              style: const TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Tag('Played ${asInt(s['played'])}'),
                Tag('Won ${asInt(s['won'])}', color: green),
                Tag('Drawn ${asInt(s['drawn'])}', color: muted),
                Tag('Lost ${asInt(s['lost'])}', color: _danger),
              ],
            ),
            const Divider(height: 24),
          ],
        ],
      ),
    );
  }
}

// =================================================================== Player

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.state,
    required this.playerId,
    this.player,
    this.clubName,
  });
  final AppState state;
  final String playerId;

  /// The roster row from the club screen, if we came from there.
  final Map<String, dynamic>? player;
  final String? clubName;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  Loaded? loaded;
  Map<String, dynamic>? athlete;
  bool? following;
  bool followBusy = false;
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final r = await widget.state.load(
        '/api/v1/roster/players/${widget.playerId}/history',
      );
      Map<String, dynamic>? ath;
      try {
        final rawAth = await widget.state.api.get('/api/v1/athletes/${widget.playerId}');
        ath = asMap(rawAth);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        loaded = r;
        if (ath != null && ath.isNotEmpty) {
          athlete = ath;
          // The server remembers follows: show the saved state, so the button never starts at "Follow" again.
          if (ath['following'] is bool) following = ath['following'] as bool;
        }
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = plainError(e);
        loading = false;
      });
    }
  }

  Future<void> _toggleFollow() async {
    if (followBusy) return;
    setState(() => followBusy = true);
    try {
      final r = asMap(
        await widget.state.api.send('POST', '/api/v1/athletes/${widget.playerId}/follow/toggle'),
      );
      if (!mounted) return;
      setState(() {
        following = r['following'] == true;
        athlete = {
          ...?athlete,
          'followers_count': asInt(r['followers_count']),
        };
      });
      notice(
        context,
        following == true ? 'Following athlete' : 'Unfollowed athlete',
        kind: ToastKind.success,
      );
    } catch (e) {
      if (mounted) notice(context, plainError(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => followBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final p = widget.player ?? const <String, dynamic>{};
    final raw = loaded?.data;
    final h = asMap(raw);
    final history = [
      for (final e in (raw is List ? raw : asList(h['history']))) asMap(e),
    ];
    final ath = athlete ?? const <String, dynamic>{};
    final name = asStr(p['name'], asStr(ath['name'], humanize(widget.playerId)));
    final pos = asStr(p['position'], asStr(ath['position']));
    final reg = asStr(p['registration_type']);
    final current = asStr(h['current_squad_id'], asStr(p['squad_id']));
    final parent = asStr(h['parent_squad_id']);
    final followers = asInt(ath['followers_count']);
    final career = asMap(ath['career']);
    final vods = [for (final v in asList(ath['vod'])) asMap(v)];
    final waiting = widget.state.pendingFor(
      ActionTypes.rosterTransfer,
      widget.playerId,
    );
    return OceanPage(
      title: 'Player profile',
      actions: [_refreshAction(_load)],
      children: [
        if (loaded?.fromCache ?? false) _SavedNote(loaded!.savedAt),
        GlassCard(
          child: Column(
            children: [
              Crest(name, size: 72),
              const SizedBox(height: 14),
              Text(
                name,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  if (pos.isNotEmpty) Tag(humanize(pos)),
                  Tag('$followers FOLLOWER${followers == 1 ? '' : 'S'}', color: ocean),
                ],
              ),
              const SizedBox(height: 12),
              if (widget.state.user?.playerId != widget.playerId)
              FilledButton.icon(
                key: const Key('follow-athlete-btn'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                onPressed: followBusy ? null : _toggleFollow,
                icon: Icon(
                  following == true ? Icons.person_remove_outlined : Icons.person_add_alt_1,
                ),
                label: Text(
                  following == true ? 'Following · Tap to unfollow' : 'Follow athlete',
                ),
              ),
              const Divider(),
              DetailRow('Player ID', widget.playerId),
              if (current.isNotEmpty)
                DetailRow('Squad', widget.state.teamName(current)),
              if (widget.clubName != null) DetailRow('Club', widget.clubName!),
              if (reg.isNotEmpty)
                DetailRow('Registration', _registrationLabel(reg)),
              if (asStr(p['role']).isNotEmpty)
                DetailRow('Role', humanize(asStr(p['role']))),
              if (parent.isNotEmpty && parent != current)
                DetailRow('Parent squad', widget.state.teamName(parent)),
              if (asStr(p['loan_end_date']).isNotEmpty)
                DetailRow('Loan ends', asStr(p['loan_end_date'])),
              if (asStr(h['league_id']).isNotEmpty)
                DetailRow('League', humanize(asStr(h['league_id']))),
              DetailRow('Deep link', 'nascon://entity/${widget.playerId}'),
            ],
          ),
        ),
        if (career.isNotEmpty)
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeading('Career match record', trailing: Tag('SOCIAL GRAPH')),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Tag('Played ${asInt(career['played'])}'),
                    Tag('Won ${asInt(career['won'])}', color: green),
                    Tag('Drawn ${asInt(career['drawn'])}', color: muted),
                    Tag('Lost ${asInt(career['lost'])}', color: _danger),
                  ],
                ),
                if (vods.isNotEmpty) ...[
                  const Divider(height: 20),
                  const Text(
                    'VOD Archive',
                    style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  for (final v in vods)
                    DetailRow(asStr(v['stream_key'], 'Stream'), asStr(v['object_url'])),
                ],
              ],
            ),
          ),
        if (waiting.isNotEmpty)
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeading(
                  'Waiting to sync',
                  trailing: Tag('SAVED OFFLINE', color: _loanColor),
                ),
                for (final a in waiting)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule, color: _loanColor),
                    title: Text(a.label.isEmpty ? 'Roster change' : a.label),
                    subtitle: Text('Saved ${formatDateTime(a.queuedAt)}'),
                  ),
              ],
            ),
          ),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeading('Registration history'),
              if (loading && loaded == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (error != null && loaded == null) ...[
                Text(error!),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ] else if (history.isEmpty)
                const Text('No registration changes recorded yet.')
              else
                for (final e in history.reversed) _historyTile(e),
            ],
          ),
        ),
      ],
    );
  }

  Widget _historyTile(Map<String, dynamic> e) {
    final action = asStr(e['action']);
    final from = asStr(e['from_squad_id']);
    final to = asStr(e['to_squad_id']);
    final st = asStr(e['state']);
    final move = [
      if (from.isNotEmpty) widget.state.teamName(from),
      if (to.isNotEmpty) widget.state.teamName(to),
    ].join(' → ');
    final details = [
      if (move.isNotEmpty) move,
      if (asStr(e['effective_date']).isNotEmpty)
        'From ${asStr(e['effective_date'])}',
      if (asStr(e['who']).isNotEmpty) 'By ${asStr(e['who'])}',
      if (asStr(e['when']).isNotEmpty) formatDateTime(asStr(e['when'])),
      if (asStr(e['why']).isNotEmpty) '"${asStr(e['why'])}"',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        action == 'release'
            ? Icons.logout
            : action == 'loan'
            ? Icons.swap_horiz
            : Icons.how_to_reg_outlined,
        color: action == 'loan' ? _loanColor : green,
      ),
      title: Text(_actionLabel(action)),
      subtitle: Text(details.join('\n')),
      trailing: st.isEmpty
          ? null
          : Tag(humanize(st), color: st == 'active' ? green : muted),
    );
  }
}

// ============================================================ Manage roster

class ManageRosterPage extends StatefulWidget {
  const ManageRosterPage({
    super.key,
    required this.state,
    this.clubId,
    this.roster,
    this.initialPlayerId,
  });
  final AppState state;
  final String? clubId;

  /// Players to choose from. Loaded from the club when not given.
  final List<Map<String, dynamic>>? roster;
  final String? initialPlayerId;
  @override
  State<ManageRosterPage> createState() => _ManageRosterPageState();
}

enum _Result { none, sent, queued, rejected }

class _ManageRosterPageState extends State<ManageRosterPage> {
  final reason = TextEditingController();
  List<Map<String, dynamic>> roster = [];
  bool loadingRoster = false;
  String? loadError;
  String action = 'transfer';
  String? playerId;
  String? toSquad;
  DateTime effective = DateUtils.dateOnly(DateTime.now());
  DateTime? loanEnd;
  bool sending = false;
  _Result result = _Result.none;
  String resultText = '';

  String get clubId =>
      widget.clubId ?? widget.state.user?.clubId ?? AppState.demoClubs.first;

  @override
  void initState() {
    super.initState();
    if (widget.roster != null && widget.roster!.isNotEmpty) {
      _setRoster(widget.roster!);
    } else {
      _loadRoster();
    }
  }

  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  void _setRoster(List<Map<String, dynamic>> r) {
    roster = r;
    final ids = r.map((p) => asStr(p['player_id'])).toList();
    final keep = playerId ?? widget.initialPlayerId;
    playerId = ids.contains(keep) ? keep : (ids.isEmpty ? null : ids.first);
    _fixSquad();
  }

  Future<void> _loadRoster() async {
    setState(() {
      loadingRoster = true;
      loadError = null;
    });
    try {
      final r = await widget.state.load('/api/v1/clubs/$clubId');
      if (!mounted) return;
      setState(() {
        _setRoster([for (final p in asList(asMap(r.data)['roster'])) asMap(p)]);
        loadingRoster = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loadError = plainError(e);
        loadingRoster = false;
      });
    }
  }

  Map<String, dynamic> get player => roster.firstWhere(
    (p) => asStr(p['player_id']) == playerId,
    orElse: () => const <String, dynamic>{},
  );

  String get fromSquad => asStr(player['squad_id'], clubId);

  List<String> get squads {
    final all = <String>{
      ...AppState.demoClubs,
      clubId,
      for (final p in roster)
        if (asStr(p['squad_id']).isNotEmpty) asStr(p['squad_id']),
    };
    return all.where((s) => s != fromSquad).toList();
  }

  void _fixSquad() {
    final options = squads;
    if (!options.contains(toSquad)) {
      toSquad = options.contains('club-alpha-2')
          ? 'club-alpha-2'
          : (options.isEmpty ? null : options.first);
    }
  }

  void _changed(VoidCallback f) => setState(() {
    f();
    _fixSquad();
    result = _Result.none;
  });

  Future<DateTime?> _pick(DateTime initial, DateTime first) => showIosDatePicker(
    context,
    initial: initial,
    first: first,
    last: DateTime.now().add(const Duration(days: 730)),
  );

  String? _validate() {
    if (playerId == null) return 'Choose a player first.';
    if (action != 'release' && toSquad == null) {
      return 'Choose a destination squad.';
    }
    if (action == 'loan') {
      if (loanEnd == null) return 'Choose when the loan ends.';
      if (!loanEnd!.isAfter(effective)) {
        return 'The loan must end after it starts.';
      }
    }
    if (reason.text.trim().isEmpty) return 'Add a short reason for the record.';
    if (reason.text.trim().length > 200) return 'Keep the reason under 200 characters.';
    return null;
  }

  String get _summary {
    final name = asStr(player['name'], humanize(playerId));
    return switch (action) {
      'release' => 'Release $name from ${widget.state.teamName(fromSquad)}',
      'loan' =>
        'Loan $name to ${widget.state.teamName(toSquad)} until ${isoDate(loanEnd!)}',
      _ => 'Transfer $name to ${widget.state.teamName(toSquad)}',
    };
  }

  Future<void> _submit() async {
    final problem = _validate();
    if (problem != null) {
      setState(() {
        result = _Result.rejected;
        resultText = problem;
      });
      return;
    }
    final summary = _summary;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Confirm roster change'),
        content: Text(
          '$summary, starting ${isoDate(effective)}.\n\n'
          'Reason: ${reason.text.trim()}',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      sending = true;
      result = _Result.none;
    });
    final body = <String, dynamic>{
      'request_id': newId(),
      'league_id': widget.state.rosterLeagueId,
      'player_id': playerId,
      'type': action,
      'from_squad_id': fromSquad,
      'to_squad_id': action == 'release' ? null : toSquad,
      'effective_date': isoDate(effective),
      'loan_end_date': action == 'loan' ? isoDate(loanEnd!) : null,
      'reason': reason.text.trim(),
      'requested_by': widget.state.user?.userId,
    };
    try {
      final outcome = await widget.state.submitRosterAction(
        body: body,
        label: summary,
      );
      if (!mounted) return;
      setState(() {
        sending = false;
        if (outcome.queued) {
          result = _Result.queued;
          resultText =
              'Saved offline – will sync. "$summary" will be sent '
              'automatically when the connection is back.';
        } else {
          result = _Result.sent;
          resultText = 'Done. "$summary" has been saved on the server.';
          reason.clear();
        }
      });
      if (outcome.queued) {
        notice(context, 'Saved offline – will sync');
      } else {
        notice(context, 'Roster updated', kind: ToastKind.success);
        _loadRoster();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        sending = false;
        result = _Result.rejected;
        resultText = plainError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final user = widget.state.user;
    if (user == null || !user.canManageRoster) {
      return OceanPage(
        title: 'Manage roster',
        children: [
          GlassCard(
            child: Column(
              children: [
                const Icon(Icons.lock_outline, size: 40, color: ocean),
                const SizedBox(height: 12),
                const Text(
                  'Only club managers and platform admins can change a roster.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  user == null
                      ? 'Please sign in first.'
                      : 'You are signed in as ${Roles.label(user.role)}, so you can view the squad but not change it.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return OceanPage(
      title: 'Manage roster',
      subtitle: widget.state.teamName(clubId).toUpperCase(),
      children: [
        if (!widget.state.isOnline)
          const GlassCard(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.cloud_off_outlined, color: _loanColor),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'You are offline. Changes are saved on this phone and sent when you reconnect.',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: ink),
                  ),
                ),
              ],
            ),
          ),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('add-player'),
              onPressed: () async {
                final added = await Navigator.of(context).push<bool>(MaterialPageRoute(
                  builder: (_) => AddPlayerPage(state: widget.state, clubId: clubId),
                ));
                if (added == true) _loadRoster();
              },
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add a new player'),
            ),
          ),
        ),
        if (loadingRoster && roster.isEmpty) const _Busy('Loading players…'),
        if (loadError != null && roster.isEmpty)
          _ErrorCard(loadError!, onRetry: _loadRoster),
        if (!loadingRoster && loadError == null && roster.isEmpty)
          const EmptyCard(
            'No players yet',
            'This club has no registered players to move.',
          ),
        if (roster.isNotEmpty) _form(),
        if (result != _Result.none) _resultCard(),
        if (widget.state.pending.isNotEmpty) _pendingCard(),
      ],
    );
  }

  Widget _form() {
    String playerLabel(Map<String, dynamic> p) => [
      asStr(p['name'], asStr(p['player_id'])),
      humanize(asStr(p['position'])),
    ].where((x) => x.isNotEmpty).join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormSection(
          header: 'Roster action',
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoSlidingSegmentedControl<String>(
                  groupValue: action,
                  children: {
                    for (final item in const ['transfer', 'loan', 'release'])
                      item: Padding(padding: const EdgeInsets.all(10), child: Text(_actionLabel(item))),
                  },
                  onValueChanged: (v) => _changed(() => action = v ?? 'transfer'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        FormSection(
          header: 'Details',
          footer: 'Currently in ${widget.state.teamName(fromSquad)}'
              '${asStr(player['registration_type']) == 'loan' ? ' (on loan)' : ''}. '
              'The server checks the transfer window, squad size and positions.',
          children: [
            PickerRow<String>(
              key: ValueKey('player-$playerId-${roster.length}'),
              label: 'Player',
              sheetTitle: 'Choose a player',
              initialValue: playerId ?? '',
              options: [
                for (final p in roster)
                  PickerOption(value: asStr(p['player_id']), label: playerLabel(p), icon: CupertinoIcons.person),
              ],
              onChanged: (v) => _changed(() => playerId = v),
            ),
            if (action != 'release')
              PickerRow<String>(
                key: ValueKey('squad-$toSquad-$fromSquad'),
                label: 'Destination',
                sheetTitle: 'Move to which squad?',
                initialValue: toSquad ?? '',
                options: [
                  for (final sq in squads)
                    PickerOption(value: sq, label: widget.state.teamName(sq), icon: CupertinoIcons.shield),
                ],
                onChanged: (v) => _changed(() => toSquad = v),
              ),
            ValueRow(
              label: 'Effective from',
              value: isoDate(effective),
              icon: CupertinoIcons.calendar,
              onTap: () async {
                final d = await _pick(effective, DateTime.now().subtract(const Duration(days: 365)));
                if (d != null && mounted) _changed(() => effective = d);
              },
            ),
            if (action == 'loan')
              ValueRow(
                label: 'Loan ends',
                value: loanEnd == null ? 'Choose' : isoDate(loanEnd!),
                icon: CupertinoIcons.calendar_badge_plus,
                onTap: () async {
                  final d = await _pick(
                    loanEnd ?? effective.add(const Duration(days: 30)),
                    effective.add(const Duration(days: 1)),
                  );
                  if (d != null && mounted) _changed(() => loanEnd = d);
                },
              ),
            TextRow(label: 'Reason', hint: 'e.g. Needs more match time', controller: reason, maxLines: 3),
          ],
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          label: sending ? 'Sending…' : 'Review and submit',
          icon: CupertinoIcons.paperplane,
          busy: sending,
          onPressed: _submit,
        ),
      ],
    );
  }

  Widget _resultCard() {
    final (label, color, icon) = switch (result) {
      _Result.sent => ('SAVED', green, Icons.check_circle_outline),
      _Result.queued => ('SAVED OFFLINE', _loanColor, Icons.schedule),
      _ => ('NOT SAVED', _danger, Icons.error_outline),
    };
    return Semantics(
      liveRegion: true,
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Tag(label, color: color, icon: icon),
            const SizedBox(height: 12),
            Text(
              resultText,
              style: const TextStyle(fontFamily: 'Inter', color: ink),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pendingCard() => GlassCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(
          'Waiting to sync',
          trailing: Tag('${widget.state.pending.length}', color: _loanColor),
        ),
        for (final a in widget.state.pending)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              a.type == ActionTypes.rosterTransfer
                  ? Icons.swap_horiz
                  : Icons.sports_score,
              color: _loanColor,
            ),
            title: Text(a.label.isEmpty ? humanize(a.type) : a.label),
            subtitle: Text('Saved ${formatDateTime(a.queuedAt)}'),
          ),
      ],
    ),
  );
}


/// FR-2.2 / spec 8.2 "add": register a brand-new player in this club's squad (online only).
class AddPlayerPage extends StatefulWidget {
  const AddPlayerPage({super.key, required this.state, required this.clubId});
  final AppState state;
  final String clubId;

  @override
  State<AddPlayerPage> createState() => _AddPlayerPageState();
}

class _AddPlayerPageState extends State<AddPlayerPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _position = TextEditingController();
  final _reason = TextEditingController();
  String _role = 'substitute';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _position, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.state.api.post('/api/v1/roster/players', {
        'league_id': widget.state.rosterLeagueId,
        'squad_id': widget.clubId,
        'name': _name.text.trim(),
        'position': _position.text.trim().toLowerCase(),
        'role': _role,
        'reason': _reason.text.trim().isEmpty ? null : _reason.text.trim(),
      });
      if (!mounted) return;
      notice(context, '${_name.text.trim()} added to ${widget.state.teamName(widget.clubId)}',
          kind: ToastKind.success);
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = plainError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;

  @override
  Widget build(BuildContext context) => OceanPage(
    title: 'Add player',
    subtitle: widget.state.teamName(widget.clubId).toUpperCase(),
    children: [
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.state.isOnline) ...[
              const FormError('Adding a player needs a connection. Try again when you are back online.'),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[FormError(_error!), const SizedBox(height: 16)],
            FormSection(
              header: 'Player',
              children: [
                TextRow(
                  fieldKey: const Key('player-name'),
                  label: 'Full name',
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  validator: _required,
                ),
                TextRow(
                  fieldKey: const Key('player-position'),
                  label: 'Position',
                  hint: 'e.g. gk, df, mf, fw',
                  controller: _position,
                  validator: _required,
                ),
                PickerRow<String>(
                  label: 'Squad role',
                  initialValue: _role,
                  onChanged: (v) => setState(() => _role = v),
                  options: const [
                    PickerOption(value: 'captain', label: 'Captain', icon: CupertinoIcons.star_fill),
                    PickerOption(value: 'vice_captain', label: 'Vice-captain', icon: CupertinoIcons.star_lefthalf_fill),
                    PickerOption(value: 'starter', label: 'Starter', icon: CupertinoIcons.sportscourt),
                    PickerOption(value: 'substitute', label: 'Substitute', icon: CupertinoIcons.arrow_2_squarepath),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            FormSection(
              header: 'History',
              footer: 'Kept in the player\'s permanent roster history.',
              children: [TextRow(label: 'Reason (optional)', controller: _reason, maxLines: 2)],
            ),
            const SizedBox(height: 24),
            PrimaryButton(
              key: const Key('save-player'),
              label: 'Add to squad',
              icon: CupertinoIcons.person_add,
              busy: _saving,
              onPressed: widget.state.isOnline ? _save : null,
            ),
          ],
        ),
      ),
    ],
  );
}
