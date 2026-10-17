import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_state.dart';
import '../../core/format.dart';
import '../../widgets/common.dart';
import 'receipt_screen.dart';

class MockCard {
  const MockCard(this.token, this.title, this.subtitle, this.icon);
  final String token;
  final String title;
  final String subtitle;
  final IconData icon;
}

const mockCards = [
  MockCard('tok_success', 'Card OK', 'Test card that pays successfully', Icons.credit_card),
  MockCard('tok_declined', 'Card declined', 'Test card the bank refuses', Icons.credit_card_off),
  MockCard('tok_capture_fail', 'Capture fails', 'Approved, then the charge fails', Icons.report_gmailerrorred),
];

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final _discount = TextEditingController();
  String _token = 'tok_success';
  bool _busy = false;
  String? _error;

  // Re-use the order id only to retry the identical request after a network failure.
  String? _orderId;
  String? _lastBody;

  @override
  void dispose() {
    _discount.dispose();
    super.dispose();
  }

  Future<void> _pay() async {
    final state = AppScope.read(context);
    final cart = state.cart;
    if (cart.isEmpty) return;
    final ok = await confirmAction(
      context,
      title: 'Pay ${formatMoney(cart.subtotal, cart.currency)}?',
      message:
          'You are buying ${cart.count} item(s) with "${mockCards.firstWhere((c) => c.token == _token).title}". '
          '${_discount.text.trim().isEmpty ? '' : 'Discount code ${_discount.text.trim().toUpperCase()} will be applied if valid. '}'
          'This is a test payment.',
      confirmLabel: 'Pay now',
    );
    if (!ok || !mounted) return;

    final content = {
      'items': [
        for (final i in cart.items) {'variant_id': i.variantId, 'quantity': i.quantity},
      ],
      'discount_code': _discount.text.trim().isEmpty ? null : _discount.text.trim().toUpperCase(),
      'payment': {'token': _token},
    };
    final bodyKey = jsonEncode(content);
    if (_orderId == null || _lastBody != bodyKey) _orderId = newId('ord');
    _lastBody = bodyKey;
    final body = {'order_id': _orderId, ...content};
    final labels = {for (final i in cart.items) i.variantId: '${i.productName} (${i.variantLabel})'};

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = asMap(await state.api.post('/api/v1/store/checkout', body));
      final order = {...res, 'local_labels': labels};
      final saved = asList(await state.cached('local:orders')).toList();
      saved.insert(0, order);
      await state.store.putCache('local:orders', saved.take(10).toList());
      cart.clear();
      _orderId = null;
      if (!mounted) return;
      showSnack(context, 'Payment successful');
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ReceiptScreen(order: order)));
    } on ApiException catch (e) {
      if (!e.isNetwork) _orderId = null;
      if (mounted) {
        setState(() => _error = e.isNetwork ? '${e.message} Your cart is kept, try again when online.' : e.message);
        showSnack(context, e.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final cart = state.cart;
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) => Scaffold(
        appBar: leagueAppBar(context, 'Cart & checkout'),
        body: cart.isEmpty
            ? ListView(
                children: [
                  const EmptyView(
                    icon: Icons.remove_shopping_cart_outlined,
                    title: 'Your cart is empty',
                    message: 'Open the Store tab and pick an item.',
                  ),
                  Center(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Back to store'),
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  const SectionTitle('Items'),
                  for (final i in cart.items)
                    ListTile(
                      title: Text(i.productName),
                      subtitle: Text('${i.variantLabel}\n${formatMoney(i.priceMinor, i.currency)} each'),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: i.quantity == 1 ? 'Remove ${i.productName}' : 'One less',
                            icon: Icon(i.quantity == 1 ? Icons.delete_outline : Icons.remove),
                            onPressed: _busy ? null : () => cart.setQuantity(i.variantId, i.quantity - 1),
                          ),
                          Text('${i.quantity}', style: theme.textTheme.titleMedium),
                          IconButton(
                            tooltip: 'One more',
                            icon: const Icon(Icons.add),
                            onPressed: _busy || i.quantity >= i.stock.clamp(1, 10)
                                ? null
                                : () => cart.setQuantity(i.variantId, i.quantity + 1),
                          ),
                        ],
                      ),
                    ),
                  const SectionTitle('Discount code'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _discount,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Code (optional)',
                        hintText: 'e.g. WELCOME10',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.local_offer_outlined),
                      ),
                    ),
                  ),
                  const SectionTitle('Payment (test cards)'),
                  for (final c in mockCards)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Card(
                        margin: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: _token == c.token ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                            width: _token == c.token ? 2 : 1,
                          ),
                        ),
                        child: ListTile(
                          key: Key('card-${c.token}'),
                          selected: _token == c.token,
                          leading: Icon(c.icon),
                          title: Text(c.title),
                          subtitle: Text(c.subtitle),
                          trailing: Icon(
                            _token == c.token ? Icons.check_circle : Icons.circle_outlined,
                            semanticLabel: _token == c.token ? 'Selected' : 'Not selected',
                          ),
                          onTap: _busy ? null : () => setState(() => _token = c.token),
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Text('Subtotal', style: theme.textTheme.titleMedium),
                        const Spacer(),
                        Text(
                          formatMoney(cart.subtotal, cart.currency),
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Text('Any discount is calculated by the server and shown on the receipt.'),
                  ),
                  if (_error != null)
                    Card(
                      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      color: theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Semantics(
                          liveRegion: true,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: FilledButton.icon(
                      key: const Key('pay'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        textStyle: theme.textTheme.titleMedium,
                      ),
                      onPressed: _busy || !state.isOnline ? null : _pay,
                      icon: _busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.lock_outline),
                      label: Text(_busy ? 'Processing payment…' : 'Pay ${formatMoney(cart.subtotal, cart.currency)}'),
                    ),
                  ),
                  if (!state.isOnline)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text('You are offline. Checkout needs a connection. Your cart is kept.'),
                    ),
                ],
              ),
      ),
    );
  }
}
