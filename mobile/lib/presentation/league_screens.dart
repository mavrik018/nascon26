import 'dart:async';

import 'package:flutter/material.dart';

import '../toolkit/02_ui_elements/pressable.dart';

import '../core/api_client.dart';
import '../core/app_state.dart';
import '../core/format.dart';
import '../core/models.dart';
import 'ocean_widgets.dart';

const _live = Color(0xFFBE3450);
const _away = Color(0xFFA86C2E);
const _red = Color(0xFFB3261E);

// --------------------------------------------------------------- helpers

/// Team id + display name from a fixture side (plain id or an object).
(String, String) _team(AppState state, Object? side) {
  if (side is Map) {
    final id = asStr(side['team_id'] ?? side['club_id'] ?? side['id']);
    final name = asStr(side['name']);
    if (name.isNotEmpty) state.rememberTeamName(id, name);
    return (id, name.isNotEmpty ? name : state.teamName(id));
  }
  final id = asStr(side);
  return (id, id.isEmpty ? 'TBD' : state.teamName(id));
}

String _statusLabel(String status) => switch (status) {
  'in_progress' => 'Live',
  'completed' => 'Results',
  _ => 'Upcoming',
};

String _clock(String? raw) {
  final t = DateTime.tryParse(raw ?? '');
  if (t == null) return 'TBA';
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String _errorText(Object e) =>
    e is ApiException ? e.message : 'Something went wrong. Please try again.';

/// "Saved data (offline)" strip shown when a screen comes from the cache.
class _CachedBanner extends StatelessWidget {
  const _CachedBanner(this.loaded);
  final Loaded loaded;
  @override
  Widget build(BuildContext context) {
    final ago = formatSavedAgo(loaded.savedAt);
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            const Icon(Icons.cloud_off_outlined, color: ocean, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                ago.isEmpty
                    ? 'Saved data (offline)'
                    : 'Saved data (offline) · saved $ago',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => GlassCard(
    child: Semantics(
      label: label,
      child: const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: CircularProgressIndicator(),
        ),
      ),
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
        const Icon(Icons.error_outline, size: 36, color: _red),
        const SizedBox(height: 10),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      ],
    ),
  );
}

/// League dropdown (loads /api/v1/leagues; falls back to the current id).
class _LeaguePicker extends StatefulWidget {
  const _LeaguePicker({
    required this.state,
    required this.value,
    required this.onChanged,
  });
  final AppState state;
  final String value;
  final ValueChanged<String> onChanged;
  @override
  State<_LeaguePicker> createState() => _LeaguePickerState();
}

class _LeaguePickerState extends State<_LeaguePicker> {
  List<Map<String, dynamic>> leagues = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.state.load('/api/v1/leagues');
      final raw = loaded.data is Map
          ? asMap(loaded.data)['leagues']
          : loaded.data;
      if (!mounted) return;
      setState(() => leagues = [for (final l in asList(raw)) asMap(l)]);
    } catch (_) {
      // Keep showing the current league only.
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = <String, String>{
      for (final l in leagues)
        asStr(l['league_id']): asStr(l['name'], humanize(asStr(l['league_id']))),
    };
    items.putIfAbsent(widget.value, () => humanize(widget.value));
    return GlassCard(
      opacity: .2,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      child: Semantics(
        label: 'Choose league',
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: widget.value,
            isExpanded: true,
            itemHeight: 48,
            dropdownColor: ocean,
            icon: const Icon(Icons.expand_more, color: Colors.white),
            style: const TextStyle(
              fontFamily: 'Inter',
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            items: [
              for (final e in items.entries)
                DropdownMenuItem(
                  value: e.key,
                  child: Text(
                    e.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null && v != widget.value) widget.onChanged(v);
            },
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- fixtures

class FixturesPage extends StatefulWidget {
  const FixturesPage({super.key, required this.state});
  final AppState state;
  @override
  State<FixturesPage> createState() => _FixturesPageState();
}

class _FixturesPageState extends State<FixturesPage> {
  String filter = 'All';
  late String leagueId = widget.state.leagueId;
  Loaded? loaded;
  Object? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => loading = true);
    try {
      final result = await widget.state.load(
        '/api/v1/leagues/$leagueId/fixtures',
      );
      if (!mounted) return;
      setState(() {
        loaded = result;
        error = null;
        loading = false;
      });
      final ids = [for (final f in _list()) asStr(f['match_id'])];
      widget.state.prefetch([for (final id in ids) '/api/v1/matches/$id']);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e;
        loading = false;
      });
    }
  }

  List<Map<String, dynamic>> _list() {
    final d = loaded?.data;
    final raw = d is Map ? d['fixtures'] ?? d['matches'] : d;
    final list = [for (final f in asList(raw)) asMap(f)];
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
    return list;
  }

  Future<void> _pickLeague(String id) async {
    setState(() {
      leagueId = id;
      loaded = null;
    });
    await widget.state.selectLeague(id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final all = _list();
      final shown = filter == 'All'
          ? all
          : all
                .where((f) => _statusLabel(asStr(f['status'])) == filter)
                .toList();
      return RefreshIndicator(
        onRefresh: _refresh,
        child: OceanPage(
          title: 'Fixtures',
          actions: [
            IconButton(
              tooltip: 'Refresh fixtures',
              onPressed: loading ? null : _refresh,
              icon: const Icon(Icons.refresh, color: Colors.white),
            ),
          ],
          children: [
            _LeaguePicker(
              state: widget.state,
              value: leagueId,
              onChanged: _pickLeague,
            ),
            ChoiceRow(
              items: const ['All', 'Live', 'Upcoming', 'Results'],
              value: filter,
              light: true,
              onChanged: (v) => setState(() => filter = v),
            ),
            if (loaded?.fromCache ?? false) _CachedBanner(loaded!),
            if (loaded == null && loading)
              const _LoadingCard('Loading fixtures')
            else if (loaded == null && error != null)
              _ErrorCard(_errorText(error!), onRetry: _refresh)
            else if (all.isEmpty)
              const EmptyCard(
                'No matches yet',
                'Fixtures appear here once the organizer schedules them.',
              )
            else if (shown.isEmpty)
              EmptyCard(
                'No ${filter.toLowerCase()} matches',
                'Try another filter to see the other matches.',
              )
            else
              for (final f in shown) _fixtureCard(context, f),
          ],
        ),
      );
    },
  );

  Widget _fixtureCard(BuildContext context, Map<String, dynamic> f) {
    final state = widget.state;
    final (_, home) = _team(state, f['home'] ?? f['home_team_id']);
    final (_, away) = _team(state, f['away'] ?? f['away_team_id']);
    final matchId = asStr(f['match_id']);
    return _LiveMatchCard(
      home: home,
      away: away,
      status: asStr(f['status'], 'upcoming'),
      homeScore: asStr(f['home_score'], '0'),
      awayScore: asStr(f['away_score'], '0'),
      scheduledAt: asStr(f['scheduled_at']),
      pending: state.pendingFor(ActionTypes.scoreEvent, matchId).length,
      onTap: () =>
          openPage(context, MatchPage(state: state, matchId: matchId)),
    );
  }
}

/// Laptop 2's match card, fed with live values.
class _LiveMatchCard extends StatelessWidget {
  const _LiveMatchCard({
    required this.home,
    required this.away,
    required this.status,
    required this.homeScore,
    required this.awayScore,
    required this.scheduledAt,
    this.pending = 0,
    this.onTap,
  });
  final String home, away, status, homeScore, awayScore, scheduledAt;
  final int pending;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final upcoming = status == 'upcoming';
    final live = status == 'in_progress';
    final label = _statusLabel(status);
    final scoreText = upcoming ? _clock(scheduledAt) : '$homeScore – $awayScore';
    return Pressable(
      onTap: onTap,
      semanticLabel:
          '$home versus $away, ${upcoming ? 'upcoming at $scoreText' : '${live ? 'live' : 'final'}, $homeScore to $awayScore'}'
          '${pending > 0 ? ', $pending pending sync' : ''}. Open match.',
      child: GlassCard(
        child: Column(
          children: [
            Row(
              children: [
                Tag(
                  live
                      ? '● LIVE'
                      : status == 'completed'
                      ? 'FULL TIME'
                      : label.toUpperCase(),
                  color: live ? _live : ocean,
                ),
                if (pending > 0) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Tag(
                      '$pending pending sync',
                      icon: Icons.cloud_upload_outlined,
                      color: _away,
                    ),
                  ),
                ],
                const Spacer(),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: _side(home, 'Home', ocean)),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .8),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        FittedBox(
                          child: Text(
                            scoreText,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 30,
                              fontWeight: FontWeight.w800,
                              color: ink,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          upcoming
                              ? 'KICK-OFF'
                              : live
                              ? 'IN PROGRESS'
                              : 'FINAL',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 8,
                            letterSpacing: 1,
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(child: _side(away, 'Away', _away)),
              ],
            ),
            const Divider(),
            Row(
              children: [
                const Icon(Icons.schedule, size: 16, color: ocean),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    formatDateTime(scheduledAt),
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      color: muted,
                    ),
                  ),
                ),
                if (onTap != null) const Flexible(child: Tag('Match detail →')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _side(String name, String label, Color color) => Column(
    children: [
      Crest(name.isEmpty ? '?' : name, color: color),
      const SizedBox(height: 8),
      Text(
        name,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        label,
        style: const TextStyle(fontFamily: 'Inter', fontSize: 10, color: muted),
      ),
    ],
  );
}

// --------------------------------------------------------------- match

class MatchPage extends StatefulWidget {
  const MatchPage({super.key, required this.state, required this.matchId});
  final AppState state;
  final String matchId;
  @override
  State<MatchPage> createState() => _MatchPageState();
}

class _MatchPageState extends State<MatchPage> {
  static const _correctable = {'score', 'discipline', 'tiebreak_winner'};

  Loaded? loaded;
  Object? error;
  bool busy = false;
  String tab = 'Timeline';
  Timer? _poll;

  AppState get state => widget.state;
  String get _path => '/api/v1/matches/${widget.matchId}';
  Map<String, dynamic> get data => asMap(loaded?.data);
  bool get canScore {
    final role = state.user?.role;
    return role == 'league_organizer' || role == 'super_admin';
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    // Live score: poll every 5 s while this page is open.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (state.hasNetwork && asStr(data['status']) != 'completed') _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final result = await state.load(_path);
      if (!mounted) return;
      setState(() {
        loaded = result;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e);
    }
  }

  String _name(String? id) => state.teamName(id);

  String _eventTitle(Map<String, dynamic> e) {
    final p = asMap(e['payload']);
    return switch (asStr(e['type'])) {
      'match_init' => 'Match created',
      'match_start' => 'Match started',
      'match_end' => 'Match ended',
      'score' =>
        '${humanize(asStr(p['event_type'], 'score'))} – ${_name(asStr(p['team_id']))}',
      'discipline' =>
        'Discipline ${asStr(p['points'])} – ${_name(asStr(p['team_id']))}'
            .replaceAll('  ', ' '),
      'tiebreak_winner' =>
        'Tie-break won by ${_name(asStr(p['team_id']))}',
      'compensation' =>
        'Correction${asStr(p['reason']).isEmpty ? '' : ': ${asStr(p['reason'])}'}',
      final t => humanize(t),
    };
  }

  IconData _eventIcon(String type) => switch (type) {
    'match_init' => Icons.event_note,
    'match_start' => Icons.play_circle_outline,
    'match_end' => Icons.flag_outlined,
    'score' => Icons.sports_score,
    'discipline' => Icons.style_outlined,
    'tiebreak_winner' => Icons.emoji_events_outlined,
    'compensation' => Icons.undo,
    _ => Icons.sports,
  };

  Future<void> _submit(Map<String, dynamic> body, String label, String done) async {
    setState(() => busy = true);
    try {
      final outcome = await state.submitMatchEvent(
        matchId: widget.matchId,
        body: body,
        label: label,
      );
      if (!mounted) return;
      if (outcome.queued) {
        notice(
          context,
          'You are offline. "$label" is saved on this phone as pending sync and will be sent automatically.',
        );
      } else {
        notice(context, done);
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) notice(context, e.message);
    } catch (_) {
      if (mounted) notice(context, 'That could not be saved. Please try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _confirm(String title, String message, String yes) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(yes),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _addScore() async {
    final homeId = asStr(asMap(data['home'])['team_id']);
    final awayId = asStr(asMap(data['away'])['team_id']);
    final types = [
      for (final t in asList(data['event_types']))
        asStr(t is Map ? t['name'] ?? t['type'] : t),
    ]..removeWhere((t) => t.isEmpty);
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ScoreSheet(
        teams: [(homeId, _name(homeId)), (awayId, _name(awayId))],
        eventTypes: types,
      ),
    );
    if (result == null || !mounted) return;
    final (teamId, eventType) = result;
    final label = '${humanize(eventType)} for ${_name(teamId)}';
    if (!await _confirm('Add score event?', 'Record "$label" in this match?', 'Add')) {
      return;
    }
    await _submit(
      {
        'event_id': newId('m'),
        'match_id': widget.matchId,
        'type': 'score',
        'payload': {'team_id': teamId, 'event_type': eventType},
      },
      label,
      'Score added: $label',
    );
  }

  List<Map<String, dynamic>> get _correctableEvents => [
    for (final e in asList(data['events']).map(asMap))
      if (e['compensated'] != true &&
          _correctable.contains(asStr(e['type'])))
        e,
  ].reversed.toList();

  Future<void> _pickCorrection() async {
    final events = _correctableEvents;
    if (events.isEmpty) {
      notice(context, 'There are no score events that can be corrected.');
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * .7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              const SectionHeading('Which event is wrong?'),
              for (final e in events)
                ListTile(
                  minTileHeight: 56,
                  leading: Icon(_eventIcon(asStr(e['type'])), color: ocean),
                  title: Text(_eventTitle(e)),
                  subtitle: Text('Event #${asStr(e['sequence'])}'),
                  onTap: () => Navigator.pop(ctx, e),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) await _compensate(picked);
  }

  Future<void> _compensate(Map<String, dynamic> event) async {
    final reasonCtrl = TextEditingController(text: 'Scoring correction');
    final label = _eventTitle(event);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Correct this event?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '"$label" will be cancelled by a correction. It stays in the timeline, struck through, and no longer counts.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonCtrl,
                decoration: const InputDecoration(labelText: 'Reason'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Correct'),
          ),
        ],
      ),
    );
    final reason = reasonCtrl.text.trim().isEmpty
        ? 'Scoring correction'
        : reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (ok != true || !mounted) return;
    await _submit(
      {
        'event_id': newId('m'),
        'match_id': widget.matchId,
        'type': 'compensation',
        'payload': {'compensates': asStr(event['event_id']), 'reason': reason},
      },
      'Correction of "$label"',
      'Correction recorded',
    );
  }

  Future<void> _transition(String type, String label) async {
    if (!await _confirm('$label?', 'This changes the match status for everyone.', label)) {
      return;
    }
    await _submit(
      {
        'event_id': newId('m'),
        'match_id': widget.matchId,
        'type': type,
        'payload': <String, dynamic>{},
      },
      label,
      '$label: done',
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final pending = state.pendingFor(ActionTypes.scoreEvent, widget.matchId);
      return RefreshIndicator(
        onRefresh: _refresh,
        child: OceanPage(
          title: 'Match centre',
          subtitle: humanize(asStr(data['league_id'], 'Match')).toUpperCase(),
          actions: [
            IconButton(
              tooltip: 'Refresh score',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, color: Colors.white),
            ),
          ],
          children: [
            if (loaded?.fromCache ?? false) _CachedBanner(loaded!),
            if (loaded == null && error == null)
              const _LoadingCard('Loading match')
            else if (loaded == null)
              _ErrorCard(_errorText(error!), onRetry: _refresh)
            else ...[
              _scoreCard(context),
              ?_pinned(),
              if (canScore) _scoringDesk(context),
              ChoiceRow(
                items: const ['Timeline', 'Match info'],
                value: tab,
                light: true,
                onChanged: (v) => setState(() => tab = v),
              ),
              if (tab == 'Timeline')
                _timeline(context, pending)
              else
                _info(),
            ],
          ],
        ),
      );
    },
  );

  Widget _scoreCard(BuildContext context) {
    final home = asMap(data['home']);
    final away = asMap(data['away']);
    final status = asStr(data['status'], 'upcoming');
    String scoreOf(Map<String, dynamic> s) {
      final v = asStr(s['score'], '0');
      return s['wickets'] != null ? '$v/${s['wickets']}' : v;
    }

    final outcome = asStr(data['outcome']);
    final result = switch (outcome) {
      'home_win' || 'away_win' => '${_name(asStr(data['winner_team_id']))} won',
      'draw' => 'Draw',
      'undecided' => 'Result undecided',
      _ =>
        status == 'in_progress'
            ? 'In play · updates every 5 seconds'
            : status == 'completed'
            ? 'Full time'
            : 'Not started yet',
    };
    return _LiveMatchCard(
      home: _name(asStr(home['team_id'])),
      away: _name(asStr(away['team_id'])),
      status: status,
      homeScore: scoreOf(home),
      awayScore: scoreOf(away),
      scheduledAt: asStr(data['scheduled_at']),
    ).withResult(result);
  }

  Widget? _pinned() {
    final p = data['pinned_product'];
    if (p is! Map) return null;
    final product = asMap(p);
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Semantics(
        container: true,
        label: 'Featured product',
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ocean.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.shopping_bag_outlined, color: ocean),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Tag('FEATURED IN THIS MATCH'),
                  const SizedBox(height: 6),
                  Text(
                    asStr(product['name'], 'Featured product'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    formatMoney(
                      asInt(product['price_minor']),
                      asStr(product['currency'], 'PKR'),
                    ),
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w700,
                      color: ocean,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scoringDesk(BuildContext context) {
    final status = asStr(data['status'], 'upcoming');
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeading('Scoring desk', trailing: Tag('ORGANIZER')),
          FilledButton.icon(
            key: const Key('add-score'),
            onPressed: busy ? null : _addScore,
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('Add score event'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('correct-event'),
            onPressed: busy ? null : _pickCorrection,
            icon: const Icon(Icons.undo),
            label: const Text('Correct an event'),
          ),
          if (status == 'upcoming' || status == 'in_progress') ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : status == 'upcoming'
                  ? () => _transition('match_start', 'Start match')
                  : () => _transition('match_end', 'End match'),
              icon: Icon(
                status == 'upcoming' ? Icons.play_arrow : Icons.stop,
              ),
              label: Text(status == 'upcoming' ? 'Start match' : 'End match'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _timeline(BuildContext context, List<PendingAction> pending) {
    final events = [
      for (final e in asList(data['events'])) asMap(e),
    ].reversed.toList();
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading('Match events', trailing: Tag('EVENT HISTORY')),
          for (final a in pending)
            _eventRow(
              sequence: '…',
              title: a.label.isEmpty ? 'Score event' : a.label,
              subtitle: 'Saved on this phone ${formatDateTime(a.queuedAt)}',
              icon: Icons.cloud_upload_outlined,
              tag: const Tag(
                'PENDING SYNC',
                icon: Icons.schedule,
                color: _away,
              ),
            ),
          if (events.isEmpty && pending.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('No events yet. Score updates appear here as they happen.'),
            ),
          for (final e in events) _eventFromServer(e),
        ],
      ),
    );
  }

  Widget _eventFromServer(Map<String, dynamic> e) {
    final type = asStr(e['type']);
    final compensated = e['compensated'] == true;
    final canCorrect =
        canScore && !compensated && _correctable.contains(type);
    return _eventRow(
      sequence: asStr(e['sequence']).padLeft(2, '0'),
      title: _eventTitle(e),
      subtitle: compensated
          ? 'Corrected · does not count'
          : type == 'compensation'
          ? 'Cancels an earlier event'
          : humanize(type),
      icon: _eventIcon(type),
      struck: compensated,
      tag: compensated
          ? const Tag('CORRECTED', icon: Icons.undo, color: muted)
          : null,
      trailing: canCorrect
          ? TextButton(
              onPressed: busy ? null : () => _compensate(e),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Text('Correct'),
            )
          : null,
    );
  }

  Widget _eventRow({
    required String sequence,
    required String title,
    required String subtitle,
    required IconData icon,
    bool struck = false,
    Widget? tag,
    Widget? trailing,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            sequence,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 10,
              color: muted,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: struck ? muted : ocean, size: 19),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  color: struck ? muted : ink,
                  decoration: struck ? TextDecoration.lineThrough : null,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  color: muted,
                ),
              ),
              if (tag != null) ...[const SizedBox(height: 4), tag],
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );

  Widget _info() => GlassCard(
    child: Column(
      children: [
        const SectionHeading('Match information'),
        DetailRow('Home', _name(asStr(asMap(data['home'])['team_id']))),
        DetailRow('Away', _name(asStr(asMap(data['away'])['team_id']))),
        DetailRow('Sport', humanize(asStr(data['sport_id'], '—'))),
        DetailRow('League', humanize(asStr(data['league_id'], '—'))),
        DetailRow('Scheduled', formatDateTime(asStr(data['scheduled_at']))),
        DetailRow('Status', _statusLabel(asStr(data['status']))),
        DetailRow('Events recorded', '${asList(data['events']).length}'),
      ],
    ),
  );
}

extension on _LiveMatchCard {
  /// Match card with a result line underneath (used on the match page).
  Widget withResult(String result) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(liveRegion: true, child: this),
      const SizedBox(height: 10),
      Text(
        result,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    ],
  );
}

class _ScoreSheet extends StatefulWidget {
  const _ScoreSheet({required this.teams, required this.eventTypes});
  final List<(String, String)> teams;
  final List<String> eventTypes;
  @override
  State<_ScoreSheet> createState() => _ScoreSheetState();
}

class _ScoreSheetState extends State<_ScoreSheet> {
  late String team = widget.teams.first.$1;
  late String? type = widget.eventTypes.isEmpty ? null : widget.eventTypes.first;
  final custom = TextEditingController();

  @override
  void dispose() {
    custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chosen = widget.eventTypes.isEmpty ? custom.text.trim() : type;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeading('New score event'),
            const Text('Team'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (id, name) in widget.teams)
                  ChoiceChip(
                    label: Text(name),
                    selected: team == id,
                    onSelected: (_) => setState(() => team = id),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Event'),
            const SizedBox(height: 8),
            if (widget.eventTypes.isEmpty)
              TextField(
                controller: custom,
                decoration: const InputDecoration(labelText: 'Event type'),
                onChanged: (_) => setState(() {}),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in widget.eventTypes)
                    ChoiceChip(
                      label: Text(humanize(t)),
                      selected: type == t,
                      onSelected: (_) => setState(() => type = t),
                    ),
                ],
              ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: (chosen == null || chosen.isEmpty)
                  ? null
                  : () => Navigator.pop(context, (team, chosen)),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- standings

const _criteria = {
  'h2h_points': 'head-to-head points',
  'h2h_diff': 'head-to-head difference',
  'overall_diff': 'overall difference',
  'scored': 'scored',
  'fair_play': 'fair play',
  'draw_lots': 'drawing lots',
};

(IconData, String, Color) _qualification(String status) => switch (status) {
  'clinched' => (Icons.check_circle, 'Qualified', green),
  'eliminated' => (Icons.cancel_outlined, 'Out', _red),
  _ => (Icons.help_outline, 'Still possible', muted),
};

class StandingsPage extends StatefulWidget {
  const StandingsPage({super.key, required this.state});
  final AppState state;
  @override
  State<StandingsPage> createState() => _StandingsPageState();
}

class _StandingsPageState extends State<StandingsPage> {
  late String leagueId = widget.state.leagueId;
  Loaded? loaded;
  Object? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => loading = true);
    try {
      final result = await widget.state.load(
        '/api/v1/leagues/$leagueId/standings',
      );
      if (!mounted) return;
      setState(() {
        loaded = result;
        error = null;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e;
        loading = false;
      });
    }
  }

  Future<void> _pickLeague(String id) async {
    setState(() {
      leagueId = id;
      loaded = null;
    });
    await widget.state.selectLeague(id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final d = loaded?.data;
    final rows = [
      for (final r in asList(d is Map ? d['table'] : d)) asMap(r),
    ]..sort((a, b) => asInt(a['rank']).compareTo(asInt(b['rank'])));
    return RefreshIndicator(
      onRefresh: _refresh,
      child: OceanPage(
        title: 'Standings',
        actions: [
          IconButton(
            tooltip: 'Refresh standings',
            onPressed: loading ? null : _refresh,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
        ],
        children: [
          _LeaguePicker(
            state: widget.state,
            value: leagueId,
            onChanged: _pickLeague,
          ),
          if (loaded?.fromCache ?? false) _CachedBanner(loaded!),
          if (loaded == null && loading)
            const _LoadingCard('Loading standings')
          else if (loaded == null && error != null)
            _ErrorCard(_errorText(error!), onRetry: _refresh)
          else if (rows.isEmpty)
            const EmptyCard(
              'The table starts here',
              'No completed matches in this league yet.',
            )
          else ...[
            _leader(context, rows.first),
            _table(rows),
            _notes(rows),
          ],
        ],
      ),
    );
  }

  Widget _leader(BuildContext context, Map<String, dynamic> row) {
    final name = widget.state.teamName(asStr(row['team_id']));
    return GlassCard(
      child: Row(
        children: [
          Crest(name, size: 62),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Tag('LEAGUE LEADERS', icon: Icons.emoji_events_outlined),
                const SizedBox(height: 8),
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  'Top of the table · ${asInt(row['played'])} played',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    color: muted,
                  ),
                ),
              ],
            ),
          ),
          Semantics(
            label: '${asInt(row['points'])} points',
            excludeSemantics: true,
            child: Text(
              '${asInt(row['points'])}',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: ocean,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(List<Map<String, dynamic>> rows) => GlassCard(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(
          humanize(leagueId),
          trailing: const Tag('TABLE'),
        ),
        const Text(
          'P Played · W Won · D Drawn · L Lost · GD Difference · Pts Points',
          style: TextStyle(fontFamily: 'Inter', fontSize: 10, color: muted),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                horizontalMargin: 2,
                columnSpacing: 14,
                headingRowHeight: 36,
                dataRowMinHeight: 56,
                dataRowMaxHeight: 72,
                headingTextStyle: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: muted,
                ),
                dataTextStyle: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  color: ink,
                ),
                columns: [
                  for (final label in ['Club', 'P', 'W', 'D', 'L', 'GD', 'Pts'])
                    DataColumn(label: Text(label), numeric: label != 'Club'),
                ],
                rows: [for (final r in rows) _row(r)],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  DataRow _row(Map<String, dynamic> r) {
    final rank = asInt(r['rank']);
    final name = widget.state.teamName(asStr(r['team_id']));
    final (icon, label, color) = _qualification(asStr(r['status']));
    final diff = asInt(r['diff']);
    return DataRow(
      color: WidgetStatePropertyAll(
        rank == 1 ? ocean.withValues(alpha: .08) : Colors.transparent,
      ),
      cells: [
        DataCell(
          Semantics(
            label: 'Rank $rank, $name, $label',
            excludeSemantics: true,
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: Text(
                    '$rank',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 13, color: color),
                        const SizedBox(width: 4),
                        Text(
                          label,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 10,
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (final n in [r['played'], r['won'], r['drawn'], r['lost']])
          DataCell(Text('${asInt(n)}')),
        DataCell(Text(diff > 0 ? '+$diff' : '$diff')),
        DataCell(
          Text(
            '${asInt(r['points'])}',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }

  Widget _notes(List<Map<String, dynamic>> rows) {
    final ties = [
      for (final r in rows)
        if (r['resolved_by'] != null && asStr(r['resolved_by']).isNotEmpty) r,
    ];
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading('What the marks mean'),
          for (final s in ['clinched', 'still_possible', 'eliminated'])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Builder(
                builder: (context) {
                  final (icon, label, color) = _qualification(s);
                  return Row(
                    children: [
                      Icon(icon, size: 18, color: color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(switch (s) {
                          'clinched' => '$label: sure to qualify',
                          'eliminated' => '$label: cannot qualify any more',
                          _ => '$label: depends on remaining matches',
                        }),
                      ),
                    ],
                  );
                },
              ),
            ),
          if (ties.isNotEmpty) ...[
            const Divider(),
            const Text(
              'Tie-breaks',
              style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            for (final r in ties)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${widget.state.teamName(asStr(r['team_id']))} placed above a tied team by '
                  '${_criteria[asStr(r['resolved_by'])] ?? humanize(asStr(r['resolved_by']))}.',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12),
                ),
              ),
          ],
          const Divider(),
          const Text(
            'Standings and qualification are calculated by the server from the match event history.',
            style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: muted),
          ),
        ],
      ),
    );
  }
}
