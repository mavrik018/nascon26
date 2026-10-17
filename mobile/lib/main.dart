import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/local_store.dart';
import 'presentation/clubline_app.dart';

/// Real app: JWT session in secure storage (Android Keystore), SQLite cache +
/// durable offline queue, connectivity-driven online/offline status.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final connectivity = Connectivity();
  bool hasNetwork(List<ConnectivityResult> r) => r.any((x) => x != ConnectivityResult.none);

  final state = AppState(
    store: await SqliteLocalStore.open(),
    tokens: SecureTokenStore(),
    networkChanges: connectivity.onConnectivityChanged.map(hasNetwork),
    checkNetwork: () async => hasNetwork(await connectivity.checkConnectivity()),
  );
  runApp(ClublineApp(state: state));
  await state.init();
}
