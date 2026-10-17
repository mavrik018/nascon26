import 'dart:async';

import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_shell.dart';
import 'features/sync/sync_screen.dart';
import 'widgets/sync_banner.dart';

const _defaultSeed = Color(0xFF1E3A8A);

Color? parseHexColor(String? hex) {
  if (hex == null) return null;
  var h = hex.trim().replaceFirst('#', '');
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return (h.length == 8 && v != null) ? Color(v) : null;
}

ThemeData buildTheme(Color seed, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    appBarTheme: AppBarTheme(backgroundColor: scheme.surface, foregroundColor: scheme.onSurface, centerTitle: false),
    cardTheme: const CardThemeData(elevation: 1),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(64, 48))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48))),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(48, 48))),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

class LeagueApp extends StatefulWidget {
  const LeagueApp({super.key, required this.state});
  final AppState state;

  @override
  State<LeagueApp> createState() => _LeagueAppState();
}

class _LeagueAppState extends State<LeagueApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<String>? _messages;
  String? _lastUser;

  @override
  void initState() {
    super.initState();
    _messages = widget.state.messages.listen((m) {
      _messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    });
    widget.state.addListener(_onState);
  }

  void _onState() {
    final user = widget.state.user?.userId;
    if (user != _lastUser) {
      _lastUser = user;
      // Session changed (login/logout): drop any pushed screens.
      _navigatorKey.currentState?.popUntil((r) => r.isFirst);
    }
  }

  @override
  void dispose() {
    _messages?.cancel();
    widget.state.removeListener(_onState);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final state = widget.state;
          final seed = parseHexColor(state.tenant?.primaryColor) ?? _defaultSeed;
          return MaterialApp(
            title: state.tenant?.name ?? 'League Manager',
            debugShowCheckedModeBanner: false,
            navigatorKey: _navigatorKey,
            scaffoldMessengerKey: _messengerKey,
            theme: buildTheme(seed, Brightness.light),
            darkTheme: buildTheme(seed, Brightness.dark),
            builder: (context, child) => Column(
              children: [
                SyncBanner(
                  state: state,
                  onTap: () => _navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => const SyncScreen())),
                ),
                Expanded(
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
            home: !state.ready
                ? const Scaffold(body: Center(child: CircularProgressIndicator()))
                : state.session == null
                ? const LoginScreen()
                : HomeShell(key: ValueKey(state.user?.userId)),
          );
        },
      ),
    );
  }
}
