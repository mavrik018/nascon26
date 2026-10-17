import 'package:flutter/foundation.dart';

class CartItem {
  CartItem({
    required this.variantId,
    required this.productName,
    required this.variantLabel,
    required this.priceMinor,
    required this.currency,
    required this.quantity,
    required this.stock,
  });

  final String variantId;
  final String productName;
  final String variantLabel;
  final int priceMinor;
  final String currency;
  int quantity;
  final int stock;

  int get lineTotal => priceMinor * quantity;
}

/// In-memory shopping cart (cleared on logout and after a paid order).
class Cart extends ChangeNotifier {
  final List<CartItem> items = [];

  int get count => items.fold(0, (sum, i) => sum + i.quantity);
  int get subtotal => items.fold(0, (sum, i) => sum + i.lineTotal);
  String get currency => items.isEmpty ? 'PKR' : items.first.currency;
  bool get isEmpty => items.isEmpty;

  void add(CartItem item) {
    final existing = items.where((i) => i.variantId == item.variantId).firstOrNull;
    if (existing != null) {
      existing.quantity = (existing.quantity + item.quantity).clamp(1, 10);
    } else {
      items.add(item);
    }
    notifyListeners();
  }

  void setQuantity(String variantId, int quantity) {
    final item = items.where((i) => i.variantId == variantId).firstOrNull;
    if (item == null) return;
    if (quantity <= 0) {
      items.remove(item);
    } else {
      item.quantity = quantity.clamp(1, 10);
    }
    notifyListeners();
  }

  void remove(String variantId) {
    items.removeWhere((i) => i.variantId == variantId);
    notifyListeners();
  }

  void clear() {
    if (items.isEmpty) return;
    items.clear();
    notifyListeners();
  }
}
