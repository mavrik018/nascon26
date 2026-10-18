import 'dart:math';
import 'dart:ui' show Color;

final Random _secure = Random.secure();

/// RFC 4122 version-4 UUID from a cryptographically secure source (like Postgres gen_random_uuid()).
/// Only used for ids the phone must create before the server sees the request: idempotency keys for
/// events, roster requests, orders and offline actions (spec 5.14). Everything else gets its id from the server.
String newId() {
  final b = List<int>.generate(16, (_) => _secure.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// UTC timestamp in the spec format YYYY-MM-DDTHH:MM:SSZ.
String isoUtc(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

String isoDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

/// 450000 paisa -> "PKR 4,500.00".
String formatMoney(num? minor, [String? currency]) {
  final value = (minor ?? 0).toInt();
  final negative = value < 0;
  final abs = value.abs();
  final major = (abs ~/ 100).toString();
  final cents = (abs % 100).toString().padLeft(2, '0');
  final buf = StringBuffer();
  for (var i = 0; i < major.length; i++) {
    if (i > 0 && (major.length - i) % 3 == 0) buf.write(',');
    buf.write(major[i]);
  }
  return '${negative ? '-' : ''}${currency ?? 'PKR'} $buf.$cents';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "17 Oct, 14:30" in the phone's local time; falls back to the raw text.
String formatDateTime(String? raw) {
  if (raw == null || raw.isEmpty) return 'Time to be announced';
  final t = DateTime.tryParse(raw);
  if (t == null) return raw;
  final l = t.toLocal();
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  return '${l.day} ${_months[l.month - 1]} ${l.year}, $hh:$mm';
}

String formatSavedAgo(DateTime? saved) {
  if (saved == null) return '';
  final diff = DateTime.now().difference(saved);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  return formatDateTime(saved.toIso8601String());
}

/// Turns "club-alpha-1" / "first_name" into readable text when no name exists.
String humanize(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final words = raw.replaceAll(RegExp(r'[_\-]+'), ' ').trim().split(' ');
  return words.map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
}

int asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

String asStr(Object? v, [String fallback = '']) => v == null ? fallback : v.toString();

Map<String, dynamic> asMap(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<dynamic> asList(Object? v) => v is List ? v : const [];

/// '#1E40AF' / '1E40AF' / '#fff' -> Color, or null when it is not a hex colour (tenant branding).
Color? parseHexColor(String? hex) {
  if (hex == null) return null;
  var h = hex.trim().replaceFirst('#', '');
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return (h.length == 8 && v != null) ? Color(v) : null;
}
