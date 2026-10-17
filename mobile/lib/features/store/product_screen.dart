import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_state.dart';
import '../../core/format.dart';
import '../../widgets/common.dart';
import 'cart.dart';
import 'cart_screen.dart';
import 'store_screen.dart';

class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key, required this.productId, this.initial});
  final String productId;
  final Map<String, dynamic>? initial;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  Map<String, dynamic>? _product;
  String? _error;
  String? _variantId;
  int _qty = 1;

  @override
  void initState() {
    super.initState();
    _product = widget.initial;
    _pickDefault();
    if (_product == null) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final loaded = await AppScope.read(context).load(productsPath);
      final data = loaded.data;
      final list = asList(data is Map ? data['products'] : data);
      final found = list.map(asMap).where((p) => p['product_id'] == widget.productId).firstOrNull;
      if (!mounted) return;
      setState(() {
        _product = found;
        _error = found == null ? 'This product is no longer in the store.' : null;
        _pickDefault();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  List<Map<String, dynamic>> get _variants => [for (final v in asList(_product?['variants'])) asMap(v)];

  void _pickDefault() {
    if (_variantId != null) return;
    final v = _variants.where((v) => asInt(v['stock']) > 0).firstOrNull;
    _variantId = v == null ? null : asStr(v['variant_id']);
  }

  Map<String, dynamic>? get _selected => _variants.where((v) => v['variant_id'] == _variantId).firstOrNull;

  String _variantLabel(Map<String, dynamic> v) {
    final parts = [asStr(v['label']), asStr(v['size']), asStr(v['color'])].where((s) => s.isNotEmpty).toSet();
    return parts.isEmpty ? asStr(v['variant_id']) : parts.join(' · ');
  }

  bool _addToCart() {
    final v = _selected;
    if (v == null) return false;
    AppScope.read(context).cart.add(
      CartItem(
        variantId: asStr(v['variant_id']),
        productName: asStr(_product?['name'], 'Product'),
        variantLabel: _variantLabel(v),
        priceMinor: asInt(v['price_minor']),
        currency: asStr(v['currency'], 'PKR'),
        quantity: _qty,
        stock: asInt(v['stock']),
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = _product;
    return Scaffold(
      appBar: leagueAppBar(context, 'Product', actions: const [CartButton()]),
      body: product == null
          ? (_error == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: [ErrorView(message: _error!, onRetry: _load)],
                  ))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  height: 140,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    categoryIcon(asStr(product['category'])),
                    size: 80,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 16),
                Text(asStr(product['name']), style: theme.textTheme.headlineSmall),
                if (asStr(product['description']).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(asStr(product['description'])),
                ],
                const SizedBox(height: 20),
                Text('Choose an option', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                if (_variants.isEmpty) const Text('No options available.'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final v in _variants)
                      ChoiceChip(
                        key: Key('variant-${v['variant_id']}'),
                        label: Text(
                          asInt(v['stock']) > 0
                              ? '${_variantLabel(v)} – ${formatMoney(asInt(v['price_minor']), asStr(v['currency'], 'PKR'))}'
                              : '${_variantLabel(v)} – Out of stock',
                        ),
                        selected: _variantId == v['variant_id'],
                        onSelected: asInt(v['stock']) > 0
                            ? (_) => setState(() {
                                _variantId = asStr(v['variant_id']);
                                _qty = 1;
                              })
                            : null,
                      ),
                  ],
                ),
                if (_selected != null) ...[
                  const SizedBox(height: 8),
                  Text('${asInt(_selected!['stock'])} left in stock', style: theme.textTheme.bodySmall),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Text('Quantity', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    IconButton.outlined(
                      tooltip: 'One less',
                      onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                      icon: const Icon(Icons.remove),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text('$_qty', style: theme.textTheme.titleLarge),
                    ),
                    IconButton.outlined(
                      tooltip: 'One more',
                      onPressed: _selected != null && _qty < asInt(_selected!['stock']).clamp(1, 10)
                          ? () => setState(() => _qty++)
                          : null,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const Key('buy-now'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    textStyle: theme.textTheme.titleMedium,
                  ),
                  onPressed: _selected == null
                      ? null
                      : () {
                          if (_addToCart()) {
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CartScreen()));
                          }
                        },
                  icon: const Icon(Icons.shopping_bag),
                  label: Text(
                    _selected == null
                        ? 'Choose an option'
                        : 'Buy now · ${formatMoney(asInt(_selected!['price_minor']) * _qty, asStr(_selected!['currency'], 'PKR'))}',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: _selected == null
                      ? null
                      : () {
                          if (_addToCart()) showSnack(context, 'Added to cart');
                        },
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text('Add to cart'),
                ),
              ],
            ),
    );
  }
}
