import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/app_state.dart';
import '../core/format.dart';
import '../toolkit/02_ui_elements/pressable.dart';
import 'club_screens.dart' show plainError;
import 'ocean_widgets.dart';

/// Sports are data (spec 5.6): admins and league organizers add sports and edit their rules without any code
/// change; the platform admin can delete a custom sport nobody uses. Matches keep the rules they were created
/// with, so editing never changes a finished result.
bool canAddSport(AppState state) => const {'super_admin', 'league_organizer'}.contains(state.user?.role);
bool canDeleteSport(AppState state) => state.user?.role == 'super_admin';

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
      sports = [for (final s in asList(data)) asMap(s)];
    } on ApiException catch (e) {
      error = e.message;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _open([Map<String, dynamic>? sport]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SportEditorPage(state: widget.state, sport: sport),
      ),
    );
    if (changed == true) await _load();
  }

  static String _model(String m) => switch (m) {
    'innings' => 'Innings-based (runs, wickets, overs)',
    'round' => 'Round / map based (best of N)',
    _ => 'Event-based (points per scoring event)',
  };

  @override
  Widget build(BuildContext context) {
    final editor = canAddSport(widget.state);
    return OceanPage(
      title: 'Sports',
      subtitle: 'CONFIGURED AS DATA',
      actions: [
        IconButton(
          tooltip: 'Refresh sports',
          onPressed: loading ? null : _load,
          icon: const Icon(CupertinoIcons.refresh, color: Colors.white),
        ),
      ],
      children: [
        if (editor)
          PrimaryButton(key: const Key('add-sport'), label: 'Add a sport', icon: CupertinoIcons.add, onPressed: _open),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CupertinoActivityIndicator(radius: 14)),
          )
        else if (error != null)
          FormError(error!)
        else if (sports.isEmpty)
          const EmptyCard('No sports yet', 'Add the first sport to start a league.')
        else
          for (final s in sports)
            Pressable(
              onTap: editor ? () => _open(s) : null,
              semanticLabel: '${asStr(s['name'])}. ${editor ? 'Edit rules.' : ''}',
              child: GlassCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  asStr(s['name'], 'Sport'),
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: ink),
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (s['baseline'] != true) const Tag('CUSTOM'),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(_model(asStr(s['scoring_model'])), style: const TextStyle(color: muted)),
                          const SizedBox(height: 6),
                          Text(
                            'Scoring: ${asMap(s['scoring_events']).keys.map(humanize).join(', ')}',
                            style: const TextStyle(color: ink),
                          ),
                          Text(
                            'Draws ${s['draw_allowed'] == true ? 'allowed' : 'not allowed'} · squad '
                            '${asMap(s['roster'])['min_squad_size']}–${asMap(s['roster'])['max_squad_size']}',
                            style: const TextStyle(color: muted, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                    if (editor) const Icon(CupertinoIcons.chevron_right, color: muted, size: 18),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

/// One scoring rule ("goal = 1 point", "six = 6 runs, legal ball").
class _EventRule {
  _EventRule(String name, int value, {this.legalBall = true, this.wicket = false})
    : name = TextEditingController(text: name),
      value = TextEditingController(text: '$value');
  final TextEditingController name;
  final TextEditingController value;
  bool legalBall;
  bool wicket;
}

/// One roster rule ("at least 1 gk").
class _PositionRule {
  _PositionRule(String position, int count)
    : position = TextEditingController(text: position),
      count = TextEditingController(text: '$count');
  final TextEditingController position;
  final TextEditingController count;
}

/// Create a sport, or edit an existing one's rules (pass [sport]). The server assigns the sport id.
class SportEditorPage extends StatefulWidget {
  const SportEditorPage({super.key, required this.state, this.sport});
  final AppState state;
  final Map<String, dynamic>? sport;

  @override
  State<SportEditorPage> createState() => _SportEditorPageState();
}

class _SportEditorPageState extends State<SportEditorPage> {
  final _form = GlobalKey<FormState>();
  late final Map<String, dynamic> _s = widget.sport ?? const {};
  late final Map<String, dynamic> _p = asMap(_s['periods']);
  late final Map<String, dynamic> _r = asMap(_s['roster']);
  late final _name = TextEditingController(text: asStr(_s['name']));
  late String _model = asStr(_s['scoring_model'], 'event');
  late final _count = TextEditingController(text: '${_p['count'] ?? _p['innings_per_team'] ?? 2}');
  late final _minutes = TextEditingController(text: '${_p['duration_minutes'] ?? 20}');
  late final _overs = TextEditingController(text: '${_p['overs_per_innings'] ?? 20}');
  late final _balls = TextEditingController(text: '${_p['balls_per_over'] ?? 6}');
  late final _wickets = TextEditingController(text: '${_p['wickets_per_innings'] ?? 10}');
  late final _bestOf = TextEditingController(text: '${_p['best_of'] ?? 3}');
  late final _minSquad = TextEditingController(text: '${_r['min_squad_size'] ?? 7}');
  late final _maxSquad = TextEditingController(text: '${_r['max_squad_size'] ?? 15}');
  late bool _draws = _s['draw_allowed'] as bool? ?? true;
  late String _overtime = asStr(asMap(_s['overtime'])['policy'], 'none');
  late final List<_EventRule> _events = [
    for (final e in asMap(_s['scoring_events']).entries)
      _EventRule(
        humanize(e.key),
        asInt(asMap(e.value)['points'] ?? asMap(e.value)['runs'] ?? asMap(e.value)['rounds']),
        legalBall: asMap(e.value)['legal_ball'] as bool? ?? true,
        wicket: asMap(e.value)['wicket'] as bool? ?? false,
      ),
    if (_s.isEmpty) _EventRule('point', 1),
  ];
  late final List<_PositionRule> _positions = [
    for (final e in asMap(_r['required_positions']).entries) _PositionRule(humanize(e.key), asInt(e.value)),
  ];
  bool _saving = false;
  String? _error;

  bool get _editing => widget.sport != null;
  String get _id => asStr(_s['sport_id']);

  int _int(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  Map<String, dynamic> _body() => {
    'name': _name.text.trim(),
    'scoring_model': _model,
    'periods': switch (_model) {
      'innings' => {
        'innings_per_team': _int(_count),
        'overs_per_innings': _int(_overs),
        'balls_per_over': _int(_balls),
        'wickets_per_innings': _int(_wickets),
      },
      'round' => {'best_of': _int(_bestOf)},
      _ => {'count': _int(_count), 'duration_minutes': _int(_minutes)},
    },
    'scoring_events': {
      for (final e in _events)
        _key(e.name.text): switch (_model) {
          'innings' => {'runs': _int(e.value), 'legal_ball': e.legalBall, 'wicket': e.wicket},
          'round' => {'rounds': _int(e.value)},
          _ => {'points': _int(e.value)},
        },
    },
    'draw_allowed': _draws,
    'overtime': {'policy': _overtime},
    if (_s['tie_break_order'] != null) 'tie_break_order': _s['tie_break_order'],
    'roster': {
      'min_squad_size': _int(_minSquad),
      'max_squad_size': _int(_maxSquad),
      'required_positions': {for (final r in _positions) _key(r.position.text): _int(r.count)},
    },
  };

  /// "Free Throw" -> "free_throw" (rule names are keys, the app shows them humanized).
  static String _key(String raw) =>
      raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final keys = [for (final e in _events) _key(e.name.text)];
    if (keys.toSet().length != keys.length) {
      setState(() => _error = 'Two scoring rules have the same name. Give each rule its own name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_editing) {
        await widget.state.api.send('PUT', '/api/v1/sports/$_id', _body());
      } else {
        await widget.state.api.post('/api/v1/sports', _body());
      }
      if (!mounted) return;
      notice(
        context,
        _editing ? 'Rules updated for ${_name.text.trim()}' : '${_name.text.trim()} added',
        kind: ToastKind.success,
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e is ApiException && e.code == 'SPORT_EXISTS'
            ? 'A sport with this name already exists. Pick another name.'
            : plainError(e),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmIos(
      context,
      title: 'Delete ${_name.text.trim()}?',
      message: 'The sport disappears for everyone. Built-in sports and sports used by a league cannot be deleted.',
      confirm: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.state.api.send('DELETE', '/api/v1/sports/$_id');
      if (!mounted) return;
      notice(context, '${_name.text.trim()} deleted', kind: ToastKind.success);
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = plainError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _wholeNumber(String? v, {int min = 1}) =>
      (int.tryParse((v ?? '').trim()) ?? -1) < min ? 'Enter a whole number of at least $min' : null;

  Widget _num(TextEditingController c, String label, {int min = 1}) => TextRow(
    label: label,
    controller: c,
    keyboardType: TextInputType.number,
    validator: (v) => _wholeNumber(v, min: min),
  );

  Widget _removeButton(String what, VoidCallback? onPressed) => IconButton(
    tooltip: 'Remove $what',
    onPressed: onPressed,
    icon: Icon(CupertinoIcons.minus_circle_fill, color: onPressed == null ? muted : const Color(0xFFD70015)),
  );

  @override
  Widget build(BuildContext context) {
    final valueLabel = switch (_model) {
      'innings' => 'Runs',
      'round' => 'Rounds won',
      _ => 'Points',
    };
    return OceanPage(
      title: _editing ? 'Edit rules' : 'Add a sport',
      subtitle: _editing ? _name.text.toUpperCase() : 'NO CODE CHANGE NEEDED',
      children: [
        if (_editing)
          const GlassCard(
            padding: EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(CupertinoIcons.info_circle, color: ocean),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Changes apply to new matches. Matches already created keep their rules, '
                    'so past results never change.',
                  ),
                ),
              ],
            ),
          ),
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[FormError(_error!), const SizedBox(height: 16)],
              FormSection(
                header: 'Sport',
                children: [
                  TextRow(
                    fieldKey: const Key('sport-name'),
                    label: 'Name',
                    hint: 'e.g. Kabaddi',
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Give the sport a name' : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: CupertinoSlidingSegmentedControl<String>(
                        groupValue: _model,
                        children: const {
                          'event': Padding(padding: EdgeInsets.all(10), child: Text('Points')),
                          'innings': Padding(padding: EdgeInsets.all(10), child: Text('Innings')),
                          'round': Padding(padding: EdgeInsets.all(10), child: Text('Rounds')),
                        },
                        onValueChanged: (v) => setState(() => _model = v ?? 'event'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FormSection(
                header: 'Match structure',
                children: switch (_model) {
                  'innings' => [
                    _num(_count, 'Innings per team'),
                    _num(_overs, 'Overs per innings'),
                    _num(_balls, 'Balls per over'),
                    _num(_wickets, 'Wickets per innings'),
                  ],
                  'round' => [
                    TextRow(
                      label: 'Best of (odd number)',
                      controller: _bestOf,
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final n = int.tryParse((v ?? '').trim()) ?? 0;
                        return n >= 1 && n.isOdd ? null : 'Enter an odd number, e.g. 3 or 5';
                      },
                    ),
                  ],
                  _ => [_num(_count, 'Number of periods'), _num(_minutes, 'Minutes per period')],
                },
              ),
              const SizedBox(height: 20),
              FormSection(
                header: 'Scoring rules',
                footer: 'Add a rule for every way to score, e.g. "Three pointer = 3".',
                children: [
                  for (final (i, e) in _events.indexed)
                    Column(
                      key: ObjectKey(e),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextRow(
                                label: 'Rule ${i + 1}',
                                hint: 'e.g. Free throw',
                                controller: e.name,
                                validator: (v) => _key(v ?? '').isEmpty ? 'Name the rule' : null,
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: TextRow(
                                label: valueLabel,
                                controller: e.value,
                                keyboardType: TextInputType.number,
                                validator: (v) => _wholeNumber(v, min: _model == 'innings' ? 0 : 1),
                              ),
                            ),
                            _removeButton(
                              'scoring rule ${i + 1}',
                              _events.length == 1 ? null : () => setState(() => _events.remove(e)),
                            ),
                          ],
                        ),
                        if (_model == 'innings') ...[
                          SwitchRow(
                            label: 'Counts as a legal ball',
                            value: e.legalBall,
                            onChanged: (v) => setState(() => e.legalBall = v),
                          ),
                          SwitchRow(
                            label: 'Is a wicket',
                            value: e.wicket,
                            onChanged: (v) => setState(() => e.wicket = v),
                          ),
                        ],
                      ],
                    ),
                  _AddRowButton(
                    key: const Key('add-scoring-rule'),
                    label: 'Add scoring rule',
                    onTap: () => setState(() => _events.add(_EventRule('', 1))),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FormSection(
                header: 'Result rules',
                children: [
                  SwitchRow(
                    label: 'Draws allowed',
                    subtitle: 'Off: a level match needs a tie-break winner',
                    value: _draws,
                    onChanged: (v) => setState(() => _draws = v),
                  ),
                  PickerRow<String>(
                    label: 'Overtime / tie-break',
                    initialValue: _overtime,
                    onChanged: (v) => setState(() => _overtime = v),
                    options: const [
                      PickerOption(value: 'none', label: 'None'),
                      PickerOption(value: 'extra_time', label: 'Extra time'),
                      PickerOption(value: 'shootout', label: 'Shootout'),
                      PickerOption(value: 'golden_score', label: 'Golden score'),
                      PickerOption(value: 'super_over', label: 'Super over'),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FormSection(
                header: 'Squad rules',
                footer: 'Position rules make every squad keep at least that many players in a position.',
                children: [
                  _num(_minSquad, 'Minimum squad size'),
                  TextRow(
                    label: 'Maximum squad size',
                    controller: _maxSquad,
                    keyboardType: TextInputType.number,
                    validator: (v) =>
                        _wholeNumber(v) ??
                        ((int.tryParse((v ?? '').trim()) ?? 0) < _int(_minSquad)
                            ? 'Must be at least the minimum'
                            : null),
                  ),
                  for (final (i, r) in _positions.indexed)
                    Row(
                      key: ObjectKey(r),
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextRow(
                            label: 'Position ${i + 1}',
                            hint: 'e.g. gk',
                            controller: r.position,
                            validator: (v) => _key(v ?? '').isEmpty ? 'Name the position' : null,
                          ),
                        ),
                        Expanded(flex: 2, child: _num(r.count, 'At least', min: 0)),
                        _removeButton('position rule ${i + 1}', () => setState(() => _positions.remove(r))),
                      ],
                    ),
                  _AddRowButton(
                    label: 'Add position rule',
                    onTap: () => setState(() => _positions.add(_PositionRule('', 1))),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                key: const Key('save-sport'),
                label: _editing ? 'Save rules' : 'Create sport',
                busy: _saving,
                onPressed: _save,
              ),
              if (_editing && canDeleteSport(widget.state) && _s['baseline'] != true) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  key: const Key('delete-sport'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFD70015),
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(CupertinoIcons.trash),
                  label: const Text('Delete sport'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _AddRowButton extends StatelessWidget {
  const _AddRowButton({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Icon(CupertinoIcons.add_circled_solid, color: Color(0xFF30A14E)),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(fontSize: 16, color: ocean, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ),
  );
}
