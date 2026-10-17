import 'dart:ui' show ImageFilter;
import 'package:flutter/cupertino.dart'
    show CupertinoAlertDialog, CupertinoDialogAction, showCupertinoDialog;
import 'package:flutter/material.dart';

import '../toolkit/02_ui_elements/app_chip.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/models.dart';
import 'club_screens.dart' show plainError;
import 'ocean_widgets.dart';
import 'sport_screens.dart';

const _amber = Color(0xFF92621C);
const _danger = Color(0xFFB3261E);

/// The five seeded demo accounts (password is the same for all).
const demoAccounts = <(String, String)>[
  ('Admin', 'admin@nascon.test'),
  ('Organizer', 'organizer@nascon.test'),
  ('Manager', 'manager@nascon.test'),
  ('Player', 'player@nascon.test'),
  ('Viewer', 'viewer@nascon.test'),
];
const demoPassword = 'Nascon@26';

Color? _hexColor(String? hex) {
  if (hex == null) return null;
  final h = hex.replaceAll('#', '').trim();
  if (h.length != 6 && h.length != 8) return null;
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? null : Color(v);
}

/// Dialog to view, test and save the server address.
Future<void> showServerDialog(BuildContext context, AppState state) async {
  final ctrl = TextEditingController(text: state.baseUrl);
  String? status;
  bool busy = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Server address'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'http://10.0.2.2:8080',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Emulator: http://10.0.2.2:8080 · Phone on Wi-Fi: http://<laptop IP>:8080',
                style: TextStyle(fontSize: 11, color: muted),
              ),
              if (busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (status != null) ...[
                const SizedBox(height: 12),
                Text(status!, style: const TextStyle(color: ink)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    setLocal(() => busy = true);
                    final r = await state.testConnection(ctrl.text.trim());
                    setLocal(() {
                      busy = false;
                      status = r;
                    });
                  },
            child: const Text('Test'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await state.setBaseUrl(ctrl.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  ctrl.dispose();
}

// ================================================================== Profile

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, required this.state});
  final AppState state;

  Future<void> _logout(BuildContext context) async {
    final pending = state.pending.length;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Log out?'),
        content: Text(
          pending == 0
              ? 'You can sign in again at any time.'
              : 'You have $pending change${pending == 1 ? '' : 's'} waiting to sync. '
                    'They stay on this phone and will be sent after you sign in again.',
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (ok == true) await state.logout();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final user = state.user;
    final tenant = state.tenant;
    final primary = _hexColor(tenant?.primaryColor);
    final secondary = _hexColor(tenant?.secondaryColor);
    final n = state.pending.length;
    return OceanPage(
      title: 'Profile',
      subtitle: (tenant?.name ?? 'ALPHA SPORTS LEAGUE').toUpperCase(),
      children: [
        GlassCard(
          child: Column(
            children: [
              Crest(user?.name ?? 'Guest', size: 72, color: primary ?? ocean),
              const SizedBox(height: 14),
              Text(
                user?.name ?? 'Not signed in',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (user != null && user.displayName != null) ...[
                const SizedBox(height: 6),
                Text(
                  user.email,
                  style: const TextStyle(fontFamily: 'Inter', color: muted),
                ),
              ],
              const SizedBox(height: 12),
              if (user != null) Tag(Roles.label(user.role)),
              const Divider(),
              DetailRow('Organisation', tenant?.name ?? humanize(user?.tenantId)),
              if (user?.clubId != null)
                DetailRow('Club', state.teamName(user!.clubId)),
              if (user?.leagueId != null)
                DetailRow('League', humanize(user!.leagueId)),
              if (user?.playerId != null)
                DetailRow('Player ID', user!.playerId!),
              if (primary != null || secondary != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'League colours',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            color: muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      for (final c in [primary, secondary])
                        if (c != null)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  state.isOnline ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                  color: ocean,
                ),
                title: const Text('Sync status'),
                subtitle: Text(
                  n == 0
                      ? (state.isOnline ? 'Online · nothing waiting' : 'Offline · nothing waiting')
                      : '$n change${n == 1 ? '' : 's'} waiting to sync',
                ),

                onTap: () => openPage(context, SyncPage(state: state)),
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('open-sports'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.sports, color: ocean),
                title: const Text('Sports'),
                subtitle: Text(canAddSport(state) ? 'View and add sports (no code change)' : 'Sports in this platform'),
                onTap: () => openPage(context, SportsPage(state: state)),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined, color: ocean),
                title: const Text('Server address'),
                subtitle: Text(
                  state.baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => showServerDialog(context, state),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout, color: _danger),
                title: const Text('Log out'),
                onTap: () => _logout(context),
              ),
            ],
          ),
        ),
        const Text(
          'CLUBLINE\nYour league. Your club. Your game.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            color: ink,
            height: 1.8,
            letterSpacing: .7,
          ),
        ),
      ],
    );
  }
}

// ================================================================== Sign in

class SignInPage extends StatefulWidget {
  const SignInPage({super.key, required this.state});
  final AppState state;
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final form = GlobalKey<FormState>();
  // Remember the last account used on this phone.
  late final email = TextEditingController(
    text: widget.state.savedAccounts.isEmpty ? '' : widget.state.savedAccounts.first.user.email,
  );
  final password = TextEditingController();
  bool obscure = true;
  bool busy = false;
  String? error;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.state.login(email.text.trim(), password.text);
      if (!mounted) return;
      setState(() => busy = false);
      if (Navigator.canPop(context)) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        busy = false;
        error = plainError(e);
      });
    }
  }

  Future<void> _continueAs(Session s) async {
    setState(() => busy = true);
    await widget.state.continueAs(s);
    if (!mounted) return;
    setState(() => busy = false);
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final saved = widget.state.savedAccounts;
    final notice = widget.state.sessionNotice;
    return OceanPage(
      title: 'Welcome back',
      subtitle: 'CLUBLINE',
      actions: [
        IconButton(
          tooltip: 'Server address',
          onPressed: () => showServerDialog(context, widget.state),
          icon: const Icon(Icons.dns_outlined, color: Colors.white),
        ),
      ],
      children: [
        const SportGlassCards(),
        const SizedBox(height: 8),
        if (notice != null)
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: _amber),
                const SizedBox(width: 10),
                Expanded(child: Text(notice)),
              ],
            ),
          ),
        GlassCard(
          child: Form(
            key: form,
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeading('Sign in to your club'),
                  const Text(
                    'Fixtures, squads and matchday essentials.',
                    style: TextStyle(fontFamily: 'Inter', color: muted),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Demo accounts',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: muted),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final (label, mail) in demoAccounts)
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Center(
                            widthFactor: 1,
                            child: Semantics(
                              button: true,
                              label: 'Fill in $label demo account',
                              child: AppChip(
                                label: label,
                                selected: email.text == mail,
                                onTap: () => setState(() {
                                  email.text = mail;
                                  password.text = demoPassword;
                                  error = null;
                                }),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    key: const Key('signin-email'),
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      labelText: 'Email address',
                      prefixIcon: Icon(Icons.mail_outline),
                    ),
                    validator: (v) =>
                        v != null &&
                            RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())
                        ? null
                        : 'Enter a valid email address.',
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('signin-password'),
                    controller: password,
                    obscureText: obscure,
                    autofillHints: const [AutofillHints.password],
                    onFieldSubmitted: (_) => busy ? null : _signIn(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: obscure ? 'Show password' : 'Hide password',
                        onPressed: () => setState(() => obscure = !obscure),
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: (v) =>
                        (v ?? '').isNotEmpty ? null : 'Enter your password.',
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        error!,
                        style: const TextStyle(fontFamily: 'Inter', color: _danger),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const Key('signin-submit'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: busy ? null : _signIn,
                    child: busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Sign in →'),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => showServerDialog(context, widget.state),
                    icon: const Icon(Icons.dns_outlined, size: 18),
                    label: Text(
                      'Server: ${widget.state.baseUrl}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (saved.isNotEmpty)
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: SectionHeading('Continue as'),
                ),
                const Text(
                  'Accounts used on this phone. Works offline too.',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: muted),
                ),
                for (final s in saved)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Crest(s.user.name, size: 36),
                    title: Text(s.user.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(Roles.label(s.user.role)),

                    onTap: busy ? null : () => _continueAs(s),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ===================================================================== Sync

class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.state});
  final AppState state;
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  Future<void> _sync() async {
    final s = widget.state;
    if (s.session == null) {
      notice(context, 'Sign in first so your changes can be sent.');
      return;
    }
    final summary = await s.syncNow();
    if (!mounted) return;
    if (summary == null && s.lastSyncError != null) {
      notice(context, s.lastSyncError!);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final s = widget.state;
    final pending = s.pending;
    final log = s.log;
    final (icon, title) = switch (s.status) {
      NetStatus.syncing => (Icons.cloud_sync_outlined, 'Syncing…'),
      NetStatus.online => (Icons.cloud_done_outlined, 'Online'),
      NetStatus.offline => (Icons.cloud_off_outlined, 'Offline'),
    };
    return OceanPage(
      title: 'Sync status',
      children: [
        GlassCard(
          child: Column(
            children: [
              Icon(icon, size: 52, color: ocean),
              const SizedBox(height: 14),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                pending.isEmpty
                    ? 'Nothing waiting to sync'
                    : '${pending.length} change${pending.length == 1 ? '' : 's'} saved on this phone, waiting to be sent.',
                textAlign: TextAlign.center,
              ),
              if (s.lastSyncAt != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Last sync ${formatSavedAgo(s.lastSyncAt)}',
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: muted),
                ),
              ],
              if (s.lastSyncError != null) ...[
                const SizedBox(height: 10),
                Text(
                  s.lastSyncError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: _danger),
                ),
              ],
            ],
          ),
        ),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeading(
                'Waiting to sync',
                trailing: Tag('${pending.length}', color: pending.isEmpty ? green : _amber),
              ),
              if (pending.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Nothing waiting to sync', textAlign: TextAlign.center),
                ),
              for (final a in pending)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    a.type == ActionTypes.rosterTransfer
                        ? Icons.swap_horiz
                        : Icons.sports_score,
                    color: ocean,
                  ),
                  title: Text(a.label.isEmpty ? humanize(a.type) : a.label),
                  subtitle: Text(
                    '${a.type == ActionTypes.rosterTransfer ? 'Roster change' : 'Score update'}'
                    ' · saved ${formatDateTime(a.queuedAt)}',
                  ),
                  trailing: const Tag('Pending', color: _amber),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('sync-now'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: s.syncing || pending.isEmpty ? null : _sync,
                icon: s.syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(s.syncing ? 'Syncing…' : 'Sync now'),
              ),
            ],
          ),
        ),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeading('Last results'),
              if (log.isEmpty)
                const Text('No changes have been synced yet.'),
              for (final e in log)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    e.status == 'rejected'
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    color: e.status == 'rejected' ? _danger : green,
                  ),
                  title: Text(e.label.isEmpty ? 'Change' : e.label),
                  subtitle: Text('${e.message}\n${formatDateTime(e.at)}'),
                  trailing: Tag(
                    switch (e.status) {
                      'applied' => 'Applied',
                      'rejected' => 'Rejected',
                      'duplicate' => 'Already saved',
                      _ => humanize(e.status),
                    },
                    color: e.status == 'rejected' ? _danger : green,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}


/// Sign-in hero: four frosted-glass sport cards (football, esports, basketball,
/// cricket) in the brand palette — the four seeded scoring models at a glance.
class SportGlassCards extends StatelessWidget {
  const SportGlassCards({super.key});

  static const _cards = [
    (Icons.sports_soccer, 'Football', Color(0xFFD6ECF5), Color(0xFF0B3C5D)),
    (Icons.sports_esports, 'Esports', Color(0xFF2E8BC9), Colors.white),
    (Icons.sports_basketball, 'Basketball', Color(0xFF1B4965), Colors.white),
    (Icons.sports_cricket, 'Cricket', Color(0xFFB9A7DB), Colors.white),
  ];

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Supported sports: football, esports, basketball and cricket',
    child: ExcludeSemantics(
      child: SizedBox(
        height: 132,
        child: Row(
          children: [
            for (final (icon, label, tint, fg) in _cards)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.skewY(-0.06),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [tint.withValues(alpha: .78), tint.withValues(alpha: .48)],
                            ),
                            border: Border.all(color: Colors.white.withValues(alpha: .55), width: 1.2),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: .18), blurRadius: 18, offset: const Offset(0, 10)),
                            ],
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(icon, size: 36, color: fg),
                              const SizedBox(height: 8),
                              Text(label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
