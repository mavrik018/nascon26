import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_state.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../widgets/common.dart';
import '../store/product_screen.dart';
import 'fixtures_screen.dart';

class MatchScreen extends StatefulWidget {
  const MatchScreen({super.key, required this.matchId, this.homeName, this.awayName, this.homeId, this.awayId});

  final String matchId;
  final String? homeName;
  final String? awayName;
  final String? homeId;
  final String? awayId;

  @override
  State<MatchScreen> createState() => _MatchScreenState();
}

class _MatchScreenState extends State<MatchScreen> {
  Map<String, dynamic>? _data;
  Loaded? _loaded;
  ApiException? _error;
  Timer? _poll;
  bool _busy = false;

  String get _path => '/api/v1/matches/${widget.matchId}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    // Live score: poll every 5 s while this screen is open.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      final state = AppScope.read(context);
      if (state.hasNetwork && asStr(_data?['status']) != 'completed') _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final loaded = await AppScope.read(context).load(_path);
      if (!mounted) return;
      setState(() {
        _loaded = loaded;
        _data = asMap(loaded.data);
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  String _teamName(String? id) {
    if (id != null && id == widget.homeId && widget.homeName != null) return widget.homeName!;
    if (id != null && id == widget.awayId && widget.awayName != null) return widget.awayName!;
    return AppScope.read(context).teamName(id);
  }

  Future<void> _submit(Map<String, dynamic> body, String label, String doneText) async {
    final state = AppScope.read(context);
    setState(() => _busy = true);
    try {
      final outcome = await state.submitMatchEvent(matchId: widget.matchId, body: body, label: label);
      if (!mounted) return;
      if (outcome.queued) {
        showSnack(context, 'You are offline. "$label" is saved on this phone and will sync automatically.');
      } else {
        showSnack(context, doneText);
        await _refresh();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addScore() async {
    final data = _data ?? {};
    final home = asMap(data['home']);
    final away = asMap(data['away']);
    final homeId = asStr(home['team_id'], widget.homeId ?? '');
    final awayId = asStr(away['team_id'], widget.awayId ?? '');
    final types = [for (final t in asList(data['event_types'])) asStr(t is Map ? t['name'] : t)];
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ScoreSheet(
        homeId: homeId,
        awayId: awayId,
        homeName: _teamName(homeId),
        awayName: _teamName(awayId),
        eventTypes: types,
      ),
    );
    if (result == null || !mounted) return;
    final (teamId, eventType) = result;
    final label = '${humanize(eventType)} for ${_teamName(teamId)}';
    final ok = await confirmAction(
      context,
      title: 'Add score event?',
      message: 'Record "$label" in this match?',
      confirmLabel: 'Add',
    );
    if (!ok) return;
    await _submit(
      {
        'event_id': newId(),
        'match_id': widget.matchId,
        'type': 'score',
        'payload': {'team_id': teamId, 'event_type': eventType},
      },
      label,
      'Score added: $label',
    );
  }

  Future<void> _compensate(Map<String, dynamic> event) async {
    final reasonCtrl = TextEditingController(text: 'Scoring correction');
    final label = _eventTitle(event);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Correct this event?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('"$label" will be cancelled by a correction. The original stays in the timeline, struck through.'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Correct')),
        ],
      ),
    );
    final reason = reasonCtrl.text.trim().isEmpty ? 'Scoring correction' : reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (ok != true || !mounted) return;
    await _submit(
      {
        'event_id': newId(),
        'match_id': widget.matchId,
        'type': 'compensation',
        'payload': {'compensates': asStr(event['event_id']), 'reason': reason},
      },
      'Correction of "$label"',
      'Correction recorded',
    );
  }

  Future<void> _transition(String type, String label) async {
    final ok = await confirmAction(
      context,
      title: '$label?',
      message: 'This changes the match status for everyone.',
      confirmLabel: label,
    );
    if (!ok) return;
    await _submit(
      {'event_id': newId(), 'match_id': widget.matchId, 'type': type, 'payload': {}},
      label,
      '$label: done',
    );
  }

  String _eventTitle(Map<String, dynamic> e) {
    final p = asMap(e['payload']);
    return switch (asStr(e['type'])) {
      'match_init' => 'Match created',
      'match_start' => 'Match started',
      'match_end' => 'Match ended',
      'score' => '${humanize(asStr(p['event_type']))} – ${_teamName(asStr(p['team_id']))}',
      'discipline' => 'Discipline ${p['points']} – ${_teamName(asStr(p['team_id']))}',
      'tiebreak_winner' => 'Tie-break won by ${_teamName(asStr(p['team_id']))}',
      'compensation' => 'Correction: ${asStr(p['reason'])}',
      final t => humanize(t),
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final data = _data;
    return Scaffold(
      appBar: leagueAppBar(
        context,
        'Match',
        actions: [IconButton(tooltip: 'Refresh score', icon: const Icon(Icons.refresh), onPressed: _refresh)],
      ),
      body: data == null
          ? (_error == null
                ? Center(
                    child: Semantics(label: 'Loading match', child: const CircularProgressIndicator()),
                  )
                : ListView(
                    children: [ErrorView(message: _error!.message, onRetry: _refresh, offline: _error!.isNetwork)],
                  ))
          : Column(
              children: [
                if (_loaded?.fromCache ?? false) CachedNotice(savedAt: _loaded?.savedAt),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 32),
                      children: [
                        _scoreCard(context, data),
                        if (state.user?.canScore ?? false) _organizerPanel(context, data),
                        _pinnedProduct(context, data),
                        ..._pendingSection(context, state),
                        SectionTitle('Timeline'),
                        ..._timeline(context, data, state),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _scoreCard(BuildContext context, Map<String, dynamic> data) {
    final theme = Theme.of(context);
    final home = asMap(data['home']);
    final away = asMap(data['away']);
    final status = asStr(data['status'], 'upcoming');
    String scoreOf(Map<String, dynamic> side) {
      final s = asStr(side['score'], '0');
      if (side['wickets'] != null) return '$s/${side['wickets']}';
      return s;
    }

    String? oversOf(Map<String, dynamic> side) => side['overs'] == null ? null : '${side['overs']} overs';
    final outcome = asStr(data['outcome']);
    final winner = data['winner_team_id'] as String?;
    final result = switch (outcome) {
      'home_win' || 'away_win' => '${_teamName(winner)} won',
      'draw' => 'Draw',
      'undecided' => 'Result undecided',
      _ => status == 'in_progress' ? 'In play – updates every 5 seconds' : 'Not started yet',
    };
    Widget side(Map<String, dynamic> s, String fallbackName) => Expanded(
      child: Column(
        children: [
          Text(
            _teamName(asStr(s['team_id'], fallbackName)),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
          if (oversOf(s) != null) Text(oversOf(s)!, style: theme.textTheme.bodySmall),
        ],
      ),
    );
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            matchStatusPill(context, status),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              label:
                  'Score ${_teamName(asStr(home['team_id']))} ${scoreOf(home)}, '
                  '${_teamName(asStr(away['team_id']))} ${scoreOf(away)}',
              excludeSemantics: true,
              child: Row(
                children: [
                  side(home, widget.homeId ?? ''),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: FittedBox(
                      child: Text(
                        '${scoreOf(home)} : ${scoreOf(away)}',
                        style: theme.textTheme.displayMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  side(away, widget.awayId ?? ''),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(result, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _organizerPanel(BuildContext context, Map<String, dynamic> data) {
    final status = asStr(data['status'], 'upcoming');
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Scoring (organizer)', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('add-score'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: _busy ? null : _addScore,
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Add score event'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (status == 'upcoming')
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _transition('match_start', 'Start match'),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start match'),
                  ),
                if (status == 'in_progress')
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _transition('match_end', 'End match'),
                    icon: const Icon(Icons.stop),
                    label: const Text('End match'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'To fix a mistake, tap "Correct" on an event in the timeline.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _pinnedProduct(BuildContext context, Map<String, dynamic> data) {
    final p = data['pinned_product'];
    if (p is! Map) return const SizedBox.shrink();
    final product = asMap(p);
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.secondaryContainer,
          child: Icon(Icons.shopping_bag_outlined, color: theme.colorScheme.onSecondaryContainer),
        ),
        title: Text(asStr(product['name'], 'Featured product')),
        subtitle: Text(
          'Featured in this match · ${formatMoney(asInt(product['price_minor']), asStr(product['currency'], 'PKR'))}',
        ),
        trailing: FilledButton.tonal(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => ProductScreen(productId: asStr(product['product_id'])))),
          child: const Text('Shop'),
        ),
      ),
    );
  }

  List<Widget> _pendingSection(BuildContext context, AppState state) {
    final pending = state.pendingFor(ActionTypes.scoreEvent, widget.matchId);
    if (pending.isEmpty) return const [];
    return [
      SectionTitle('Waiting to sync (${pending.length})'),
      for (final a in pending)
        ListTile(
          leading: const Icon(Icons.cloud_upload_outlined),
          title: Text(a.label),
          subtitle: Text('Saved ${formatDateTime(a.queuedAt)}'),
          trailing: const PendingPill(label: 'Pending'),
        ),
    ];
  }

  List<Widget> _timeline(BuildContext context, Map<String, dynamic> data, AppState state) {
    final events = [for (final e in asList(data['events'])) asMap(e)].reversed.toList();
    if (events.isEmpty) {
      return const [
        EmptyView(icon: Icons.timeline, title: 'No events yet', message: 'Score updates appear here as they happen.'),
      ];
    }
    final theme = Theme.of(context);
    final canScore = state.user?.canScore ?? false;
    const correctable = {'score', 'discipline', 'tiebreak_winner'};
    return [
      for (final e in events)
        Builder(
          builder: (context) {
            final compensated = e['compensated'] == true;
            final type = asStr(e['type']);
            final title = _eventTitle(e);
            return ListTile(
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: compensated
                    ? theme.colorScheme.surfaceContainerHighest
                    : theme.colorScheme.secondaryContainer,
                child: Text('${e['sequence'] ?? ''}', style: theme.textTheme.labelMedium),
              ),
              title: Text(
                title,
                style: compensated
                    ? TextStyle(decoration: TextDecoration.lineThrough, color: theme.colorScheme.outline)
                    : null,
              ),
              subtitle: compensated
                  ? const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: StatusPill(
                          icon: Icons.undo,
                          label: 'Corrected – does not count',
                          color: Color(0x22000000),
                        ),
                      ),
                    )
                  : type == 'compensation'
                  ? const Text('Cancels an earlier event')
                  : null,
              trailing: canScore && !compensated && correctable.contains(type)
                  ? TextButton(onPressed: _busy ? null : () => _compensate(e), child: const Text('Correct'))
                  : null,
            );
          },
        ),
    ];
  }
}

class _ScoreSheet extends StatefulWidget {
  const _ScoreSheet({
    required this.homeId,
    required this.awayId,
    required this.homeName,
    required this.awayName,
    required this.eventTypes,
  });

  final String homeId;
  final String awayId;
  final String homeName;
  final String awayName;
  final List<String> eventTypes;

  @override
  State<_ScoreSheet> createState() => _ScoreSheetState();
}

class _ScoreSheetState extends State<_ScoreSheet> {
  late String _team = widget.homeId;
  String? _type;
  final _custom = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.eventTypes.isNotEmpty) _type = widget.eventTypes.first;
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = widget.eventTypes.isEmpty ? _custom.text.trim() : _type;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Add score event', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            Text('Team', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (id, name) in [(widget.homeId, widget.homeName), (widget.awayId, widget.awayName)])
                  ChoiceChip(label: Text(name), selected: _team == id, onSelected: (_) => setState(() => _team = id)),
              ],
            ),
            const SizedBox(height: 16),
            Text('Event', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (widget.eventTypes.isEmpty)
              TextField(
                controller: _custom,
                decoration: const InputDecoration(labelText: 'Event type', border: OutlineInputBorder()),
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
                      selected: _type == t,
                      onSelected: (_) => setState(() => _type = t),
                    ),
                ],
              ),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: (type == null || type.isEmpty) ? null : () => Navigator.pop(context, (_team, type)),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}
