import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class CachedValue {
  const CachedValue(this.data, this.savedAt);
  final dynamic data;
  final DateTime savedAt;
}

/// Everything the app keeps on the device: settings, the response cache,
/// the offline action queue and the sync result log.
abstract class LocalStore {
  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);

  Future<CachedValue?> getCache(String key);
  Future<void> putCache(String key, dynamic data);

  Future<List<PendingAction>> pendingActions();
  Future<void> enqueue(PendingAction action);
  Future<void> removeActions(Iterable<String> actionIds);

  Future<List<SyncLogEntry>> syncLog();
  Future<void> addSyncLog(List<SyncLogEntry> entries);
}

/// SQLite implementation (sqflite). Survives force-close and restarts.
class SqliteLocalStore implements LocalStore {
  SqliteLocalStore._(this._db);
  final Database _db;

  static Future<SqliteLocalStore> open() async {
    final path = p.join(await getDatabasesPath(), 'league_app.db');
    final db = await openDatabase(
      path,
      version: 2,
      // v2: pending_actions.owner, so each signed-in account keeps its own queue.
      onUpgrade: (db, from, _) async {
        if (from < 2) await db.execute("ALTER TABLE pending_actions ADD COLUMN owner TEXT NOT NULL DEFAULT ''");
      },
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await db.execute('CREATE TABLE cache (key TEXT PRIMARY KEY, json TEXT NOT NULL, saved_at TEXT NOT NULL)');
        await db.execute(
          'CREATE TABLE pending_actions ('
          'seq INTEGER PRIMARY KEY AUTOINCREMENT, '
          'action_id TEXT NOT NULL UNIQUE, '
          'type TEXT NOT NULL, '
          'queued_at TEXT NOT NULL, '
          'base_version INTEGER NOT NULL, '
          'payload TEXT NOT NULL, '
          'label TEXT NOT NULL, '
          "owner TEXT NOT NULL DEFAULT '')",
        );
        await db.execute(
          'CREATE TABLE sync_log ('
          'seq INTEGER PRIMARY KEY AUTOINCREMENT, json TEXT NOT NULL)',
        );
      },
    );
    return SqliteLocalStore._(db);
  }

  @override
  Future<String?> getSetting(String key) async {
    final rows = await _db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  @override
  Future<void> setSetting(String key, String value) =>
      _db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<CachedValue?> getCache(String key) async {
    final rows = await _db.query('cache', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return CachedValue(
      jsonDecode(rows.first['json'] as String),
      DateTime.tryParse(rows.first['saved_at'] as String) ?? DateTime.now(),
    );
  }

  @override
  Future<void> putCache(String key, dynamic data) => _db.insert('cache', {
    'key': key,
    'json': jsonEncode(data),
    'saved_at': DateTime.now().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<List<PendingAction>> pendingActions() async {
    final rows = await _db.query('pending_actions', orderBy: 'seq ASC');
    return [
      for (final r in rows)
        PendingAction(
          actionId: r['action_id'] as String,
          type: r['type'] as String,
          queuedAt: r['queued_at'] as String,
          baseVersion: r['base_version'] as int,
          payload: Map<String, dynamic>.from(jsonDecode(r['payload'] as String) as Map),
          label: r['label'] as String,
          owner: r['owner'] as String,
        ),
    ];
  }

  @override
  Future<void> enqueue(PendingAction a) => _db.insert('pending_actions', {
    'action_id': a.actionId,
    'type': a.type,
    'queued_at': a.queuedAt,
    'base_version': a.baseVersion,
    'payload': jsonEncode(a.payload),
    'label': a.label,
    'owner': a.owner,
  });

  @override
  Future<void> removeActions(Iterable<String> actionIds) async {
    final batch = _db.batch();
    for (final id in actionIds) {
      batch.delete('pending_actions', where: 'action_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<List<SyncLogEntry>> syncLog() async {
    final rows = await _db.query('sync_log', orderBy: 'seq DESC', limit: 50);
    return [
      for (final r in rows) SyncLogEntry.fromJson(Map<String, dynamic>.from(jsonDecode(r['json'] as String) as Map)),
    ];
  }

  @override
  Future<void> addSyncLog(List<SyncLogEntry> entries) async {
    final batch = _db.batch();
    for (final e in entries) {
      batch.insert('sync_log', {'json': jsonEncode(e.toJson())});
    }
    await batch.commit(noResult: true);
  }
}

/// In-memory store for tests.
class MemoryLocalStore implements LocalStore {
  final settings = <String, String>{};
  final cache = <String, CachedValue>{};
  final queue = <PendingAction>[];
  final log = <SyncLogEntry>[];

  @override
  Future<String?> getSetting(String key) async => settings[key];
  @override
  Future<void> setSetting(String key, String value) async => settings[key] = value;
  @override
  Future<CachedValue?> getCache(String key) async => cache[key];
  @override
  Future<void> putCache(String key, dynamic data) async =>
      cache[key] = CachedValue(jsonDecode(jsonEncode(data)), DateTime.now());
  @override
  Future<List<PendingAction>> pendingActions() async => List.of(queue);
  @override
  Future<void> enqueue(PendingAction action) async => queue.add(action);
  @override
  Future<void> removeActions(Iterable<String> actionIds) async {
    final ids = actionIds.toSet();
    queue.removeWhere((a) => ids.contains(a.actionId));
  }

  @override
  Future<List<SyncLogEntry>> syncLog() async => log.reversed.take(50).toList();
  @override
  Future<void> addSyncLog(List<SyncLogEntry> entries) async => log.addAll(entries);
}

/// Secrets (login tokens, saved accounts). Android: Keystore-backed storage.
abstract class TokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureTokenStore implements TokenStore {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemoryTokenStore implements TokenStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
