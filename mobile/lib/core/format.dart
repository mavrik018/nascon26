import 'dart:math';

final Random _rand = Random();

/// Client-generated id: `<prefix>-<millis>-<random>`, within the spec's
/// 1-64 chars of [A-Za-z0-9_.:-].
String newId(String prefix) {
  final ms = DateTime.now().millisecondsSinceEpoch;
  final r = _rand.nextInt(0x7fffffff).toRadixString(36);
  return '$prefix-$ms-$r';
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
