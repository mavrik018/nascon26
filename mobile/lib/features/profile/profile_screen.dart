import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../widgets/common.dart';
import '../store/receipt_screen.dart';
import '../sync/sync_screen.dart';

/// Account, recent orders, and the sync queue.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final user = state.user;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: leagueAppBar(context, 'Profile & sync'),
      body: SyncPanel(
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 24,
                          child: Text(user == null || user.name.isEmpty ? '?' : user.name[0].toUpperCase()),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(user?.name ?? '', style: theme.textTheme.titleMedium),
                              Text(user?.email ?? '', style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Chip(
                          avatar: const Icon(Icons.badge_outlined, size: 18),
                          label: Text(Roles.label(user?.role ?? '')),
                        ),
                        if (state.tenant != null)
                          Chip(avatar: const Icon(Icons.apartment, size: 18), label: Text(state.tenant!.name)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('switch-account'),
                          onPressed: () => state.logout(),
                          icon: const Icon(Icons.switch_account_outlined),
                          label: const Text('Switch account'),
                        ),
                        TextButton.icon(
                          key: const Key('logout'),
                          onPressed: () async {
                            final ok = await confirmAction(
                              context,
                              title: 'Sign out of this phone?',
                              message: state.pending.isEmpty
                                  ? 'You will need your password to sign in again.'
                                  : 'You have ${state.pending.length} action(s) waiting to sync. '
                                        'They stay on this phone and sync after you sign in again.',
                              confirmLabel: 'Sign out',
                            );
                            if (ok) await state.logout(forget: true);
                          },
                          icon: const Icon(Icons.logout),
                          label: const Text('Sign out'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Switch account keeps this login on the phone, so you can come back to it even offline.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const _RecentOrders(),
          ],
        ),
      ),
    );
  }
}

class _RecentOrders extends StatelessWidget {
  const _RecentOrders();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return FutureBuilder<dynamic>(
      future: state.cached('local:orders'),
      builder: (context, snap) {
        final orders = [for (final o in asList(snap.data)) asMap(o)];
        if (orders.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionTitle('My orders'),
            for (final o in orders.take(5))
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text('Order ${asStr(o['order_id'])}'),
                subtitle: Text(formatMoney(asInt(o['total_minor']), asStr(o['currency'], 'PKR'))),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiptScreen(order: o))),
              ),
          ],
        );
      },
    );
  }
}
