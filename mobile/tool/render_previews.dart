// Run with: flutter test tool/render_previews.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:league_app/core/app_state.dart';
import 'package:league_app/core/local_store.dart';
import 'package:league_app/presentation/clubline_app.dart';

import '../test/fake_backend.dart';

void main() {
  testWidgets('render onboarding and login screens for visual review', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final loader = FontLoader('Inter');
    for (final weight in [400, 500, 600, 700, 800]) {
      loader.addFont(rootBundle.load('assets/fonts/Inter-$weight.ttf'));
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final cupertino = FontLoader('packages/cupertino_icons/CupertinoIcons')
      ..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      );
    await cupertino.load();

    final state = AppState(
      store: MemoryLocalStore(),
      tokens: MemoryTokenStore(),
      httpClient: FakeBackend().client,
      probeInterval: const Duration(hours: 1),
    );
    await state.init();

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: boundaryKey, child: ClublineApp(state: state)),
    );
    await tester.pumpAndSettle();

    Future<void> snap(String name) async {
      await tester.pumpAndSettle();
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 2);
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/ui-previews').create(recursive: true);
        await File(
          'build/ui-previews/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
    }

    await snap('onboarding_1');
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await snap('onboarding_2');
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await snap('onboarding_3');
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await snap('onboarding_4');
    await tester.tap(find.byKey(const Key('onboarding-start')));
    await tester.pump();
    // Precache asset image inside runAsync so flutter_test decodes the PNG bitmap for toImage()
    final ctx = tester.element(find.byType(MaterialApp));
    await tester.runAsync(() async {
      await precacheImage(const AssetImage('assets/images/login_sports_hero.png'), ctx);
    });
    await tester.pumpAndSettle();
    await snap('login');

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
