import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/app_state.dart';
import '../core/format.dart';
import '../features/settings/settings_screen.dart';

/// Tenant logo from the server, falling back to the tenant's initials.
class TenantLogo extends StatelessWidget {
  const TenantLogo({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final tenant = state.tenant;
    final scheme = Theme.of(context).colorScheme;
    final name = tenant?.name ?? 'League';
    final initials = name.trim().split(RegExp(r'\s+')).take(2).map((w) => w.isEmpty ? '' : w[0]).join();
    final fallback = CircleAvatar(
      radius: size / 2,
      backgroundColor: scheme.primary,
      child: Text(
        initials.toUpperCase(),
        style: TextStyle(color: scheme.onPrimary, fontWeight: FontWeight.bold, fontSize: size * 0.4),
      ),
    );
    final url = tenant?.logoUrl;
    if (url == null || url.isEmpty) return Semantics(label: '$name logo', child: fallback);
    final resolved = url.startsWith('http') ? url : '${state.baseUrl}${url.startsWith('/') ? '' : '/'}$url';
    return Semantics(
      label: '$name logo',
      image: true,
      child: ClipOval(
        child: Image.network(
          resolved,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

/// The app bar used on every screen: tenant logo + name, title, settings.
PreferredSizeWidget leagueAppBar(
  BuildContext context,
  String title, {
  List<Widget> actions = const [],
  PreferredSizeWidget? bottom,
}) {
  final state = AppScope.of(context);
  final canPop = Navigator.of(context).canPop();
  return AppBar(
    titleSpacing: canPop ? 0 : 16,
    title: Row(
      children: [
        const TenantLogo(size: 32),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                state.tenant?.name ?? 'League',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ],
    ),
    actions: [
      ...actions,
      IconButton(
        tooltip: 'Server settings',
        icon: const Icon(Icons.settings_outlined),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
      ),
    ],
    bottom: bottom,
  );
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.icon, required this.title, this.message});
  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry, this.offline = false});
  final String message;
  final VoidCallback? onRetry;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(offline ? Icons.cloud_off : Icons.error_outline, size: 56, color: theme.colorScheme.error),
          const SizedBox(height: 12),
          Text(
            offline ? 'No saved copy yet' : 'Could not load this screen',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
          ],
        ],
      ),
    );
  }
}

/// "Offline – showing saved data" strip above cached content.
class CachedNotice extends StatelessWidget {
  const CachedNotice({super.key, required this.savedAt});
  final DateTime? savedAt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: scheme.tertiaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.history, size: 20, color: scheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Offline – showing saved data${savedAt == null ? '' : ' from ${formatSavedAgo(savedAt)}'}',
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small pill with an icon AND text, so meaning never relies on color.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.icon, required this.label, required this.color, this.onColor});
  final IconData icon;
  final String label;
  final Color color;
  final Color? onColor;

  @override
  Widget build(BuildContext context) {
    final fg = onColor ?? Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class PendingPill extends StatelessWidget {
  const PendingPill({super.key, this.label = 'Pending sync'});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StatusPill(
      icon: Icons.schedule,
      label: label,
      color: scheme.secondaryContainer,
      onColor: scheme.onSecondaryContainer,
    );
  }
}

/// Loads [path] through the cache and rebuilds on pull-to-refresh.
/// [builder] must return a scrollable (ListView etc.).
class CachedLoader extends StatefulWidget {
  const CachedLoader({super.key, required this.path, required this.builder, this.isEmpty, this.empty});

  final String path;
  final Widget Function(BuildContext context, dynamic data, Future<void> Function() refresh) builder;
  final bool Function(dynamic data)? isEmpty;
  final Widget? empty;

  @override
  State<CachedLoader> createState() => CachedLoaderState();
}

class CachedLoaderState extends State<CachedLoader> {
  Loaded? _loaded;
  ApiException? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
  }

  @override
  void didUpdateWidget(CachedLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      setState(() {
        _loaded = null;
        _loading = true;
      });
      refresh();
    }
  }

  Future<void> refresh() async {
    final state = AppScope.read(context);
    final path = widget.path;
    try {
      final loaded = await state.load(path);
      if (!mounted || path != widget.path) return;
      setState(() {
        _loaded = loaded;
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || path != widget.path) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _loaded == null) {
      return Center(
        child: Semantics(label: 'Loading', child: const CircularProgressIndicator()),
      );
    }
    final loaded = _loaded;
    if (loaded == null) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          children: [
            ErrorView(
              message: _error?.message ?? 'Something went wrong.',
              onRetry: refresh,
              offline: _error?.isNetwork ?? false,
            ),
          ],
        ),
      );
    }
    final empty = widget.isEmpty?.call(loaded.data) ?? false;
    return Column(
      children: [
        if (loaded.fromCache) CachedNotice(savedAt: loaded.savedAt),
        Expanded(
          child: RefreshIndicator(
            onRefresh: refresh,
            child: empty
                ? ListView(
                    children: [widget.empty ?? const EmptyView(icon: Icons.inbox, title: 'Nothing here yet')],
                  )
                : widget.builder(context, loaded.data, refresh),
          ),
        ),
      ],
    );
  }
}

/// Confirmation dialog for risky actions. Returns true when confirmed.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(confirmLabel)),
      ],
    ),
  );
  return result ?? false;
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              error ? Icons.error_outline : Icons.check_circle_outline,
              color: error ? scheme.onErrorContainer : scheme.onInverseSurface,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: TextStyle(color: error ? scheme.onErrorContainer : null)),
            ),
          ],
        ),
        backgroundColor: error ? scheme.errorContainer : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
