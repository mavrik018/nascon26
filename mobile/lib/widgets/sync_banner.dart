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

/// Compact Online / Offline / Syncing chip for page headers (spec 8.2: always visible). A coloured
/// dot plus words, so the state never depends on colour alone; shows the pending count when > 0.
class SyncDot extends StatelessWidget {
  const SyncDot({super.key, required this.state, this.onTap});
  final AppState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final n = state.pending.length;
    final (String text, Color dot) = switch (state.status) {
      NetStatus.syncing => ('Syncing', const Color(0xFF0A84FF)),
      NetStatus.offline => ('Offline', const Color(0xFFFF9F0A)),
      NetStatus.online => ('Online', const Color(0xFF30D158)),
    };
    final label = n == 0 ? text : '$text · $n';
    return Semantics(
      button: onTap != null,
      liveRegion: true,
      label: 'Connection: $text${n == 0 ? '' : ', $n pending'}. Open sync status.',
      excludeSemantics: true,
      child: Material(
        key: const Key('sync-dot'),
        color: Colors.black.withValues(alpha: .22),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.status == NetStatus.syncing)
                    const SizedBox.square(
                      dimension: 10,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  else
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
