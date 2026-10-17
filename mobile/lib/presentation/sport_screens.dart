import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/app_state.dart';
import 'ocean_widgets.dart';

/// Sports are data (spec 5.6): this screen lists them and lets admins / league
/// organizers add a new one without any code change.
bool canAddSport(AppState state) => const {'super_admin', 'league_organizer'}.contains(state.user?.role);

class SportsPage extends StatefulWidget {
  const SportsPage({super.key, required this.state});
  final AppState state;

  @override
  State<SportsPage> createState() => _SportsPageState();
}

class _SportsPageState extends State<SportsPage> {
  List<Map<String, dynamic>> sports = const [];
  bool loading = true;
  String? error;

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
      final data = (await widget.state.load('/api/v1/sports')).data;
      sports = [for (final s in (data as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
    } on ApiException catch (e) {
      error = e.message;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  static String _model(String m) => switch (m) {
    'innings' => 'Innings-based (runs, wickets, overs)',
    'round' => 'Round / map based (best of N)',
    _ => 'Event-based (points per scoring event)',
  };

  @override
  Widget build(BuildContext context) => OceanPage(
    title: 'Sports',
    subtitle: 'CONFIGURED AS DATA',
    actions: [
      IconButton(
        tooltip: 'Refresh sports',
        onPressed: loading ? null : _load,
        icon: const Icon(Icons.refresh, color: Colors.white),
      ),
    ],
    children: [
      if (canAddSport(widget.state))
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const Key('add-sport'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: () async {
              final added = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => AddSportPage(state: widget.state)),
              );
              if (added == true) await _load();
            },
            icon: const Icon(Icons.add),
            label: const Text('Add a sport'),
          ),
        ),
      if (loading)
        const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
      else if (error != null)
        GlassCard(child: Text(error!))
      else if (sports.isEmpty)
        const GlassCard(child: Text('No sports configured yet.'))
      else
        for (final s in sports)
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('${s['name'] ?? s['sport_id']}',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: ink)),
                    ),
                    if (s['baseline'] != true) const Tag('CUSTOM'),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_model('${s['scoring_model']}'), style: const TextStyle(color: muted)),
                const SizedBox(height: 6),
                Text('Scoring: ${(s['scoring_events'] as Map? ?? const {}).keys.join(', ')}',
                    style: const TextStyle(color: ink)),
                Text('Draws ${s['draw_allowed'] == true ? 'allowed' : 'not allowed'} · '
                    'squad ${(s['roster'] as Map?)?['min_squad_size']}–${(s['roster'] as Map?)?['max_squad_size']}',
                    style: const TextStyle(color: muted, fontSize: 12)),
              ],
            ),
          ),
    ],
  );
}

class _EventRow {
  _EventRow(String name, int value) : name = TextEditingController(text: name), value = TextEditingController(text: '$value');
  final TextEditingController name;
  final TextEditingController value;
  bool legalBall = true;
  bool wicket = false;
}

class AddSportPage extends StatefulWidget {
  const AddSportPage({super.key, required this.state});
  final AppState state;

  @override
  State<AddSportPage> createState() => _AddSportPageState();
}

class _AddSportPageState extends State<AddSportPage> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _name = TextEditingController();
  String _model = 'event';
  // periods
  final _count = TextEditingController(text: '2');
  final _minutes = TextEditingController(text: '20');
  final _overs = TextEditingController(text: '20');
  final _balls = TextEditingController(text: '6');
  final _wickets = TextEditingController(text: '10');
  final _bestOf = TextEditingController(text: '3');
  final _minSquad = TextEditingController(text: '7');
  final _maxSquad = TextEditingController(text: '15');
  bool _draws = true;
  String _overtime = 'none';
  final List<_EventRow> _events = [_EventRow('point', 1)];
  bool _saving = false;
  String? _error;

  int _int(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  Map<String, dynamic> _body() {
    final periods = switch (_model) {
      'innings' => {
        'innings_per_team': _int(_count),
        'overs_per_innings': _int(_overs),
        'balls_per_over': _int(_balls),
        'wickets_per_innings': _int(_wickets),
      },
      'round' => {'best_of': _int(_bestOf)},
      _ => {'count': _int(_count), 'duration_minutes': _int(_minutes)},
    };
    final events = <String, dynamic>{
      for (final e in _events)
        e.name.text.trim(): switch (_model) {
          'innings' => {'runs': _int(e.value), 'legal_ball': e.legalBall, 'wicket': e.wicket},
          'round' => {'rounds': _int(e.value)},
          _ => {'points': _int(e.value)},
        },
    };
    return {
      'sport_id': _id.text.trim(),
      'name': _name.text.trim(),
      'scoring_model': _model,
      'periods': periods,
      'scoring_events': events,
      'draw_allowed': _draws,
      'overtime': {'policy': _overtime},
      'roster': {'min_squad_size': _int(_minSquad), 'max_squad_size': _int(_maxSquad), 'required_positions': {}},
    };
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.state.api.post('/api/v1/sports', _body());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_name.text.trim()} added')));
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.code == 'SPORT_EXISTS'
          ? 'A sport with this id already exists.'
          : e.code == 'VALIDATION_ERROR'
          ? 'Some values are not valid: ${(e.details['fields'] as List?)?.join(', ') ?? e.message}'
          : e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _num(TextEditingController c, String label, {int min = 1}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: c,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      validator: (v) => (int.tryParse((v ?? '').trim()) ?? -1) < min ? 'Whole number ≥ $min' : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final valueLabel = switch (_model) { 'innings' => 'Runs', 'round' => 'Rounds', _ => 'Points' };
    return OceanPage(
      title: 'Add a sport',
      subtitle: 'NO CODE CHANGE NEEDED',
      children: [
        GlassCard(
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: const TextStyle(color: Color(0xFFB3261E))),
                  ),
                TextFormField(
                  controller: _id,
                  decoration: const InputDecoration(labelText: 'Sport id', hintText: 'lowercase, e.g. kabaddi'),
                  validator: (v) => RegExp(r'^[a-z0-9_-]{2,40}$').hasMatch((v ?? '').trim())
                      ? null
                      : '2–40 lowercase letters, digits, - or _',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Display name'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                const Text('Scoring model', style: TextStyle(fontWeight: FontWeight.w700, color: ink)),
                const SizedBox(height: 8),
                CupertinoSlidingSegmentedControl<String>(
                  groupValue: _model,
                  children: const {
                    'event': Padding(padding: EdgeInsets.all(10), child: Text('Events')),
                    'innings': Padding(padding: EdgeInsets.all(10), child: Text('Innings')),
                    'round': Padding(padding: EdgeInsets.all(10), child: Text('Rounds')),
                  },
                  onValueChanged: (v) => setState(() => _model = v ?? 'event'),
                ),
                const SizedBox(height: 16),
                if (_model == 'event') ...[
                  _num(_count, 'Number of periods'),
                  _num(_minutes, 'Minutes per period'),
                ] else if (_model == 'innings') ...[
                  _num(_count, 'Innings per team'),
                  _num(_overs, 'Overs per innings'),
                  _num(_balls, 'Balls per over'),
                  _num(_wickets, 'Wickets per innings'),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      controller: _bestOf,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Best of (odd number)'),
                      validator: (v) {
                        final n = int.tryParse((v ?? '').trim()) ?? 0;
                        return n >= 1 && n.isOdd ? null : 'Odd number ≥ 1';
                      },
                    ),
                  ),
                const Text('Scoring events', style: TextStyle(fontWeight: FontWeight.w700, color: ink)),
                for (final e in _events)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: e.name,
                                decoration: const InputDecoration(labelText: 'Event name'),
                                validator: (v) => RegExp(r'^[a-z0-9_]{1,40}$').hasMatch((v ?? '').trim())
                                    ? null
                                    : 'lowercase_with_underscores',
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: e.value,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(labelText: valueLabel),
                                validator: (v) => (int.tryParse((v ?? '').trim()) ?? -1) < (_model == 'innings' ? 0 : 1)
                                    ? 'Invalid'
                                    : null,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove event',
                              onPressed: _events.length == 1 ? null : () => setState(() => _events.remove(e)),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                          ],
                        ),
                        if (_model == 'innings')
                          Row(
                            children: [
                              Expanded(
                                child: SwitchListTile.adaptive(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Legal ball'),
                                  value: e.legalBall,
                                  onChanged: (v) => setState(() => e.legalBall = v),
                                ),
                              ),
                              Expanded(
                                child: SwitchListTile.adaptive(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Wicket'),
                                  value: e.wicket,
                                  onChanged: (v) => setState(() => e.wicket = v),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _events.add(_EventRow('', 1))),
                    icon: const Icon(Icons.add),
                    label: const Text('Add scoring event'),
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Draws allowed'),
                  value: _draws,
                  onChanged: (v) => setState(() => _draws = v),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _overtime,
                  decoration: const InputDecoration(labelText: 'Overtime / tie-break policy'),
                  items: const [
                    DropdownMenuItem(value: 'none', child: Text('None')),
                    DropdownMenuItem(value: 'extra_time', child: Text('Extra time')),
                    DropdownMenuItem(value: 'shootout', child: Text('Shootout')),
                    DropdownMenuItem(value: 'golden_score', child: Text('Golden score')),
                    DropdownMenuItem(value: 'super_over', child: Text('Super over')),
                  ],
                  onChanged: (v) => setState(() => _overtime = v ?? 'none'),
                ),
                const SizedBox(height: 12),
                _num(_minSquad, 'Minimum squad size'),
                _num(_maxSquad, 'Maximum squad size'),
                FilledButton(
                  key: const Key('save-sport'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Create sport'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
