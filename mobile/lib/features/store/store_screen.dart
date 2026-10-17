import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/format.dart';
import '../../widgets/common.dart';
import 'cart_screen.dart';
import 'product_screen.dart';

const productsPath = '/api/v1/store/products';

IconData categoryIcon(String category) => switch (category.toLowerCase()) {
  'jersey' || 'apparel' || 'shirt' || 'kit' => Icons.checkroom,
  'ticket' || 'tickets' => Icons.confirmation_number_outlined,
  'accessory' || 'accessories' => Icons.watch_outlined,
  _ => Icons.shopping_bag_outlined,
};

/// Cart icon with item-count badge, used in store app bars.
class CartButton extends StatelessWidget {
  const CartButton({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = AppScope.of(context).cart;
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) => IconButton(
        tooltip: cart.count == 0 ? 'Cart is empty' : 'Cart, ${cart.count} item(s)',
        icon: Badge(
          isLabelVisible: cart.count > 0,
          label: Text('${cart.count}'),
          child: const Icon(Icons.shopping_cart_outlined),
        ),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CartScreen())),
      ),
    );
  }
}

class StoreScreen extends StatelessWidget {
  const StoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: leagueAppBar(context, 'Store', actions: const [CartButton()]),
      body: CachedLoader(
        path: productsPath,
        isEmpty: (d) => asList(d is Map ? d['products'] : d).isEmpty,
        empty: const EmptyView(
          icon: Icons.storefront_outlined,
          title: 'No products yet',
          message: 'Club merchandise will appear here.',
        ),
        builder: (context, data, refresh) {
          final products = [for (final p in asList(data is Map ? data['products'] : data)) asMap(p)];
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: products.length,
            itemBuilder: (context, i) => _ProductCard(product: products[i]),
          );
        },
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product});
  final Map<String, dynamic> product;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final variants = [for (final v in asList(product['variants'])) asMap(v)];
    final prices = variants.map((v) => asInt(v['price_minor'])).toList()..sort();
    final currency = variants.isEmpty ? 'PKR' : asStr(variants.first['currency'], 'PKR');
    final inStock = variants.fold<int>(0, (s, v) => s + asInt(v['stock']));
    final name = asStr(product['name'], 'Product');
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ProductScreen(productId: asStr(product['product_id']), initial: product),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  categoryIcon(asStr(product['category'])),
                  size: 36,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: theme.textTheme.titleMedium),
                    Text(humanize(asStr(product['category'])), style: theme.textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Text(
                      prices.isEmpty ? 'Price not set' : formatMoney(prices.first, currency),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      inStock > 0 ? '${variants.length} option(s) available' : 'Sold out',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
