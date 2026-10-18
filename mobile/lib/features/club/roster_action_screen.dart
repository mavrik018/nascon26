import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_state.dart';
import '../../core/format.dart';
import '../../widgets/common.dart';

/// Club-manager screen: transfer, loan or release one player.
class RosterActionScreen extends StatefulWidget {
  const RosterActionScreen({super.key, required this.player, required this.clubId});
  final Map<String, dynamic> player;
  final String clubId;

  @override
  State<RosterActionScreen> createState() => _RosterActionScreenState();
}

class _RosterActionScreenState extends State<RosterActionScreen> {
  String _type = 'transfer';
  String? _to;
  DateTime _effective = DateTime.now();
  DateTime _loanEnd = DateTime.now().add(const Duration(days: 30));
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _history = const [];
  bool _historyFromCache = false;

  String get _playerId => asStr(widget.player['player_id']);
  String get _playerName => asStr(widget.player['name'], humanize(_playerId));
  String get _fromSquad => asStr(widget.player['squad_id'], widget.clubId);

  List<String> get _destinations {
    final state = AppScope.read(context);
    final ids = <String>{...AppState.demoClubs, ...state.teamNames.keys}..remove(_fromSquad);
    return ids.toList()..sort();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final d = _destinations;
      if (d.isNotEmpty) setState(() => _to = d.first);
      _loadHistory();
    });
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  /// Also caches the history so base_version is right when offline.
  Future<void> _loadHistory() async {
    try {
      final loaded = await AppScope.read(context).load('/api/v1/roster/players/$_playerId/history');
      final data = loaded.data;
      final list = data is List ? data : asList(asMap(data)['history']);
      if (!mounted) return;
      setState(() {
        _history = [for (final e in list) asMap(e)];
        _historyFromCache = loaded.fromCache;
      });
    } on ApiException {
      // History is optional on this screen.
    }
  }

  Future<void> _pickDate(bool loanEnd) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: loanEnd ? _loanEnd : _effective,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      helpText: loanEnd ? 'Loan ends on' : 'Effective date',
    );
    if (picked == null) return;
    setState(() => loanEnd ? _loanEnd = picked : _effective = picked);
  }

  String _describe() {
    final state = AppScope.read(context);
    return switch (_type) {
      'loan' => 'Loan $_playerName to ${state.teamName(_to)} from ${isoDate(_effective)} until ${isoDate(_loanEnd)}',
      'release' => 'Release $_playerName from ${state.teamName(_fromSquad)} on ${isoDate(_effective)}',
      _ => 'Transfer $_playerName to ${state.teamName(_to)} on ${isoDate(_effective)}',
    };
  }

  Future<void> _submit() async {
    final state = AppScope.read(context);
    if (_type != 'release' && _to == null) {
      setState(() => _error = 'Choose the club the player moves to.');
      return;
    }
    if (_type == 'loan' && !_loanEnd.isAfter(_effective)) {
      setState(() => _error = 'The loan end date must be after the effective date.');
      return;
    }
    final description = _describe();
    final ok = await confirmAction(
      context,
      title: 'Confirm roster change',
      message: '$description?\n\nThis cannot be undone from the app.',
      confirmLabel: humanize(_type),
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final body = <String, dynamic>{
      'request_id': newId(),
      'league_id': state.rosterLeagueId,
      'player_id': _playerId,
      'type': _type,
      'from_squad_id': _fromSquad,
      'to_squad_id': _type == 'release' ? null : _to,
      'effective_date': isoDate(_effective),
      'loan_end_date': _type == 'loan' ? isoDate(_loanEnd) : null,
      'reason': _reason.text.trim().isEmpty ? 'Squad change' : _reason.text.trim(),
      'requested_by': state.user?.userId ?? 'unknown',
    };
    try {
      final outcome = await state.submitRosterAction(body: body, label: description);
      if (!mounted) return;
      if (outcome.queued) {
        showSnack(context, 'You are offline. The change is saved on this phone and will sync automatically.');
      } else {
        final res = asMap(outcome.response);
        final deferred = asStr(res['state']) == 'deferred_until_match_end';
        showSnack(
          context,
          deferred ? 'Accepted. It takes effect after the player\'s live match ends.' : 'Done: $description.',
        );
      }
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final dests = _destinations;
    return Scaffold(
      appBar: leagueAppBar(context, 'Manage player'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_playerName, style: theme.textTheme.headlineSmall),
          Text(
            '${humanize(asStr(widget.player['position'])).toUpperCase()} · '
            '${humanize(asStr(widget.player['role']))} · ${state.teamName(_fromSquad)}',
          ),
          const SizedBox(height: 20),
          Text('What do you want to do?', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'transfer', label: Text('Transfer'), icon: Icon(Icons.swap_horiz)),
              ButtonSegment(value: 'loan', label: Text('Loan'), icon: Icon(Icons.schedule_send)),
              ButtonSegment(value: 'release', label: Text('Release'), icon: Icon(Icons.logout)),
            ],
            selected: {_type},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() {
              _type = s.first;
              _error = null;
            }),
          ),
          const SizedBox(height: 20),
          if (_type != 'release') ...[
            DropdownButtonFormField<String>(
              key: ValueKey('dest-$_to'),
              initialValue: dests.contains(_to) ? _to : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Move to club', border: OutlineInputBorder()),
              items: [for (final id in dests) DropdownMenuItem(value: id, child: Text(state.teamName(id)))],
              onChanged: (v) => setState(() => _to = v),
            ),
            const SizedBox(height: 16),
          ],
          _DateField(label: 'Effective date', value: _effective, onTap: () => _pickDate(false)),
          if (_type == 'loan') ...[
            const SizedBox(height: 16),
            _DateField(label: 'Loan ends on', value: _loanEnd, onTap: () => _pickDate(true)),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(
              labelText: 'Reason (optional)',
              hintText: 'e.g. Tactical move',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('roster-submit'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _submit,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(state.isOnline ? Icons.check : Icons.cloud_upload_outlined),
            label: Text(state.isOnline ? '${humanize(_type)} player' : '${humanize(_type)} (save for sync)'),
          ),
          if (!state.isOnline)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('You are offline. The change will be queued and sent when you are back online.'),
            ),
          const SizedBox(height: 24),
          Text('Move history${_historyFromCache ? ' (saved copy)' : ''}', style: theme.textTheme.titleSmall),
          if (_history.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('No moves recorded yet.')),
          for (final h in _history.reversed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history),
              title: Text(
                '${humanize(asStr(h['action']))}: '
                '${state.teamName(asStr(h['from_squad_id'], '-'))} → ${state.teamName(asStr(h['to_squad_id'], '-'))}',
              ),
              subtitle: Text('${asStr(h['effective_date'])} · ${asStr(h['why'])}'),
            ),
        ],
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onTap});
  final String label;
  final DateTime value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.calendar_today),
        ),
        child: Text(isoDate(value)),
      ),
    );
  }
}
