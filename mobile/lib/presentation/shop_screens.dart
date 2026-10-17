import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../toolkit/02_ui_elements/pressable.dart';
import '../toolkit/02_ui_elements/search_field.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../core/app_state.dart';
import '../core/format.dart';
import '../features/store/cart.dart';
import 'ocean_widgets.dart';
import 'sample_data.dart' show money;

const _productsPath = '/api/v1/store/products';
const _checkoutPath = '/api/v1/store/checkout';
const _maxPerLine = 10;
const _red = Color(0xFFBE3450);
const _amber = Color(0xFF8A5A00);

String _price(int minor, [String currency = 'PKR']) =>
    currency == 'PKR' ? money(minor) : formatMoney(minor, currency);

// ------------------------------------------------------------- view models

/// One purchasable option of a product (size / colour) from the store API.
class StoreVariant {
  const StoreVariant({
    required this.id,
    required this.label,
    required this.size,
    required this.color,
    required this.priceMinor,
    required this.currency,
    required this.stock,
  });

  factory StoreVariant.fromJson(Map<String, dynamic> j) {
    final size = asStr(j['size']);
    final color = asStr(j['color']);
    var label = asStr(j['label']);
    if (label.isEmpty) {
      label = [size, color].where((s) => s.isNotEmpty).join(' · ');
    }
    return StoreVariant(
      id: asStr(j['variant_id']),
      label: label.isEmpty ? 'Standard' : label,
      size: size,
      color: color,
      priceMinor: asInt(j['price_minor']),
      currency: asStr(j['currency'], 'PKR'),
      stock: asInt(j['stock']),
    );
  }

  final String id, label, size, color, currency;
  final int priceMinor, stock;
  bool get soldOut => stock <= 0;
}

/// A store product built from GET /api/v1/store/products JSON.
class StoreProduct {
  const StoreProduct({
    required this.id,
    required this.name,
    required this.category,
    required this.description,
    required this.variants,
  });

  factory StoreProduct.fromJson(Map<String, dynamic> j) => StoreProduct(
    id: asStr(j['product_id']),
    name: asStr(j['name'], 'Club item'),
    category: humanize(asStr(j['category'], 'Other')),
    description: asStr(j['description']),
    variants: [for (final v in asList(j['variants'])) StoreVariant.fromJson(asMap(v))],
  );

  final String id, name, category, description;
  final List<StoreVariant> variants;

  int get fromPrice =>
      variants.isEmpty ? 0 : variants.map((v) => v.priceMinor).reduce((a, b) => a < b ? a : b);
  String get currency => variants.isEmpty ? 'PKR' : variants.first.currency;
  int get totalStock => variants.fold(0, (s, v) => s + (v.stock > 0 ? v.stock : 0));
  bool get soldOut => totalStock == 0;
  bool get isBag => _looksLikeBag('$category $name');
  Color get color => productColor(variants.isEmpty ? '' : variants.first.color, name);
}

bool _looksLikeBag(String text) {
  final c = text.toLowerCase();
  return c.contains('access') || c.contains('bag') || c.contains('scarf') || c.contains('ball');
}

List<StoreProduct> parseProducts(dynamic data) {
  final raw = data is Map ? asList(data['products'] ?? data['items']) : asList(data);
  return [for (final p in raw) StoreProduct.fromJson(asMap(p))];
}

const _named = <String, Color>{
  'navy': Color(0xFF143A51),
  'blue': Color(0xFF006D9F),
  'sky': Color(0xFF4FA3D1),
  'white': Color(0xFFCBD9E3),
  'black': Color(0xFF1F2933),
  'red': Color(0xFFBE3450),
  'green': Color(0xFF087453),
  'yellow': Color(0xFFE0A526),
  'gold': Color(0xFFC9962B),
  'orange': Color(0xFFD9732B),
  'grey': Color(0xFF7B8794),
  'gray': Color(0xFF7B8794),
  'teal': Color(0xFF37798B),
  'purple': Color(0xFF6B4FA0),
};

const _palette = [
  Color(0xFF006D9F),
  Color(0xFF143A51),
  Color(0xFF37798B),
  Color(0xFFA86C2E),
  Color(0xFF087453),
  Color(0xFF6B4FA0),
];

/// Kit colour from the variant's colour name or hex, else a stable hash.
Color productColor(String colorText, String fallbackKey) {
  final c = colorText.trim().toLowerCase();
  final hex = RegExp(r'#?([0-9a-f]{6})\b').firstMatch(c);
  if (hex != null) return Color(int.parse('ff${hex.group(1)}', radix: 16));
  for (final e in _named.entries) {
    if (c.contains(e.key)) return e.value;
  }
  var h = 0;
  for (final unit in fallbackKey.codeUnits) {
    h = (h * 31 + unit) & 0x7fffffff;
  }
  return _palette[h % _palette.length];
}

/// Discount code typed on the cart page, kept per cart while navigating.
final Expando<String> _discountCodes = Expando<String>('discount');

String? _codeFor(Cart cart) {
  final c = _discountCodes[cart]?.trim();
  return (c == null || c.isEmpty) ? null : c;
}

/// Client-side preview only; the server decides the real discount.
int _previewDiscount(Cart cart) =>
    _codeFor(cart)?.toUpperCase() == 'WELCOME10' ? cart.subtotal * 10 ~/ 100 : 0;

Widget _cartButton(BuildContext context, AppState state) {
  final count = state.cart.count;
  return IconButton(
    tooltip: count == 0 ? 'Shopping cart, empty' : 'Shopping cart, $count items',
    onPressed: () => openPage(context, CartPage(state: state)),
    icon: Badge(
      isLabelVisible: count > 0,
      label: Text('$count'),
      child: const Icon(Icons.shopping_bag_outlined, color: Colors.white),
    ),
  );
}

// ------------------------------------------------------------------- shop

class ShopPage extends StatefulWidget {
  const ShopPage({super.key, required this.state});
  final AppState state;
  @override
  State<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<ShopPage> {
  String category = 'All', query = '';
  bool loading = true;
  String? error;
  Loaded? loaded;
  List<StoreProduct> products = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.state.load(_productsPath);
      if (!mounted) return;
      setState(() {
        loaded = result;
        products = parseProducts(result.data);
        loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.message;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        error = 'The store could not be loaded. Please try again.';
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.state, widget.state.cart]),
    builder: (context, _) => RefreshIndicator(onRefresh: _load, child: _page(context)),
  );

  Widget _page(BuildContext context) {
    final categories = ['All', ...{for (final p in products) p.category}];
    if (!categories.contains(category)) category = 'All';
    final shown = products
        .where(
          (p) =>
              (category == 'All' || p.category == category) &&
              p.name.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    final featured = products.where((p) => !p.soldOut).firstOrNull ?? products.firstOrNull;
    return OceanPage(
      title: 'Club store',
      actions: [
        IconButton(
          tooltip: 'Refresh products',
          onPressed: loading ? null : _load,
          icon: const Icon(Icons.refresh, color: Colors.white),
        ),
        _cartButton(context, widget.state),
      ],
      children: [
        GlassCard(
          opacity: .25,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'WEAR YOUR PRIDE',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 9,
                        color: Colors.white,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Made for\nmatchday.',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.05,
                      ),
                    ),
                    if (featured != null) ...[
                      const SizedBox(height: 14),
                      FilledButton(
                        onPressed: () => openPage(
                          context,
                          ProductPage(product: featured, state: widget.state),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: ocean,
                        ),
                        child: const Text('Explore the kit →'),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                height: 150,
                child: featured == null ? const ProductArt(color: ocean) : ProductArt.of(featured),
              ),
            ],
          ),
        ),
        if (loaded?.fromCache == true)
          _InlineMessage(
            icon: Icons.cloud_off_outlined,
            text:
                'You are offline. Showing the store saved ${formatSavedAgo(loaded!.savedAt)}. '
                'Prices and stock may have changed.',
            color: _amber,
            filled: true,
          ),
        SearchField(
          hintText: 'Search club merchandise',
          onChanged: (v) => setState(() => query = v),
        ),
        if (categories.length > 2)
          ChoiceRow(
            items: categories,
            value: category,
            light: true,
            onChanged: (v) => setState(() => category = v),
          ),
        if (loading && products.isEmpty)
          const GlassCard(
            child: Row(
              children: [
                SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                SizedBox(width: 16),
                Expanded(child: Text('Loading the club store…')),
              ],
            ),
          )
        else if (error != null && products.isEmpty)
          _ErrorCard(message: error!, onRetry: _load)
        else if (products.isEmpty)
          const EmptyCard('No products yet', 'The club store has nothing for sale right now.')
        else if (shown.isEmpty)
          const EmptyCard('No matching products', 'Try a different search or category.')
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns =
                  constraints.maxWidth < 300 || MediaQuery.textScalerOf(context).scale(1) > 1.3 ? 1 : 2;
              final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final p in shown)
                    SizedBox(
                      width: width,
                      child: _ProductCard(
                        product: p,
                        onTap: () => openPage(context, ProductPage(product: p, state: widget.state)),
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product, required this.onTap});
  final StoreProduct product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final priceText = p.variants.map((v) => v.priceMinor).toSet().length > 1
        ? 'From ${_price(p.fromPrice, p.currency)}'
        : _price(p.fromPrice, p.currency);
    return Pressable(
      onTap: onTap,
      semanticLabel: 'View ${p.name}, $priceText${p.soldOut ? ', sold out' : ''}',
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(aspectRatio: 1, child: ProductArt.of(p)),
            const SizedBox(height: 12),
            Text(
              p.category.toUpperCase(),
              style: const TextStyle(fontFamily: 'Inter', fontSize: 9, letterSpacing: 1, color: muted),
            ),
            const SizedBox(height: 4),
            Text(
              p.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(
              priceText,
              style: const TextStyle(fontFamily: 'Inter', color: ocean, fontWeight: FontWeight.w800),
            ),
            if (p.soldOut) ...[const SizedBox(height: 6), const Tag('SOLD OUT', color: _red)],
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => GlassCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.wifi_off_outlined, size: 40, color: ocean),
        const SizedBox(height: 12),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      ],
    ),
  );
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage({required this.icon, required this.text, required this.color, this.filled = false});
  final IconData icon;
  final String text;
  final Color color;
  final bool filled;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: filled ? Colors.white.withValues(alpha: .9) : color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: color, height: 1.4)),
          ),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------- artwork

/// Local illustration: merchandise artwork is not a store_products field.
class ProductArt extends StatelessWidget {
  const ProductArt({super.key, required this.color, this.bag = false});

  ProductArt.of(StoreProduct product, {super.key, StoreVariant? variant})
    : color = variant == null ? product.color : productColor(variant.color, product.name),
      bag = product.isBag;

  final Color color;
  final bool bag;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [Color(0xFFEFF8FC), Color(0xFFBBD6E6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, c) => Center(
          child: SizedBox(
            width: c.maxWidth * .8,
            height: c.maxHeight * .8,
            child: CustomPaint(painter: _KitPainter(color, bag)),
          ),
        ),
      ),
    ),
  );
}

class _KitPainter extends CustomPainter {
  _KitPainter(this.color, this.bag);
  final Color color;
  final bool bag;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    if (bag) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(10, 30, 80, 53), const Radius.circular(10)),
        Paint()..color = color,
      );
      canvas.drawArc(
        const Rect.fromLTWH(32, 14, 36, 43),
        3.14,
        3.14,
        false,
        Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
      canvas.drawLine(
        const Offset(15, 41),
        const Offset(85, 41),
        Paint()
          ..color = Colors.white54
          ..strokeWidth = 1,
      );
    } else {
      final path = Path()
        ..moveTo(30, 12)
        ..lineTo(12, 23)
        ..lineTo(3, 43)
        ..lineTo(21, 52)
        ..lineTo(28, 39)
        ..lineTo(25, 91)
        ..quadraticBezierTo(50, 96, 75, 91)
        ..lineTo(72, 39)
        ..lineTo(79, 52)
        ..lineTo(97, 43)
        ..lineTo(88, 23)
        ..lineTo(70, 12)
        ..quadraticBezierTo(50, 28, 30, 12)
        ..close();
      canvas.drawShadow(path, ink.withValues(alpha: .25), 5, false);
      canvas.drawPath(path, Paint()..color = color);
      canvas.save();
      canvas.clipPath(path);
      canvas.drawRect(
        const Rect.fromLTWH(45, 25, 10, 70),
        Paint()..color = Colors.white.withValues(alpha: .17),
      );
      canvas.drawLine(
        const Offset(10, 40),
        const Offset(25, 46),
        Paint()
          ..color = Colors.white70
          ..strokeWidth = 3,
      );
      canvas.drawLine(
        const Offset(75, 46),
        const Offset(90, 40),
        Paint()
          ..color = Colors.white70
          ..strokeWidth = 3,
      );
      canvas.restore();
      canvas.drawCircle(const Offset(65, 36), 5, Paint()..color = Colors.white70);
    }
    final text = TextPainter(
      text: const TextSpan(
        text: 'WOLVES',
        style: TextStyle(
          fontFamily: 'Inter',
          color: Colors.white,
          fontSize: 8,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset(50 - text.width / 2, 56));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_KitPainter old) => old.color != color || old.bag != bag;
}

// ----------------------------------------------------------------- product

class ProductPage extends StatefulWidget {
  const ProductPage({super.key, required this.product, required this.state});
  final StoreProduct product;
  final AppState state;
  @override
  State<ProductPage> createState() => _ProductPageState();
}

class _ProductPageState extends State<ProductPage> {
  StoreVariant? variant;
  int quantity = 1;

  @override
  void initState() {
    super.initState();
    final vs = widget.product.variants;
    variant =
        vs.where((v) => !v.soldOut && v.size.toUpperCase() == 'M').firstOrNull ??
        vs.where((v) => !v.soldOut).firstOrNull ??
        vs.firstOrNull;
  }

  int _inCart(StoreVariant v) =>
      widget.state.cart.items.where((i) => i.variantId == v.id).firstOrNull?.quantity ?? 0;

  /// How many more of [v] can go in the cart: limited by stock and 10 per line.
  int _canAdd(StoreVariant v) {
    final cap = v.stock < _maxPerLine ? v.stock : _maxPerLine;
    final left = cap - _inCart(v);
    return left < 0 ? 0 : left;
  }

  void _add(BuildContext context) {
    final v = variant;
    if (v == null) return;
    final q = quantity.clamp(1, _canAdd(v));
    widget.state.cart.add(
      CartItem(
        variantId: v.id,
        productName: widget.product.name,
        variantLabel: v.label,
        priceMinor: v.priceMinor,
        currency: v.currency,
        quantity: q,
        stock: v.stock,
      ),
    );
    setState(() => quantity = 1);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Added $q × ${widget.product.name} (${v.label}) to your cart.'),
          action: SnackBarAction(
            label: 'View cart',
            onPressed: () => openPage(context, CartPage(state: widget.state)),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: widget.state.cart, builder: (context, _) => _page(context));

  Widget _page(BuildContext context) {
    final p = widget.product;
    final v = variant;
    final canAdd = v == null ? 0 : _canAdd(v);
    if (quantity > canAdd && canAdd > 0) quantity = canAdd;
    final String stockText;
    final Color stockColor;
    if (v == null) {
      stockText = 'This product has no options for sale.';
      stockColor = muted;
    } else if (v.soldOut) {
      stockText = 'Sold out';
      stockColor = _red;
    } else if (v.stock <= 5) {
      stockText = 'Only ${v.stock} left';
      stockColor = _amber;
    } else {
      stockText = 'In stock · ${v.stock} available';
      stockColor = green;
    }
    final inCart = v == null ? 0 : _inCart(v);
    final String buttonText;
    if (v == null || v.soldOut) {
      buttonText = 'Sold out';
    } else if (canAdd == 0) {
      buttonText = 'Maximum already in cart';
    } else {
      buttonText = 'Add to cart · ${_price(v.priceMinor * quantity, v.currency)}';
    }
    return OceanPage(
      title: 'Product detail',
      actions: [_cartButton(context, widget.state)],
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(aspectRatio: 1.3, child: ProductArt.of(p, variant: v)),
              const SizedBox(height: 20),
              Tag(p.category.toUpperCase()),
              const SizedBox(height: 10),
              Text(p.name, style: Theme.of(context).textTheme.headlineMedium),
              if (p.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(p.description, style: const TextStyle(fontFamily: 'Inter', color: muted)),
              ],
              const SizedBox(height: 14),
              Text(
                _price(v?.priceMinor ?? p.fromPrice, v?.currency ?? p.currency),
                style: const TextStyle(fontFamily: 'Inter', fontSize: 22, color: ocean, fontWeight: FontWeight.w800),
              ),
              const Divider(),
              const SectionHeading('Choose an option'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final option in p.variants)
                    ChoiceChip(
                      key: Key('variant-${option.id}'),
                      label: Text(
                        option.soldOut ? '${option.label} · sold out' : option.label,
                        style: option.soldOut ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
                      ),
                      selected: option.id == v?.id,
                      onSelected: option.soldOut
                          ? null
                          : (_) => setState(() {
                              variant = option;
                              quantity = 1;
                            }),
                      showCheckmark: false,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.inventory_2_outlined, size: 16, color: stockColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      inCart > 0 ? '$stockText · $inCart in your cart' : stockText,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: stockColor,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(),
              Row(
                children: [
                  const Expanded(
                    child: Text('Quantity', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    tooltip: 'Decrease quantity',
                    onPressed: quantity > 1 ? () => setState(() => quantity--) : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Semantics(
                    label: 'Quantity $quantity',
                    excludeSemantics: true,
                    child: SizedBox(width: 28, child: Text('$quantity', textAlign: TextAlign.center)),
                  ),
                  IconButton(
                    tooltip: 'Increase quantity',
                    onPressed: quantity < canAdd ? () => setState(() => quantity++) : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('add-to-cart'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
                  onPressed: canAdd > 0 ? () => _add(context) : null,
                  icon: const Icon(Icons.add_shopping_cart),
                  label: Text(buttonText),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------- cart

class CartPage extends StatefulWidget {
  const CartPage({super.key, required this.state});
  final AppState state;
  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  late final TextEditingController promo = TextEditingController(text: _discountCodes[widget.state.cart] ?? '');

  @override
  void dispose() {
    promo.dispose();
    super.dispose();
  }

  void _apply() {
    _discountCodes[widget.state.cart] = promo.text.trim();
    FocusScope.of(context).unfocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state.cart,
    builder: (context, _) {
      final cart = widget.state.cart;
      final code = _codeFor(cart);
      final discount = _previewDiscount(cart);
      final cur = cart.currency;
      return OceanPage(
        title: 'Shopping cart',
        children: [
          if (cart.isEmpty) ...[
            const EmptyCard('Your cart is empty', 'Find something that shows your club colours.'),
            FilledButton(
              onPressed: () => Navigator.maybePop(context),
              child: const Text('Continue browsing'),
            ),
          ] else ...[
            GlassCard(
              child: Column(
                children: [
                  SectionHeading('Your selection', trailing: Tag('${cart.count} ITEMS')),
                  for (final line in cart.items) _CartLine(cart: cart, line: line),
                ],
              ),
            ),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeading('Order summary'),
                  TextField(
                    key: const Key('discount-code'),
                    controller: promo,
                    textCapitalization: TextCapitalization.characters,
                    onSubmitted: (_) => _apply(),
                    decoration: InputDecoration(
                      labelText: 'Discount code',
                      hintText: 'e.g. WELCOME10',
                      suffixIcon: TextButton(
                        onPressed: _apply,
                        style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                        child: const Text('Apply'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (code != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: discount > 0
                          ? Tag('${code.toUpperCase()} · 10% off', color: green, icon: Icons.check_circle_outline)
                          : Tag('$code will be checked when you pay', icon: Icons.info_outline),
                    ),
                  DetailRow('Subtotal', _price(cart.subtotal, cur)),
                  if (discount > 0) DetailRow('Discount (estimate)', '−${_price(discount, cur)}'),
                  const Divider(),
                  DetailRow('Total', _price(cart.subtotal - discount, cur), bold: true),
                  const Text(
                    'The final price is confirmed by the store when you pay.',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: muted),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('to-checkout'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
                    onPressed: () {
                      _discountCodes[cart] = promo.text.trim();
                      openPage(context, CheckoutPage(state: widget.state));
                    },
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('Continue to checkout'),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _CartLine extends StatelessWidget {
  const _CartLine({required this.cart, required this.line});
  final Cart cart;
  final CartItem line;

  @override
  Widget build(BuildContext context) {
    final cap = line.stock < _maxPerLine ? line.stock : _maxPerLine;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 64,
                height: 72,
                child: ProductArt(
                  color: productColor(line.variantLabel, line.productName),
                  bag: _looksLikeBag(line.productName),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${line.variantLabel} · ${_price(line.priceMinor, line.currency)} each',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: muted),
                    ),
                    Text(
                      _price(line.lineTotal, line.currency),
                      style: const TextStyle(fontFamily: 'Inter', color: ocean, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: line.quantity >= cap
                    ? Text(
                        line.stock <= _maxPerLine ? 'Only ${line.stock} in stock' : 'Limit $_maxPerLine per order',
                        style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: muted),
                      )
                    : const SizedBox.shrink(),
              ),
              IconButton(
                tooltip: 'Remove ${line.productName} from cart',
                onPressed: () => cart.remove(line.variantId),
                icon: const Icon(Icons.delete_outline),
              ),
              IconButton(
                tooltip: 'One less ${line.productName}',
                onPressed: line.quantity > 1 ? () => cart.setQuantity(line.variantId, line.quantity - 1) : null,
                icon: const Icon(Icons.remove),
              ),
              Semantics(
                label: 'Quantity ${line.quantity}',
                excludeSemantics: true,
                child: SizedBox(width: 24, child: Text('${line.quantity}', textAlign: TextAlign.center)),
              ),
              IconButton(
                tooltip: 'One more ${line.productName}',
                onPressed: line.quantity < cap ? () => cart.setQuantity(line.variantId, line.quantity + 1) : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- checkout

class _CardChoice {
  const _CardChoice(this.token, this.title, this.subtitle, this.icon);
  final String token, title, subtitle;
  final IconData icon;
}

const _cards = [
  _CardChoice('tok_success', 'Card OK', 'Test card that pays successfully', Icons.credit_card),
  _CardChoice('tok_declined', 'Card declined', 'Test card the bank refuses', Icons.credit_card_off_outlined),
  _CardChoice('tok_capture_fail', 'Capture fails', 'Approved, then the charge fails', Icons.error_outline),
];

class CheckoutPage extends StatefulWidget {
  const CheckoutPage({super.key, required this.state});
  final AppState state;
  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  String token = _cards.first.token;
  bool paying = false;
  String? error;

  /// Kept only when the last attempt's outcome is unknown (connection lost or
  /// server error), so a retry cannot charge twice. Any definite answer
  /// (declined, out of stock, ...) starts a fresh order id next time.
  String? _retryOrderId;

  String _friendly(ApiException e, Cart cart) {
    if (e.isNetwork) {
      return 'Checkout needs a connection. We could not reach the store. Check your connection '
          'and try again; retrying will not charge you twice.';
    }
    switch (e.code) {
      case 'PAYMENT_DECLINED':
        return 'Your card was declined. No money was taken. Try another card.';
      case 'PAYMENT_CAPTURE_FAILED':
        return 'The payment could not be completed, so the hold on your card was released. '
            'No money was taken. Please try again.';
      case 'OUT_OF_STOCK':
        final id = asStr(e.details['variant_id']);
        final item = cart.items.where((i) => i.variantId == id).firstOrNull;
        final available = e.details['available'] ?? e.details['stock'];
        if (item != null) {
          final left = available == null ? '' : ' Only ${asInt(available)} left.';
          return 'Sorry, ${item.productName} (${item.variantLabel}) does not have enough stock.$left '
              'Reduce the quantity or remove it from your cart.';
        }
        return 'Sorry, an item in your cart just sold out. Please check quantities and try again.';
      case 'INVALID_DISCOUNT_CODE':
        return 'The discount code "${_codeFor(cart) ?? ''}" is not valid. '
            'Remove it in your cart or try another code.';
      default:
        return e.message;
    }
  }

  Future<void> _pay() async {
    final state = widget.state;
    final cart = state.cart;
    if (!state.isOnline || cart.isEmpty) return;
    final orderId = _retryOrderId ?? 'ord-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      paying = true;
      error = null;
    });
    final names = {for (final i in cart.items) i.variantId: '${i.productName} · ${i.variantLabel}'};
    try {
      final res = await state.api.post(_checkoutPath, {
        'order_id': orderId,
        'items': [
          for (final i in cart.items) {'variant_id': i.variantId, 'quantity': i.quantity},
        ],
        'discount_code': _codeFor(cart),
        'payment': {'token': token},
      });
      _retryOrderId = null;
      final order = asMap(res);
      cart.clear();
      _discountCodes[cart] = null;
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(builder: (_) => ReceiptPage(state: state, order: order, itemNames: names)),
      );
    } on ApiException catch (e) {
      _retryOrderId = (e.isNetwork || (e.status ?? 0) >= 500) ? orderId : null;
      if (!mounted) return;
      setState(() {
        paying = false;
        error = _friendly(e, cart);
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.state, widget.state.cart]),
    builder: (context, _) {
      final state = widget.state;
      final cart = state.cart;
      final code = _codeFor(cart);
      final discount = _previewDiscount(cart);
      final total = cart.subtotal - discount;
      final cur = cart.currency;
      final online = state.isOnline;
      final user = state.user;
      return OceanPage(
        title: 'Checkout',
        children: [
          if (cart.isEmpty)
            const EmptyCard('Nothing to pay for', 'Your cart is empty.')
          else ...[
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeading('Order details'),
                  if (user != null) DetailRow('Customer', user.displayName ?? user.email),
                  for (final line in cart.items)
                    DetailRow(
                      '${line.productName} · ${line.variantLabel} × ${line.quantity}',
                      _price(line.lineTotal, line.currency),
                    ),
                  const Divider(),
                  DetailRow('Subtotal', _price(cart.subtotal, cur)),
                  if (code != null)
                    DetailRow(
                      'Code ${code.toUpperCase()}',
                      discount > 0 ? '−${_price(discount, cur)} (estimate)' : 'Checked when you pay',
                    ),
                  DetailRow('Total', _price(total, cur), bold: true),
                ],
              ),
            ),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeading('Payment method'),
                  const Text(
                    'Demo payments: choose a test card. No real card is charged.',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: muted),
                  ),
                  const SizedBox(height: 8),
                  for (final c in _cards)
                    Semantics(
                      selected: c.token == token,
                      inMutuallyExclusiveGroup: true,
                      child: ListTile(
                        key: Key('card-${c.token}'),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                        minTileHeight: 56,
                        enabled: !paying,
                        selected: c.token == token,
                        onTap: () => setState(() {
                          token = c.token;
                          error = null;
                        }),
                        leading: Icon(
                          c.token == token ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                          color: c.token == token ? ocean : muted,
                        ),
                        title: Text(c.title, style: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w700)),
                        subtitle: Text(c.subtitle, style: const TextStyle(fontFamily: 'Inter', fontSize: 11)),
                        trailing: ExcludeSemantics(child: Icon(c.icon, color: muted)),
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (!online)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: _InlineMessage(
                        icon: Icons.cloud_off_outlined,
                        text: 'Checkout needs a connection. Your cart is kept; pay when you are back online.',
                        color: _amber,
                      ),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _InlineMessage(icon: Icons.error_outline, text: error!, color: _red),
                    ),
                  FilledButton(
                    key: const Key('pay'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 60),
                      textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                    onPressed: (!online || paying) ? null : _pay,
                    child: paying
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                              ),
                              SizedBox(width: 12),
                              Text('Paying…'),
                            ],
                          )
                        : Text('Pay ${_price(total, cur)}'),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    },
  );
}

// ----------------------------------------------------------------- receipt

class ReceiptPage extends StatefulWidget {
  const ReceiptPage({super.key, required this.state, required this.order, this.itemNames = const {}});
  final AppState state;

  /// The POST /api/v1/store/checkout response body.
  final Map<String, dynamic> order;

  /// variant_id -> "Product · option", captured before the cart was cleared.
  final Map<String, String> itemNames;

  @override
  State<ReceiptPage> createState() => _ReceiptPageState();
}

class _ReceiptPageState extends State<ReceiptPage> {
  bool opening = false;
  String? pdfNote;

  Map<String, dynamic> get _receipt => asMap(widget.order['receipt']);

  Future<void> _openPdf() async {
    final orderId = asStr(widget.order['order_id'], 'order');
    final b64 = asStr(_receipt['pdf_base64']);
    if (b64.isEmpty) {
      setState(() => pdfNote = 'The store did not send a PDF for this order.');
      return;
    }
    setState(() {
      opening = true;
      pdfNote = null;
    });
    String? path;
    try {
      final bytes = base64Decode(b64);
      final dir = await getApplicationDocumentsDirectory();
      final safeId = orderId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
      final file = File('${dir.path}${Platform.pathSeparator}receipt-$safeId.pdf');
      await file.writeAsBytes(bytes, flush: true);
      path = file.path;
      final result = await OpenFilex.open(path, type: 'application/pdf');
      if (!mounted) return;
      setState(() {
        opening = false;
        pdfNote = result.type == ResultType.done ? null : 'No app could open the PDF. It is saved at: $path';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        opening = false;
        pdfNote = path == null
            ? 'The PDF receipt could not be saved on this phone.'
            : 'The PDF could not be opened. It is saved at: $path';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final cur = asStr(o['currency'], 'PKR');
    final payment = asMap(o['payment']);
    final payload = asMap(_receipt['payload']);
    final signature = asStr(_receipt['signature']);
    final status = asStr(o['status'], 'paid');
    final paid = status.toLowerCase() == 'paid' || asStr(payment['state']).toLowerCase() == 'captured';
    final paidAt = asStr(payload['paid_at'] ?? o['paid_at']);
    final discount = asInt(o['discount_minor']);
    final shortSig = signature.length > 12 ? signature.substring(0, 12) : signature;
    return OceanPage(
      title: 'Order receipt',
      children: [
        GlassCard(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(shape: BoxShape.circle, color: green.withValues(alpha: .1)),
                child: const Icon(Icons.check, size: 42, color: green, semanticLabel: 'Payment successful'),
              ),
              const SizedBox(height: 20),
              Text('All set for matchday.', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('Thank you. Your order is confirmed.', textAlign: TextAlign.center),
              const SizedBox(height: 18),
              Tag(
                paid ? 'PAID' : status.toUpperCase(),
                color: paid ? green : _amber,
                icon: paid ? Icons.verified_outlined : Icons.info_outline,
              ),
              const Divider(),
              DetailRow('Order reference', asStr(o['order_id'])),
              if (paidAt.isNotEmpty) DetailRow('Paid', formatDateTime(paidAt)),
              if (asStr(payment['capture_id']).isNotEmpty) DetailRow('Payment ref', asStr(payment['capture_id'])),
              const Divider(),
              for (final raw in asList(o['items']))
                _receiptLine(asMap(raw), cur),
              const Divider(),
              DetailRow('Subtotal', _price(asInt(o['subtotal_minor']), cur)),
              if (discount > 0) DetailRow('Discount', '−${_price(discount, cur)}'),
              DetailRow('Total paid', _price(asInt(o['total_minor']), cur), bold: true),
              if (signature.isNotEmpty) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Tag('Verified receipt · $shortSig', color: green, icon: Icons.verified_user_outlined),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('open-pdf'),
                  onPressed: opening ? null : _openPdf,
                  icon: opening
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Open PDF receipt'),
                ),
              ),
              if (pdfNote != null) ...[
                const SizedBox(height: 12),
                _InlineMessage(icon: Icons.info_outline, text: pdfNote!, color: muted),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.popUntil(context, (route) => route.isFirst),
                  child: const Text('Back to club store'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _receiptLine(Map<String, dynamic> item, String cur) {
    final id = asStr(item['variant_id']);
    final qty = asInt(item['quantity']);
    final unit = asInt(item['unit_price_minor']);
    return DetailRow('${widget.itemNames[id] ?? humanize(id)} × $qty', _price(unit * qty, cur));
  }
}
