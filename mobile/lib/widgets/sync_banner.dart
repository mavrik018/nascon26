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

/// iOS-style floating status pill (always visible, above the tab bar): shows
/// Online / Offline / Syncing and the number of pending offline actions.
class SyncPill extends StatelessWidget {
  const SyncPill({super.key, required this.state, this.onTap});
  final AppState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final n = state.pending.length;
    // Quiet when all is well: shown only when offline, syncing or changes are waiting.
    if (state.status == NetStatus.online && n == 0) return const SizedBox.shrink();
    final (IconData icon, String text, Color dot) = switch (state.status) {
      NetStatus.syncing => (Icons.sync, 'Syncing $n…', const Color(0xFF0A84FF)),
      NetStatus.offline => (Icons.cloud_off, n == 0 ? 'Offline' : 'Offline · $n pending', const Color(0xFFFF9F0A)),
      NetStatus.online => (
          n == 0 ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
          n == 0 ? 'Online' : 'Online · $n pending',
          const Color(0xFF30D158),
        ),
    };
    return Semantics(
      button: onTap != null,
      liveRegion: true,
      label: 'Connection: $text. Open sync status.',
      child: Material(
        color: const Color(0xF21C1C1E),
        shape: const StadiumBorder(),
        elevation: 6,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Icon(icon, size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(text, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
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
