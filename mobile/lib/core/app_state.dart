import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../features/store/cart.dart';
import 'api_client.dart';
import 'errors.dart';
import 'format.dart';
import 'local_store.dart';
import 'models.dart';

/// Result of [AppState.load]: the data, and whether it came from the cache.
class Loaded {
  const Loaded(this.data, {this.fromCache = false, this.savedAt});
  final dynamic data;
  final bool fromCache;
  final DateTime? savedAt;
}

enum SubmitStatus { sent, queued }

class SubmitOutcome {
  const SubmitOutcome(this.status, [this.response]);
  final SubmitStatus status;
  final dynamic response;
  bool get queued => status == SubmitStatus.queued;
}

class SyncSummary {
  const SyncSummary(this.applied, this.rejected, this.duplicate);
  final int applied;
  final int rejected;
  final int duplicate;

  String get text {
    final parts = <String>[];
    if (applied > 0) parts.add('$applied applied');
    if (duplicate > 0) parts.add('$duplicate already on server');
    if (rejected > 0) parts.add('$rejected rejected');
    return parts.isEmpty ? 'Nothing to sync' : 'Sync finished: ${parts.join(', ')}';
  }
}

enum NetStatus { online, offline, syncing }

/// The whole app's state: session, connectivity, cache access and the
/// offline queue. Screens read it through AppScope.
class AppState extends ChangeNotifier {
  AppState({
    required this.store,
    required this.tokens,
    http.Client? httpClient,
    Stream<bool>? networkChanges,
    Future<bool> Function()? checkNetwork,
    this.probeInterval = const Duration(seconds: 10),
  }) : _httpClient = httpClient,
       _networkChanges = networkChanges,
       _checkNetwork = checkNetwork;

  /// First-launch default only. The real address is entered in the app (sign-in screen
  /// "Server" / Profile) and persisted locally, so a new laptop IP never needs a rebuild.
  /// A permitted public URL can be baked in with --dart-define=API_BASE_URL=https://...
  static const defaultBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8080');
  static const demoRosterLeague = 'league-alpha-1';
  static const demoClubs = ['club-alpha-1', 'club-alpha-2'];

  final LocalStore store;
  final TokenStore tokens;
  final http.Client? _httpClient;
  final Stream<bool>? _networkChanges;
  final Future<bool> Function()? _checkNetwork;
  final Duration probeInterval;

  late final ApiClient api;
  final Cart cart = Cart();
  final _messages = StreamController<String>.broadcast();

  /// One-line messages for a global snackbar (e.g. auto-sync finished).
  Stream<String> get messages => _messages.stream;

  bool ready = false;
  bool onboardingSeen = false;
  Session? session;
  String? sessionNotice;
  bool hasNetwork = true;
  bool serverReachable = true;
  bool syncing = false;
  String? lastSyncError;
  DateTime? lastSyncAt;
  List<PendingAction> pending = const [];
  List<SyncLogEntry> log = const [];
  String deviceId = '';
  String? selectedLeagueId;
  final Map<String, String> teamNames = {};

  StreamSubscription<bool>? _netSub;
  Timer? _timer;
  bool _disposed = false;

  AppUser? get user => session?.user;

  /// League shown on Fixtures / Standings.
  String get leagueId => selectedLeagueId ?? user?.leagueId ?? demoRosterLeague;

  /// League used for roster requests (the user's own league, else the demo one).
  String get rosterLeagueId => user?.leagueId ?? selectedLeagueId ?? demoRosterLeague;
  Tenant? get tenant => session?.tenant;
  bool get isOnline => hasNetwork && serverReachable;
  NetStatus get status => syncing
      ? NetStatus.syncing
      : isOnline
      ? NetStatus.online
      : NetStatus.offline;

  Future<void> init() async {
    final savedUrl = await store.getSetting('base_url');
    api = ApiClient(baseUrl: savedUrl ?? defaultBaseUrl, client: _httpClient)
      ..onReachability = _setReachable
      ..onUnauthorized = _handleUnauthorized;

    var device = await store.getSetting('device_id');
    if (device == null) {
      device = newId();
      await store.setSetting('device_id', device);
    }
    deviceId = device;
    selectedLeagueId = await store.getSetting('league_id');
    final names = await store.getSetting('team_names');
    if (names != null) {
      try {
        teamNames.addAll(Map<String, String>.from(jsonDecode(names) as Map));
      } catch (_) {}
    }

    final accounts = await tokens.read('accounts');
    if (accounts != null) {
      try {
        savedAccounts = [
          for (final a in jsonDecode(accounts) as List) Session.fromJson(Map<String, dynamic>.from(a as Map)),
        ];
      } catch (_) {}
    }
    final raw = await tokens.read('session');
    if (raw != null) {
      try {
        session = Session.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
        api.token = session!.token;
      } catch (_) {
        session = null;
      }
    }
    final seenOnboarding = await store.getSetting('onboarding_seen');
    onboardingSeen = seenOnboarding == 'true' || session != null;
    if (onboardingSeen && seenOnboarding != 'true') {
      await store.setSetting('onboarding_seen', 'true');
    }
    await _reloadQueue();

    if (_checkNetwork != null) hasNetwork = await _checkNetwork();
    _netSub = _networkChanges?.listen(_onNetworkChanged);
    _timer = Timer.periodic(probeInterval, (_) => _tick());
    ready = true;
    _notify();
    if (session != null && pending.isNotEmpty && isOnline) unawaited(syncNow());
  }

  /// Marks first-launch onboarding as completed and persists it in SQLite so it is never shown again.
  Future<void> completeOnboarding() async {
    onboardingSeen = true;
    await store.setSetting('onboarding_seen', 'true');
    _notify();
  }

  String get baseUrl => api.baseUrl;

  Future<void> setBaseUrl(String url) async {
    api.baseUrl = url;
    await store.setSetting('base_url', api.baseUrl);
    serverReachable = true;
    _notify();
  }

  /// Checks that the server answers at all. Returns a plain-language result.
  Future<String> testConnection([String? url]) async {
    final probe = ApiClient(baseUrl: url ?? baseUrl, client: _httpClient);
    try {
      await probe.get('/api/v1/ping');
      return 'Connected to the server.';
    } on ApiException catch (e) {
      if (e.isNetwork) return e.message;
      return 'The server answered, so the address is correct.';
    }
  }

  // ---------------------------------------------------------------- session

  Future<void> login(String email, String password) async {
    await _signIn(asMap(await api.post('/api/v1/auth/login', {'email': email.trim(), 'password': password})));
  }

  /// Self sign-up as a player (creates the login and the player profile), then signs in.
  Future<void> register({
    required String name,
    required String email,
    required String password,
    String position = 'mf',
  }) async {
    await _signIn(asMap(await api.post('/api/v1/auth/register', {
      'display_name': name.trim(),
      'email': email.trim(),
      'password': password,
      'position': position,
    })));
  }

  Future<void> _signIn(Map<String, dynamic> res) async {
    final token = asStr(res['token'] ?? res['access_token']);
    if (token.isEmpty) {
      throw const ApiException('The server did not return a sign-in token. Please try again.');
    }
    api.token = token;
    var userJson = asMap(res['user']);
    var tenantJson = res['tenant'];
    if (userJson.isEmpty) {
      final me = asMap(await api.get('/api/v1/me'));
      userJson = me['user'] is Map ? asMap(me['user']) : me;
      tenantJson ??= me['tenant'];
    }
    session = Session(
      token: token,
      user: AppUser.fromJson(userJson),
      tenant: tenantJson is Map ? Tenant.fromJson(asMap(tenantJson)) : null,
    );
    await _activate(session!);
  }

  Future<void> _activate(Session s) async {
    session = s;
    api.token = s.token;
    sessionNotice = null;
    onboardingSeen = true;
    await store.setSetting('onboarding_seen', 'true');
    await tokens.write('session', jsonEncode(s.toJson()));
    savedAccounts = [s, ...savedAccounts.where((a) => a.user.email != s.user.email)];
    await _saveAccounts();
    if (s.user.leagueId != null) await selectLeague(s.user.leagueId!);
    await _reloadQueue();
    _notify();
    if (pending.isNotEmpty && isOnline) unawaited(syncNow());
  }

  Future<void> _saveAccounts() => tokens.write('accounts', jsonEncode([for (final a in savedAccounts) a.toJson()]));

  /// Accounts signed in before on this phone. They can be re-opened without
  /// the network, so offline actions can be recorded as different roles.
  List<Session> savedAccounts = const [];

  Future<void> continueAs(Session saved) => _activate(saved);

  /// Leaves the account. [forget] also removes it from this phone's saved accounts.
  Future<void> logout({String? notice, bool forget = false}) async {
    final email = session?.user.email;
    session = null;
    api.token = null;
    sessionNotice = notice;
    cart.clear();
    pending = const [];
    log = const [];
    await tokens.delete('session');
    if (forget && email != null) {
      savedAccounts = savedAccounts.where((a) => a.user.email != email).toList();
      await _saveAccounts();
    }
    _notify();
  }

  void _handleUnauthorized() {
    if (session == null) return;
    unawaited(logout(notice: friendlyByCode['UNAUTHENTICATED'], forget: true));
  }

  Future<void> selectLeague(String leagueId) async {
    selectedLeagueId = leagueId;
    await store.setSetting('league_id', leagueId);
    _notify();
  }

  void rememberTeamName(String id, String name) {
    if (id.isEmpty || name.isEmpty || teamNames[id] == name) return;
    teamNames[id] = name;
    unawaited(store.setSetting('team_names', jsonEncode(teamNames)));
  }

  String teamName(String? id) {
    if (id == null || id.isEmpty) return 'TBD';
    return teamNames[id] ?? humanize(id);
  }

  // ------------------------------------------------------------ connectivity

  void _setReachable(bool reachable) {
    if (serverReachable == reachable) return;
    serverReachable = reachable;
    _notify();
    if (reachable && hasNetwork && pending.isNotEmpty) {
      scheduleMicrotask(() => syncNow());
    }
  }

  void _onNetworkChanged(bool has) {
    final regained = has && !hasNetwork;
    hasNetwork = has;
    _notify();
    if (regained) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (_disposed) return;
        if (pending.isNotEmpty && session != null) {
          syncNow();
        } else {
          _ping();
        }
      });
    }
  }

  void _tick() {
    if (_disposed || !hasNetwork || syncing) return;
    if (pending.isNotEmpty && session != null) {
      syncNow();
    } else if (!serverReachable) {
      _ping();
    }
  }

  Future<void> _ping() async {
    try {
      await api.get('/api/v1/ping');
    } on ApiException {
      // Reachability already updated by the client.
    }
  }

  /// Test hook to flip connectivity.
  void debugSetNetwork(bool has) => _onNetworkChanged(has);

  // ------------------------------------------------------------------ data

  /// GET with SQLite cache: fresh data when online, saved data otherwise.
  Future<Loaded> load(String path) async {
    if (!hasNetwork) return _fromCacheOr(path, null);
    try {
      final data = await api.get(path);
      await store.putCache(path, data);
      return Loaded(data, savedAt: DateTime.now());
    } on ApiException catch (e) {
      if (e.isNetwork || (e.status ?? 0) >= 500) return _fromCacheOr(path, e);
      rethrow;
    }
  }

  Future<Loaded> _fromCacheOr(String path, ApiException? error) async {
    final cached = await store.getCache(path);
    if (cached != null) return Loaded(cached.data, fromCache: true, savedAt: cached.savedAt);
    if (error != null && !error.isNetwork) throw error;
    throw const ApiException(
      'You are offline and this screen has not been saved on this phone yet. '
      'Open it once while online to keep a copy.',
      isNetwork: true,
    );
  }

  Future<dynamic> cached(String path) async => (await store.getCache(path))?.data;

  final Set<String> _prefetched = {};

  /// Quietly saves a few screens (e.g. match details) for offline use.
  void prefetch(Iterable<String> paths, {int limit = 10}) {
    if (!isOnline) return;
    final todo = paths.where(_prefetched.add).take(limit).toList();
    if (todo.isEmpty) return;
    () async {
      for (final p in todo) {
        try {
          await load(p);
        } on ApiException catch (e) {
          if (e.isNetwork) return;
        }
      }
    }();
  }

  // ---------------------------------------------------------------- actions

  /// base_version for a score_event: the match "version" last seen.
  Future<int> matchBaseVersion(String matchId) async =>
      asInt(asMap(await cached('/api/v1/matches/$matchId'))['version']);

  /// base_version for a roster_transfer: number of history entries last seen.
  Future<int> playerBaseVersion(String playerId) async =>
      historyLength(await cached('/api/v1/roster/players/$playerId/history'));

  static int historyLength(dynamic history) {
    if (history is List) return history.length;
    if (history is Map) return asList(history['history']).length;
    return 0;
  }

  Future<SubmitOutcome> submitMatchEvent({
    required String matchId,
    required Map<String, dynamic> body,
    required String label,
  }) async {
    return _sendOrQueue(
      type: ActionTypes.scoreEvent,
      path: '/api/v1/matches/$matchId/events',
      body: body,
      baseVersion: await matchBaseVersion(matchId),
      label: label,
    );
  }

  Future<SubmitOutcome> submitRosterAction({required Map<String, dynamic> body, required String label}) async {
    return _sendOrQueue(
      type: ActionTypes.rosterTransfer,
      path: '/api/v1/roster/transfer',
      body: body,
      baseVersion: await playerBaseVersion(asStr(body['player_id'])),
      label: label,
    );
  }

  Future<SubmitOutcome> _sendOrQueue({
    required String type,
    required String path,
    required Map<String, dynamic> body,
    required int baseVersion,
    required String label,
  }) async {
    Future<SubmitOutcome> enqueue() async {
      await queueAction(
        PendingAction(
          actionId: newId(),
          type: type,
          queuedAt: isoUtc(DateTime.now()),
          baseVersion: baseVersion,
          payload: body,
          label: label,
          owner: user?.userId ?? '',
        ),
      );
      return const SubmitOutcome(SubmitStatus.queued);
    }

    if (!isOnline) return enqueue();
    try {
      return SubmitOutcome(SubmitStatus.sent, await api.post(path, body));
    } on ApiException catch (e) {
      if (e.isNetwork) return enqueue();
      rethrow;
    }
  }

  Future<void> queueAction(PendingAction action) async {
    await store.enqueue(action);
    await _reloadQueue();
    _notify();
  }

  /// The signed-in account's own queue and results. Other accounts' actions stay stored on the
  /// phone untouched until that account signs in again (and syncs them with its own token).
  Future<void> _reloadQueue() async {
    final me = user?.userId;
    pending = me == null ? const [] : [for (final a in await store.pendingActions()) if (a.owner == me) a];
    log = me == null ? const [] : [for (final e in await store.syncLog()) if (e.owner == me) e];
  }

  List<PendingAction> pendingFor(String type, String targetId) => [
    for (final a in pending)
      if (a.type == type && a.targetId == targetId) a,
  ];

  static String resultMessage(Map<String, dynamic> r) {
    final status = asStr(r['status']);
    final resolution = asStr(r['resolution']);
    switch (status) {
      case 'applied':
        return resolution == 'rebased_append'
            ? 'Applied. Others had changed this in the meantime, so your action was added after their changes.'
            : 'Applied. Saved on the server.';
      case 'duplicate':
        return 'Already on the server, so nothing changed.';
      case 'rejected':
        final code = r['error_code'] as String?;
        return 'Rejected (server version kept): ${friendlyMessage(code: code)}';
      default:
        return 'The server gave an unexpected answer for this action.';
    }
  }

  /// Sends the whole queue to POST /api/v1/sync (5.14), logs per-action
  /// results and removes every action the server answered for.
  Future<SyncSummary?> syncNow({bool announce = true}) async {
    if (syncing || session == null) return null;
    await _reloadQueue();
    final actions = pending;
    if (actions.isEmpty) {
      pending = const [];
      _notify();
      return const SyncSummary(0, 0, 0);
    }
    syncing = true;
    lastSyncError = null;
    _notify();
    var applied = 0, rejected = 0, duplicate = 0;
    SyncSummary? summary;
    try {
      for (var i = 0; i < actions.length; i += 100) {
        final chunk = actions.sublist(i, i + 100 > actions.length ? actions.length : i + 100);
        final res = asMap(await api.post('/api/v1/sync', buildSyncRequest(deviceId, chunk)));
        final byId = {for (final a in chunk) a.actionId: a};
        final entries = <SyncLogEntry>[];
        final done = <String>[];
        final now = isoUtc(DateTime.now());
        for (final raw in asList(res['results'])) {
          final r = asMap(raw);
          final action = byId[asStr(r['action_id'])];
          if (action == null) continue;
          final status = asStr(r['status']);
          if (status == 'applied') applied++;
          if (status == 'rejected') rejected++;
          if (status == 'duplicate') duplicate++;
          done.add(action.actionId);
          entries.add(
            SyncLogEntry(
              actionId: action.actionId,
              label: action.label,
              status: status,
              resolution: r['resolution'] as String?,
              errorCode: r['error_code'] as String?,
              message: resultMessage(r),
              at: now,
              owner: action.owner,
            ),
          );
        }
        await store.addSyncLog(entries);
        await store.removeActions(done);
      }
      lastSyncAt = DateTime.now();
      summary = SyncSummary(applied, rejected, duplicate);
      if (announce) _messages.add(summary.text);
    } on ApiException catch (e) {
      lastSyncError = e.isNetwork
          ? 'Could not reach the server. Your actions are kept on this phone and will be sent automatically.'
          : 'Sync did not finish: ${e.message} Your actions are kept on this phone.';
    } finally {
      syncing = false;
      await _reloadQueue();
      _notify();
    }
    return summary;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _netSub?.cancel();
    _messages.close();
    cart.dispose();
    super.dispose();
  }
}

/// Gives every widget below it access to [AppState].
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Null outside the app shell (e.g. a widget test pumping one page).
  static AppState? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;
}
