import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import 'club_screens.dart' show ClubPage, PlayerPage, plainError;
import 'ocean_widgets.dart';

/// Screens opened from `nascon://` deep links (spec 6.3) as well as from the in-app
/// Match Centre ("Live & QR" tab) and Profile ("Live Broadcast & QR Studio").
/// They read public endpoints so they work both signed out (guest, read-only) and signed in.

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
  final _chatCtrl = TextEditingController();
  bool _sending = false;

  @override
  AppState get appState => widget.state;
  @override
  Duration get every => const Duration(seconds: 2);

  @override
  void dispose() {
    _chatCtrl.dispose();
    super.dispose();
  }

  @override
  Future<void> load() async {
    match = _map(await widget.state.api.get('/api/v1/public/matches/${widget.matchId}'));
    final room = match['chat_room_id'];
    if (room is String && room.isNotEmpty) chat = _list(await widget.state.api.get('/api/v1/public/chat/$room'));
  }

  Future<void> _sendChat() async {
    final text = _chatCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    final room = asStr(match['chat_room_id'], 'chat-${widget.matchId}');
    setState(() => _sending = true);
    try {
      await widget.state.api.send('POST', '/api/v1/chat', {
        'chat_room_id': room,
        'text': text,
      });
      _chatCtrl.clear();
      await _tick();
    } catch (e) {
      if (mounted) notice(context, plainError(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final home = _map(match['home']);
    final away = _map(match['away']);
    final product = _map(match['pinned_product']);
    final playbackUrl = asStr(match['playback_url'], 'http://localhost:8888/matches/${widget.matchId}/index.m3u8');
    final theme = Theme.of(context);
    return Semantics(
      label: 'Match Live screen ${widget.matchId}',
      container: true,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Match Live'),
          actions: [
            IconButton(
              key: const Key('show-qr'),
              tooltip: 'Show QR code for this match',
              icon: const Icon(Icons.qr_code_2),
              onPressed: () => showQrSheet(context, widget.state, widget.matchId),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(widget.matchId, style: theme.textTheme.labelLarge),
            const SizedBox(height: 12),
            Card(
              color: const Color(0xFF072B44),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.live_tv, color: Colors.white),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'HLS / WebRTC Live Stream Player',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFBE3450),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            asStr(match['status'], 'LIVE').toUpperCase(),
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      playbackUrl,
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
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
                  leading: const Icon(Icons.shopping_bag_outlined, color: ocean),
                  title: Text('${product['name'] ?? product['product_id']}'),
                  subtitle: product['price_minor'] is num
                      ? Text('PKR ${((product['price_minor'] as num) / 100).toStringAsFixed(0)}')
                      : null,
                  trailing: const Text('Pinned'),
                ),
              ),
            const SizedBox(height: 12),
            Text('Live chat', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            if (widget.state.session != null)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('live-chat-input'),
                      controller: _chatCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Say something in live chat…',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendChat(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('live-chat-send'),
                    onPressed: _sending ? null : _sendChat,
                    child: const Text('Send'),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            for (final m in chat)
              ListTile(
                dense: true,
                title: Text('${m['text']}'),
                subtitle: Text('${m['sender']}'),
                trailing: m['flagged'] == true ? const Tag('MOD', color: Color(0xFFB3261E)) : null,
              ),
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
  Map<String, dynamic> controls = const {};
  List<Map<String, dynamic>> chat = const [];
  final _chatCtrl = TextEditingController();
  bool _sending = false;

  @override
  AppState get appState => widget.state;
  @override
  Duration get every => const Duration(seconds: 1);

  @override
  void dispose() {
    _chatCtrl.dispose();
    super.dispose();
  }

  @override
  Future<void> load() async {
    // Chat must not depend on the session lookup: fall back to the conventional room id (same as the web player).
    Object? sessionError;
    try {
      session = _map(await widget.state.api.get('/api/v1/public/costream/${widget.sessionId}'));
    } catch (e) {
      sessionError = e;
    }
    try {
      controls = _map(await widget.state.api.get('/api/v1/public/costream/${widget.sessionId}/state'));
    } catch (_) {}
    final room = session['chat_room_id'] ?? 'chat-${widget.sessionId}';
    chat = _list(await widget.state.api.get('/api/v1/public/chat/$room'));
    if (sessionError != null) throw sessionError;
  }

  Future<void> _sendChat() async {
    final text = _chatCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    final room = asStr(session['chat_room_id'], 'chat-${widget.sessionId}');
    setState(() => _sending = true);
    try {
      await widget.state.api.send('POST', '/api/v1/chat', {
        'chat_room_id': room,
        'text': text,
      });
      _chatCtrl.clear();
      await _tick();
    } catch (e) {
      if (mounted) notice(context, plainError(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _hostAction(String action, String playerId) async {
    try {
      final res = _map(await widget.state.api.send(
        'POST',
        '/api/v1/costream/${widget.sessionId}/controls',
        {'action': action, 'player_id': playerId},
      ));
      if (!mounted) return;
      setState(() => controls = res);
      await _tick();
      if (mounted) notice(context, '${humanize(action)}: $playerId', kind: ToastKind.success);
    } catch (e) {
      if (mounted) notice(context, plainError(e), kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = session['active_host'];
    final participants = [
      for (final p in (session['active_participants'] as List? ?? const []))
        p is Map ? '${p['user_id'] ?? p['participant_id']}' : '$p',
    ];
    final mutedList = [for (final m in asList(controls['muted'])) '$m'];
    final spotlight = controls['spotlight']?.toString();
    final canControl = widget.state.user?.role == 'super_admin' ||
        (widget.state.user?.playerId != null && widget.state.user?.playerId == '$host');
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
            if (session['composite_playback_url'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Composite HLS: ${session['composite_playback_url']}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            Text('On stream', style: theme.textTheme.titleMedium),
            if (host != null)
              ListTile(
                dense: true,
                leading: const Icon(Icons.mic),
                title: Text('$host (host)'),
                trailing: spotlight == '$host' ? const Tag('SPOTLIGHT', color: ocean) : null,
              ),
            for (final p in participants.where((p) => p != '$host'))
              ListTile(
                dense: true,
                leading: Icon(mutedList.contains(p) ? Icons.mic_off : Icons.person),
                title: Text(p),
                subtitle: [
                  if (mutedList.contains(p)) 'Muted',
                  if (spotlight == p) 'Spotlight',
                ].isEmpty
                    ? null
                    : Text([
                        if (mutedList.contains(p)) 'Muted',
                        if (spotlight == p) 'Spotlight',
                      ].join(' · ')),
                trailing: canControl
                    ? PopupMenuButton<String>(
                        tooltip: 'Host controls for $p',
                        onSelected: (act) => _hostAction(act, p),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: mutedList.contains(p) ? 'unmute' : 'mute',
                            child: Text(mutedList.contains(p) ? 'Unmute' : 'Mute'),
                          ),
                          const PopupMenuItem(value: 'spotlight', child: Text('Spotlight')),
                          const PopupMenuItem(value: 'kick', child: Text('Kick')),
                        ],
                      )
                    : null,
              ),
            if (loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            if (error != null && session.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('Co-stream data is not available right now.')),
            const SizedBox(height: 8),
            Text('Live chat', style: theme.textTheme.titleMedium),
            if (widget.state.session != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('costream-chat-input'),
                      controller: _chatCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Message co-stream chat…',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendChat(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('costream-chat-send'),
                    onPressed: _sending ? null : _sendChat,
                    child: const Text('Send'),
                  ),
                ],
              ),
            ],
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

/// Interactive Day 2 hub accessible directly from Profile -> "Live Broadcast & QR Studio".
/// Lets users & judges test Creator Stream Keys, 4-Way Co-Streaming, Host Controls,
/// Live Match Broadcasts, Athlete Social Profiles, and Dynamic QR Short-Links without CLI commands.
class BroadcastHubPage extends StatefulWidget {
  const BroadcastHubPage({super.key, required this.state});
  final AppState state;

  @override
  State<BroadcastHubPage> createState() => _BroadcastHubPageState();
}

class _BroadcastHubPageState extends State<BroadcastHubPage> {
  Map<String, dynamic>? streamKeyData;
  Map<String, dynamic>? costreamData;
  Map<String, dynamic>? qrData;
  String selectedLayout = 'grid_4';
  bool simulateDrop = false;
  String qrEntityId = 'match-m1';
  bool busy = false;

  String get broadcasterId => widget.state.user?.playerId ?? 'player-alpha-1';

  @override
  void initState() {
    super.initState();
    _loadQr('match-m1');
  }

  Future<void> _manageKey(String action) async {
    setState(() => busy = true);
    try {
      final res = _map(await widget.state.api.send(
        'POST',
        '/audit/v1/stream/key',
        {
          'action': action,
          'player_id': broadcasterId,
          'label': 'mobile-studio',
        },
      ));
      if (!mounted) return;
      setState(() => streamKeyData = res);
      notice(context, 'Stream key ${action}d (${res['status']})', kind: ToastKind.success);
    } catch (e) {
      if (mounted) notice(context, plainError(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _launchCoStream() async {
    setState(() => busy = true);
    try {
      final parts = selectedLayout == 'solo'
          ? ['player-alpha-1']
          : selectedLayout == 'grid_2'
          ? ['player-alpha-1', 'player-alpha-2']
          : ['player-alpha-1', 'player-alpha-2', 'player-beta-1', 'player-beta-2'];
      final res = _map(await widget.state.api.send(
        'POST',
        '/audit/v1/costream/session',
        {
          'session_id': 'cs-session-101',
          'host_player_id': 'player-alpha-1',
          'participants': parts,
          'layout': selectedLayout,
          'simulate_host_drop': simulateDrop,
        },
      ));
      if (!mounted) return;
      setState(() => costreamData = res);
      notice(
        context,
        res['handoff_occurred'] == true
            ? 'Host handoff → ${res['active_host']}'
            : 'Co-stream active (${res['layout']})',
        kind: ToastKind.success,
      );
    } catch (e) {
      if (mounted) notice(context, plainError(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _loadQr(String entityId) async {
    setState(() {
      qrEntityId = entityId;
      busy = true;
    });
    try {
      final res = _map(await widget.state.api.get('/audit/v1/qr/$entityId?inspect=true'));
      if (!mounted) return;
      setState(() => qrData = res);
    } catch (e) {
      if (mounted) notice(context, plainError(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ingest = _map(streamKeyData?['ingest_endpoints']);
    final exports = _map(qrData?['export_formats']);
    return OceanPage(
      title: 'Broadcast & QR Studio',
      subtitle: 'LIVE STREAMING · CO-STREAM · DYNAMIC QR',
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeading('Live Watch & Co-Stream', trailing: Tag('DAY 2 LIVE')),
              const Text(
                'Open the real-time Match Live player (score SSE + pinned merch + moderated chat) '
                'or the 4-way Co-Stream room.',
                style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: muted),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('open-match-live-btn'),
                onPressed: () => openPage(
                  context,
                  GuestMatchLivePage(state: widget.state, matchId: 'match-m1'),
                ),
                icon: const Icon(Icons.live_tv),
                label: const Text('Watch Live Match (match-m1)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('open-costream-btn'),
                onPressed: () => openPage(
                  context,
                  CoStreamPage(state: widget.state, sessionId: 'cs-session-101'),
                ),
                icon: const Icon(Icons.grid_view_rounded),
                label: const Text('Open 4-Way Co-Stream (cs-session-101)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('open-athlete-profile-btn'),
                onPressed: () => openPage(
                  context,
                  PlayerPage(state: widget.state, playerId: 'player-alpha-1'),
                ),
                icon: const Icon(Icons.person_pin_outlined),
                label: const Text('Open Athlete Social Profile (player-alpha-1)'),
              ),
            ],
          ),
        ),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeading('Creator Stream Key', trailing: Tag(broadcasterId)),
              const Text(
                'Issue, rotate or revoke your MediaMTX RTMP / WebRTC WHIP broadcast key.',
                style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: muted),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    key: const Key('stream-key-generate'),
                    onPressed: busy ? null : () => _manageKey('generate'),
                    icon: const Icon(Icons.key),
                    label: const Text('Generate'),
                  ),
                  FilledButton.tonalIcon(
                    key: const Key('stream-key-rotate'),
                    onPressed: busy ? null : () => _manageKey('rotate'),
                    icon: const Icon(Icons.autorenew),
                    label: const Text('Rotate'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('stream-key-revoke'),
                    onPressed: busy ? null : () => _manageKey('revoke'),
                    icon: const Icon(Icons.block),
                    label: const Text('Revoke'),
                  ),
                ],
              ),
              if (streamKeyData != null) ...[
                const Divider(height: 20),
                DetailRow('Key', asStr(streamKeyData!['stream_key'])),
                DetailRow('Status', asStr(streamKeyData!['status']).toUpperCase()),
                if (ingest.isNotEmpty) ...[
                  DetailRow('RTMP Ingest', asStr(ingest['rtmp'])),
                  DetailRow('WebRTC WHIP', asStr(ingest['webrtc'])),
                ],
                if (streamKeyData!['playback_url'] != null)
                  DetailRow('HLS Playback', asStr(streamKeyData!['playback_url'])),
              ],
            ],
          ),
        ),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeading('4-Way Co-Stream Orchestrator', trailing: Tag('MAX 4')),
              ChoiceRow(
                items: const ['grid_4', 'grid_2', 'solo', 'spotlight'],
                value: selectedLayout,
                onChanged: (v) => setState(() => selectedLayout = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Simulate host drop (auto handoff)', style: TextStyle(fontSize: 13)),
                value: simulateDrop,
                onChanged: (v) => setState(() => simulateDrop = v),
              ),
              FilledButton.icon(
                key: const Key('apply-costream-session'),
                onPressed: busy ? null : _launchCoStream,
                icon: const Icon(Icons.podcasts),
                label: const Text('Apply Co-Stream Session'),
              ),
              if (costreamData != null) ...[
                const Divider(height: 20),
                DetailRow('Active host', asStr(costreamData!['active_host'], 'None')),
                DetailRow('Handoff occurred', '${costreamData!['handoff_occurred']}'),
                DetailRow('Participants', '${costreamData!['participant_count']} active'),
                DetailRow('Composite HLS', asStr(costreamData!['composite_playback_url'])),
              ],
            ],
          ),
        ),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeading('Dynamic QR & Deep-Link Resolver', trailing: Tag('QR')),
              ChoiceRow(
                items: const ['match-m1', 'player-alpha-1', 'club-alpha-1', 'cs-session-101'],
                value: qrEntityId,
                onChanged: _loadQr,
              ),
              if (qrData != null) ...[
                const SizedBox(height: 8),
                DetailRow('Entity', '${qrData!['entity_id']} (${qrData!['entity_type']})'),
                DetailRow('Live status', asStr(qrData!['entity_status'])),
                DetailRow('Short URL', asStr(qrData!['short_url'])),
                DetailRow('Target route', asStr(qrData!['target_route'])),
                DetailRow('Deep link URI', asStr(qrData!['deep_link_uri'])),
                DetailRow('Scan count', '${qrData!['scan_count']}'),
                if (exports.isNotEmpty)
                  DetailRow('Exports', 'SVG · PNG · PDF'),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    if (qrEntityId.startsWith('match-')) {
                      openPage(context, GuestMatchLivePage(state: widget.state, matchId: qrEntityId));
                    } else if (qrEntityId.startsWith('cs-session-')) {
                      openPage(context, CoStreamPage(state: widget.state, sessionId: qrEntityId));
                    } else if (qrEntityId.startsWith('player-')) {
                      openPage(context, PlayerPage(state: widget.state, playerId: qrEntityId));
                    } else if (qrEntityId.startsWith('club-')) {
                      openPage(context, ClubPage(state: widget.state, clubId: qrEntityId));
                    }
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: Text('Open $qrEntityId in App'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}



/// FR-4.1: the dynamic QR for any entity (match / club / player / co-stream), rendered by the server
/// (GET /audit/v1/qr/{id}/export.png). Its short link stays the same; where it leads follows the live state.
Future<void> showQrSheet(BuildContext context, AppState state, String entityId) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (ctx) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Scan to watch', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Image.network(
            '${state.baseUrl}/audit/v1/qr/$entityId/export.png',
            width: 240,
            height: 240,
            semanticLabel: 'QR code for $entityId',
            errorBuilder: (_, _, _) => const SizedBox(
              height: 120,
              child: Center(child: Text('QR code could not be loaded. Check the connection.')),
            ),
          ),
          const SizedBox(height: 8),
          SelectableText('nascon://entity/$entityId', style: const TextStyle(fontSize: 13)),
        ],
      ),
    ),
  ),
);
