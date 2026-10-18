import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';

/// Screens opened from `nascon://` deep links (spec 6.3). They read only public endpoints, so they work
/// signed out (guest, read-only) and never stop on the sign-in screen.

Future<void> _whenReady(AppState state) {
  if (state.ready) return Future.value();
  final done = Completer<void>();
  void check() {
    if (state.ready && !done.isCompleted) {
      state.removeListener(check);
      done.complete();
    }
  }

  state.addListener(check);
  return done.future;
}

Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _list(dynamic v) {
  final raw = v is List ? v : (v is Map && v['messages'] is List ? v['messages'] as List : const []);
  return [for (final m in raw) _map(m)];
}

/// Polls [load] every [every] once the app is ready; rebuilds with the latest value or error.
mixin _Polling<T extends StatefulWidget> on State<T> {
  Timer? _timer;
  Object? error;
  bool loading = true;

  AppState get appState;
  Duration get every;
  Future<void> load();

  @override
  void initState() {
    super.initState();
    _whenReady(appState).then((_) {
      if (!mounted) return;
      _tick();
      _timer = Timer.periodic(every, (_) => _tick());
    });
  }

  Future<void> _tick() async {
    try {
      await load();
      error = null;
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class GuestMatchLivePage extends StatefulWidget {
  const GuestMatchLivePage({super.key, required this.state, required this.matchId});
  final AppState state;
  final String matchId;

  @override
  State<GuestMatchLivePage> createState() => _GuestMatchLivePageState();
}

class _GuestMatchLivePageState extends State<GuestMatchLivePage> with _Polling {
  Map<String, dynamic> match = const {};
  List<Map<String, dynamic>> chat = const [];

  @override
  AppState get appState => widget.state;
  @override
  Duration get every => const Duration(seconds: 2);

  @override
  Future<void> load() async {
    match = _map(await widget.state.api.get('/api/v1/public/matches/${widget.matchId}'));
    final room = match['chat_room_id'];
    if (room is String && room.isNotEmpty) chat = _list(await widget.state.api.get('/api/v1/public/chat/$room'));
  }

  @override
  Widget build(BuildContext context) {
    final home = _map(match['home']);
    final away = _map(match['away']);
    final product = _map(match['pinned_product']);
    final theme = Theme.of(context);
    return Semantics(
      label: 'Match Live screen ${widget.matchId}',
      container: true,
      child: Scaffold(
        appBar: AppBar(title: const Text('Match Live')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(widget.matchId, style: theme.textTheme.labelLarge),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(child: Text('${home['team_id'] ?? 'Home'}', overflow: TextOverflow.ellipsis)),
                    Semantics(
                      label: 'Live score',
                      child: Text('${home['score'] ?? 0} - ${away['score'] ?? 0}',
                          key: const Key('live-score'), style: theme.textTheme.headlineMedium),
                    ),
                    Flexible(
                      child: Text('${away['team_id'] ?? 'Away'}', overflow: TextOverflow.ellipsis, textAlign: TextAlign.end),
                    ),
                  ],
                ),
              ),
            ),
            if (match['status'] != null) Text('Status: ${match['status']}'),
            if (loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            if (error != null && match.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('Live data is not available right now.')),
            if (product.isNotEmpty)
              Card(
                child: ListTile(
                  title: Text('${product['name'] ?? product['product_id']}'),
                  subtitle: product['price_minor'] is num
                      ? Text('PKR ${((product['price_minor'] as num) / 100).toStringAsFixed(0)}')
                      : null,
                  trailing: const Text('Pinned'),
                ),
              ),
            const SizedBox(height: 8),
            Text('Live chat', style: theme.textTheme.titleMedium),
            for (final m in chat) ListTile(dense: true, title: Text('${m['text']}'), subtitle: Text('${m['sender']}')),
            if (chat.isEmpty && !loading) const Text('No messages yet.'),
          ],
        ),
      ),
    );
  }
}

class CoStreamPage extends StatefulWidget {
  const CoStreamPage({super.key, required this.state, required this.sessionId});
  final AppState state;
  final String sessionId;

  @override
  State<CoStreamPage> createState() => _CoStreamPageState();
}

class _CoStreamPageState extends State<CoStreamPage> with _Polling {
  Map<String, dynamic> session = const {};
  List<Map<String, dynamic>> chat = const [];

  @override
  AppState get appState => widget.state;
  @override
  Duration get every => const Duration(seconds: 1);

  @override
  Future<void> load() async {
    session = _map(await widget.state.api.get('/api/v1/public/costream/${widget.sessionId}'));
    final room = session['chat_room_id'] ?? 'chat-${widget.sessionId}';
    chat = _list(await widget.state.api.get('/api/v1/public/chat/$room'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = session['active_host'];
    final participants = [
      for (final p in (session['active_participants'] as List? ?? const []))
        p is Map ? '${p['user_id'] ?? p['participant_id']}' : '$p',
    ];
    return Semantics(
      label: 'Co-Stream screen ${widget.sessionId}',
      container: true,
      child: Scaffold(
        appBar: AppBar(title: const Text('Co-Stream')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(widget.sessionId, style: theme.textTheme.labelLarge),
            if (session['layout'] != null) Text('Layout: ${session['layout']}'),
            const SizedBox(height: 12),
            Text('On stream', style: theme.textTheme.titleMedium),
            if (host != null) ListTile(dense: true, leading: const Icon(Icons.mic), title: Text('$host (host)')),
            for (final p in participants.where((p) => p != '$host'))
              ListTile(dense: true, leading: const Icon(Icons.person), title: Text(p)),
            if (loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            if (error != null && session.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('Co-stream data is not available right now.')),
            const SizedBox(height: 8),
            Text('Live chat', style: theme.textTheme.titleMedium),
            for (final m in chat)
              ListTile(
                key: ValueKey('chat-${m['message_id']}'),
                dense: true,
                title: Text('${m['text']}'),
                subtitle: Text('${m['sender']}'),
              ),
            if (chat.isEmpty && !loading) const Text('No messages yet.'),
          ],
        ),
      ),
    );
  }
}
