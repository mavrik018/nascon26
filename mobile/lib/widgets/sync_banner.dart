import 'package:flutter/material.dart';

import '../core/app_state.dart';

/// Always-visible connection + queue indicator shown above every screen.
class SyncBanner extends StatelessWidget {
  const SyncBanner({super.key, required this.state, this.onTap});
  final AppState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = state.pending.length;
    final pendingText = n == 0 ? '' : ' · $n pending';
    late final IconData icon;
    late final String text;
    late final Color bg;
    late final Color fg;
    switch (state.status) {
      case NetStatus.syncing:
        icon = Icons.sync;
        text = 'Syncing $n action${n == 1 ? '' : 's'}…';
        bg = scheme.primaryContainer;
        fg = scheme.onPrimaryContainer;
      case NetStatus.offline:
        icon = Icons.cloud_off;
        text = 'Offline$pendingText';
        bg = scheme.inverseSurface;
        fg = scheme.onInverseSurface;
      case NetStatus.online:
        icon = n == 0 ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined;
        text = n == 0 ? 'Online' : 'Online$pendingText – tap to sync';
        bg = n == 0 ? scheme.surfaceContainerHigh : scheme.secondaryContainer;
        fg = n == 0 ? scheme.onSurface : scheme.onSecondaryContainer;
    }
    return Semantics(
      container: true,
      button: onTap != null,
      liveRegion: true,
      label: 'Connection status: $text. Opens sync queue.',
      excludeSemantics: true,
      child: Material(
        color: bg,
        child: InkWell(
          key: const Key('sync-banner'),
          onTap: onTap,
          child: SafeArea(
            bottom: false,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    if (state.status == NetStatus.syncing)
                      SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                    else
                      Icon(icon, size: 20, color: fg),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (onTap != null) Icon(Icons.chevron_right, size: 20, color: fg),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
