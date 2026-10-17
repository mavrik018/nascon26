import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_state.dart';
import '../../core/format.dart';

/// Shows the selected league and lets the user switch when there are several.
class LeaguePicker extends StatefulWidget {
  const LeaguePicker({super.key});

  @override
  State<LeaguePicker> createState() => _LeaguePickerState();
}

class _LeaguePickerState extends State<LeaguePicker> {
  List<Map<String, dynamic>> _leagues = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = AppScope.read(context);
    try {
      final loaded = await state.load('/api/v1/leagues');
      final list = [for (final l in asList(loaded.data)) asMap(l)];
      if (!mounted) return;
      setState(() => _leagues = list);
      final ids = list.map((l) => asStr(l['league_id'])).toList();
      if (ids.isNotEmpty && !ids.contains(state.leagueId)) await state.selectLeague(ids.first);
    } on ApiException {
      // Keep the current league; the screens below show their own errors.
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final current = state.leagueId;
    String nameOf(String id) => asStr(_leagues.where((l) => l['league_id'] == id).firstOrNull?['name'], humanize(id));
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.emoji_events_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: _leagues.length <= 1
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        nameOf(current),
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  : DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        key: const Key('league-picker'),
                        isExpanded: true,
                        value: _leagues.any((l) => l['league_id'] == current) ? current : null,
                        hint: const Text('Choose a league'),
                        items: [
                          for (final l in _leagues)
                            DropdownMenuItem(
                              value: asStr(l['league_id']),
                              child: Text(
                                asStr(l['name'], asStr(l['league_id'])),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) state.selectLeague(v);
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
