import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:league_app/core/app_state.dart';
import 'package:league_app/core/local_store.dart';
import 'package:league_app/presentation/ocean_widgets.dart';
import 'package:league_app/presentation/shop_screens.dart';

import 'fake_backend.dart';

final _products = [
  {
    'product_id': 'prod-1',
    'tenant_id': 'tenant-alpha',
    'name': 'Home Jersey',
    'category': 'kits',
    'description': 'Match shirt',
    'variants': [
      {'variant_id': 'var-m', 'label': 'M / Navy', 'size': 'M', 'color': 'navy', 'price_minor': 450000, 'currency': 'PKR', 'stock': 3},
      {'variant_id': 'var-xl', 'label': 'XL / Navy', 'size': 'XL', 'color': 'navy', 'price_minor': 450000, 'currency': 'PKR', 'stock': 0},
    ],
  },
];

Map<String, dynamic> _order(Map<String, dynamic> body) => {
  'order_id': body['order_id'],
  'status': 'paid',
  'currency': 'PKR',
  'items': [
    {'variant_id': 'var-m', 'quantity': 1, 'unit_price_minor': 450000},
  ],
  'subtotal_minor': 450000,
  'discount_minor': 0,
  'total_minor': 450000,
  'payment': {'authorization_id': 'auth-1', 'capture_id': 'cap-1', 'state': 'captured'},
  'receipt': {
    'payload': {'order_id': body['order_id'], 'paid_at': '2026-10-17T09:00:00Z'},
    'signature': 'abcdef0123456789abcdef',
    'pdf_base64': base64Encode(utf8.encode('%PDF-1.4')),
  },
};

Future<AppState> _pump(WidgetTester tester, FakeBackend backend) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState(
    store: MemoryLocalStore(),
    tokens: MemoryTokenStore(),
    httpClient: backend.client,
    checkNetwork: () async => true,
    probeInterval: const Duration(hours: 1),
  );
  await state.init();
  await tester.pumpWidget(MaterialApp(theme: oceanTheme(), home: ShopPage(state: state)));
  await tester.pumpAndSettle();
  return state;
}

Future<void> _addJerseyAndCheckout(WidgetTester tester, AppState state) async {
  await tester.ensureVisible(find.text('Home Jersey'));
  await tester.pumpAndSettle();
  await tester.pumpAndSettle();
  await tester.tap(find.text('Home Jersey'));
  await tester.pumpAndSettle();
  expect(find.text('Only 3 left'), findsOneWidget);
  await tester.ensureVisible(find.byKey(const Key('add-to-cart')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('add-to-cart')));
  await tester.pumpAndSettle();
  expect(state.cart.count, 1);
  await tester.tap(find.text('View cart'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const Key('to-checkout')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('to-checkout')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('declined card shows plain message and keeps the cart', (tester) async {
    final backend = FakeBackend();
    final bodies = <Map<String, dynamic>>[];
    backend.overrides['/api/v1/store/products'] = (_) => FakeBackend.json(_products, 200);
    backend.overrides['/api/v1/store/checkout'] = (r) {
      bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
      return FakeBackend.error(402, 'PAYMENT_DECLINED', 'declined');
    };
    final state = await _pump(tester, backend);
    await _addJerseyAndCheckout(tester, state);

    await tester.tap(find.byKey(const Key('card-tok_declined')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('pay')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pay')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Your card was declined. No money was taken.'), findsOneWidget);
    expect(state.cart.count, 1);
    expect(bodies.single['payment'], {'token': 'tok_declined'});
    expect(bodies.single['items'], [
      {'variant_id': 'var-m', 'quantity': 1},
    ]);
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(bodies.single['order_id'] as String), isTrue); // UUID v4
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('successful payment clears the cart and shows a verified receipt', (tester) async {
    final backend = FakeBackend();
    backend.overrides['/api/v1/store/products'] = (_) => FakeBackend.json(_products, 200);
    backend.overrides['/api/v1/store/checkout'] = (r) =>
        FakeBackend.json(_order(jsonDecode(r.body) as Map<String, dynamic>), 201);
    final state = await _pump(tester, backend);
    await _addJerseyAndCheckout(tester, state);

    await tester.ensureVisible(find.byKey(const Key('pay')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pay')));
    await tester.pumpAndSettle();

    expect(state.cart.count, 0);
    expect(find.text('Order receipt'), findsOneWidget);
    expect(find.text('PAID'), findsOneWidget);
    expect(find.text('Verified receipt · abcdef012345'), findsOneWidget);
    expect(find.text('Home Jersey · M / Navy × 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
