import 'package:flutter/material.dart';

/// Scores and status represent projections of scoring_events, not SQL columns.
class Fixture {
  const Fixture(
    this.id,
    this.sport,
    this.home,
    this.away,
    this.status,
    this.time,
    this.homeScore,
    this.awayScore,
  );
  final String id, sport, home, away, status, time;
  final int homeScore, awayScore;
}

const fixtures = [
  Fixture(
    'match-01',
    'Football',
    'Alpha Wolves',
    'Karachi Strikers',
    'Live',
    '18:00',
    2,
    1,
  ),
  Fixture(
    'match-02',
    'Football',
    'Capital United',
    'Lahore Athletic',
    'Upcoming',
    '19:30',
    0,
    0,
  ),
  Fixture(
    'match-03',
    'Football',
    'Peshawar City',
    'Rawalpindi Kings',
    'Results',
    '16:00',
    1,
    3,
  ),
  Fixture(
    'match-04',
    'Basketball',
    'Alpha Wolves',
    'Capital United',
    'Live',
    '18:30',
    64,
    58,
  ),
  Fixture(
    'match-05',
    'Basketball',
    'Karachi Strikers',
    'Lahore Athletic',
    'Upcoming',
    '20:00',
    0,
    0,
  ),
  Fixture(
    'match-06',
    'Cricket',
    'Alpha Wolves',
    'Peshawar City',
    'Upcoming',
    '21:00',
    0,
    0,
  ),
  Fixture(
    'match-07',
    'Esports',
    'Apex Alpha',
    'Cyber Storm',
    'Upcoming',
    '22:00',
    0,
    0,
  ),
];

class SquadPlayer {
  const SquadPlayer(
    this.id,
    this.name,
    this.position,
    this.registration,
    this.role,
  );
  final String id, name, position, registration, role;
}

const players = [
  SquadPlayer('player-01', 'Malik Vance', 'Forward', 'Permanent', 'Captain'),
  SquadPlayer('player-02', 'Zaid Hamza', 'Defender', 'Permanent', 'Player'),
  SquadPlayer('player-03', 'Kashif Tariq', 'Midfielder', 'Permanent', 'Player'),
  SquadPlayer('player-04', 'Omar Farooq', 'Goalkeeper', 'Permanent', 'Player'),
  SquadPlayer('player-05', 'Hassan Ali', 'Forward', 'Loan', 'Player'),
  SquadPlayer('player-06', 'Ayaan Khan', 'Defender', 'Permanent', 'Player'),
];

class ShopProduct {
  const ShopProduct(
    this.id,
    this.name,
    this.category,
    this.description,
    this.priceMinor,
    this.color,
    this.sizes,
  );
  final String id, name, category, description;
  final int priceMinor;
  final Color color;
  final List<String> sizes;
  String variantId(String size) => '$id-${size.toLowerCase()}';
  int stock(String size) => size == 'XL' ? 0 : 7;
}

const products = [
  ShopProduct(
    'kit-home',
    'Wolves Home Kit',
    'Kits',
    'Your club. Your colours. A lightweight performance jersey in signature ocean blue.',
    450000,
    Color(0xFF006D9F),
    ['S', 'M', 'L', 'XL'],
  ),
  ShopProduct(
    'kit-away',
    'Wolves Away Kit',
    'Kits',
    'A clean white match jersey with a deep navy finish.',
    420000,
    Color(0xFFCBD9E3),
    ['S', 'M', 'L', 'XL'],
  ),
  ShopProduct(
    'training',
    'Training Tee',
    'Training',
    'Made for the work between matchdays. A breathable training essential.',
    280000,
    Color(0xFF143A51),
    ['S', 'M', 'L', 'XL'],
  ),
  ShopProduct(
    'bag',
    'Club Kit Bag',
    'Accessories',
    'Keep your matchday essentials together with the official club kit bag.',
    320000,
    Color(0xFF37798B),
    ['One size'],
  ),
];
String money(int minor) {
  final value = (minor / 100).toStringAsFixed(minor % 100 == 0 ? 0 : 2);
  final parts = value.split('.');
  final grouped = parts.first.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return 'PKR $grouped${parts.length == 2 ? '.${parts[1]}' : ''}';
}

String initials(String name) => name.split(' ').take(2).map((s) => s[0]).join();

class CartLine {
  CartLine(this.product, this.size, this.quantity);
  final ShopProduct product;
  final String size;
  int quantity;
  int get total => product.priceMinor * quantity;
}

/// Local UI state only; replace fixtures with FastAPI view models later.
class PreviewState extends ChangeNotifier {
  String role = 'Club manager';
  final List<CartLine> cart = [];
  bool discount = false;
  int get count => cart.fold(0, (sum, line) => sum + line.quantity);
  int get subtotal => cart.fold(0, (sum, line) => sum + line.total);
  int get discountMinor => discount ? subtotal * 10 ~/ 100 : 0;
  int get total => subtotal - discountMinor;
  bool get canManage => role == 'Club manager' || role == 'Platform admin';
  bool get canScore => role == 'League organizer' || role == 'Platform admin';
  void add(ShopProduct product, String size, int quantity) {
    if (!product.sizes.contains(size) ||
        product.stock(size) == 0 ||
        quantity < 1)
      return;
    final existing = cart
        .where((line) => line.product.id == product.id && line.size == size)
        .firstOrNull;
    if (existing == null) {
      cart.add(CartLine(product, size, quantity.clamp(1, product.stock(size))));
    } else {
      existing.quantity = (existing.quantity + quantity).clamp(
        1,
        product.stock(size),
      );
    }
    notifyListeners();
  }

  void change(CartLine line, int delta) {
    line.quantity = (line.quantity + delta).clamp(
      0,
      line.product.stock(line.size),
    );
    if (line.quantity == 0) cart.remove(line);
    notifyListeners();
  }

  void applyDiscount(bool value) {
    discount = value;
    notifyListeners();
  }

  void setRole(String value) {
    role = value;
    notifyListeners();
  }

  void clearCart() {
    cart.clear();
    discount = false;
    notifyListeners();
  }
}
