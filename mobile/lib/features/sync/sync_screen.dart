import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../widgets/common.dart';

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: leagueAppBar(context, 'Sync queue'), body: const SyncPanel());
  }
}

/// Pending offline actions, a Sync button and the last per-action results.
class SyncPanel extends StatelessWidget {
  const SyncPanel({super.key, this.header});
  final Widget? header;

  Future<void> _sync(BuildContext context) async {
    final state = AppScope.read(context);
    final summary = await state.syncNow(announce: false);
    if (!context.mounted) return;
    if (state.lastSyncError != null) {
      showSnack(context, state.lastSyncError!, error: true);
    } else if (summary != null) {
      showSnack(context, summary.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final pending = state.pending;
    final log = state.log;
    final canSync = state.session != null && pending.isNotEmpty && !state.syncing;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ?header,
        Card(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(state.isOnline ? Icons.cloud_done_outlined : Icons.cloud_off, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        state.syncing
                            ? 'Syncing now…'
                            : state.isOnline
                            ? 'You are online'
                            : 'You are offline',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  pending.isEmpty
                      ? 'Nothing waiting to be sent.'
                      : state.isOnline
                      ? '${pending.length} action(s) waiting. They are sent automatically, or tap Sync now.'
                      : '${pending.length} action(s) saved on this phone. They will be sent automatically when you are back online.',
                ),
                if (state.lastSyncError != null) ...[
                  const SizedBox(height: 8),
                  Text(state.lastSyncError!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                if (state.lastSyncAt != null) ...[
                  const SizedBox(height: 4),
                  Text('Last sync: ${formatSavedAgo(state.lastSyncAt)}', style: theme.textTheme.bodySmall),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('sync-now'),
                    onPressed: canSync ? () => _sync(context) : null,
                    icon: state.syncing
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.sync),
                    label: Text(state.syncing ? 'Syncing…' : 'Sync now'),
                  ),
                ),
              ],
            ),
          ),
        ),
        SectionTitle('Pending actions (${pending.length})'),
        if (pending.isEmpty)
          const EmptyView(
            icon: Icons.task_alt,
            title: 'No pending actions',
            message: 'Actions you make while offline appear here until they are synced.',
          )
        else
          for (final a in pending) _PendingTile(action: a),
        SectionTitle('Last sync results'),
        if (log.isEmpty)
          const EmptyView(icon: Icons.history, title: 'No sync results yet')
        else
          for (final e in log) _ResultTile(entry: e),
      ],
    );
  }
}

class _PendingTile extends StatelessWidget {
  const _PendingTile({required this.action});
  final PendingAction action;

  @override
  Widget build(BuildContext context) {
    final isScore = action.type == ActionTypes.scoreEvent;
    return ListTile(
      leading: Icon(isScore ? Icons.scoreboard_outlined : Icons.swap_horiz),
      title: Text(action.label.isEmpty ? humanize(action.type) : action.label),
      subtitle: Text('${isScore ? 'Score entry' : 'Roster change'} · queued ${formatDateTime(action.queuedAt)}'),
      trailing: const PendingPill(label: 'Pending'),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.entry});
  final SyncLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, String label, Color bg, Color fg) = switch (entry.status) {
      'applied' => (Icons.check_circle, 'Applied', scheme.primaryContainer, scheme.onPrimaryContainer),
      'duplicate' => (Icons.content_copy, 'Already synced', scheme.surfaceContainerHighest, scheme.onSurface),
      _ => (Icons.cancel, 'Rejected', scheme.errorContainer, scheme.onErrorContainer),
    };
    return ListTile(
      leading: Icon(icon, color: fg == scheme.onSurface ? null : fg),
      title: Text(entry.label.isEmpty ? entry.actionId : entry.label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          StatusPill(icon: icon, label: label, color: bg, onColor: fg),
          const SizedBox(height: 4),
          Text(entry.message),
          Text(formatDateTime(entry.at), style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
