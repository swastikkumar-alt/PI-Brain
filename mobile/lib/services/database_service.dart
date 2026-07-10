import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as legacy_sqflite;
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../models/entity.dart';
import '../models/edge.dart';
import '../models/financial_transaction.dart';
import '../models/memory.dart';
import '../models/sync_event.dart';
import '../models/message.dart';
import '../models/phone_action.dart';

class EntityDedupeResult {
  const EntityDedupeResult({
    required this.scanned,
    required this.removed,
    required this.hashesBackfilled,
  });

  final int scanned;
  final int removed;
  final int hashesBackfilled;
}

class SearchIndexMaintenanceResult {
  const SearchIndexMaintenanceResult({
    required this.inserted,
    required this.updated,
    required this.deleted,
  });

  final int inserted;
  final int updated;
  final int deleted;

  int get changedRows => inserted + updated + deleted;
}

class _EntityHashBackfill {
  const _EntityHashBackfill({
    required this.sourceConnector,
    required this.contentHash,
  });

  final String sourceConnector;
  final String contentHash;
}

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _database;
  static Future<Database>? _openingDatabase;
  static const _storage = FlutterSecureStorage();
  static const _encryptedDatabaseName = 'pie_local_encrypted_v3.db';
  static const _legacyPlaintextDatabaseName = 'pie_local_secure_v2.db';
  static const _databasePasswordKey = 'pie_sqlcipher_password_v1';
  static final Sha256 _sha256 = Sha256();
  static DateTime? _lastSearchIndexRepair;

  DatabaseService._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    final openingDatabase = _openingDatabase;
    if (openingDatabase != null) return openingDatabase;

    _openingDatabase = _initDB();
    try {
      _database = await _openingDatabase;
    } finally {
      _openingDatabase = null;
    }
    return _database!;
  }

  Future<Database> _initDB() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    final encryptedPath = join(documentsDirectory.path, _encryptedDatabaseName);
    final legacyPlaintextPath = join(
      documentsDirectory.path,
      _legacyPlaintextDatabaseName,
    );
    var encryptedExists = await File(encryptedPath).exists();
    var password = await _getOrCreateDatabasePassword();

    Database db;
    try {
      db = await _openEncryptedDatabase(encryptedPath, password);
    } on DatabaseException catch (error, stackTrace) {
      developer.log(
        'Encrypted database could not be opened; quarantining and creating a fresh encrypted store.',
        name: 'DatabaseService',
        error: error,
        stackTrace: stackTrace,
      );
      await _quarantineEncryptedDatabase(encryptedPath);
      await _storage.delete(key: _databasePasswordKey);
      password = await _getOrCreateDatabasePassword();
      encryptedExists = false;
      db = await _openEncryptedDatabase(encryptedPath, password);
    }

    if (!encryptedExists && await File(legacyPlaintextPath).exists()) {
      await _migrateLegacyPlaintextDatabase(legacyPlaintextPath, db);
    }

    return db;
  }

  Future<Database> _openEncryptedDatabase(String path, String password) {
    return openDatabase(
      path,
      version: 9,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.rawQuery('PRAGMA journal_mode = WAL');
        await db.rawQuery('PRAGMA secure_delete = ON');
      },
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
      password: password,
    );
  }

  Future<void> _quarantineEncryptedDatabase(String encryptedPath) async {
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final source = File('$encryptedPath$suffix');
      if (!await source.exists()) continue;

      final target = File('$encryptedPath.$timestamp.unreadable$suffix');
      try {
        await source.rename(target.path);
      } catch (error, stackTrace) {
        developer.log(
          'Failed to quarantine unreadable encrypted database file ${source.path}.',
          name: 'DatabaseService',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<String> _getOrCreateDatabasePassword() async {
    final existing = await _storage.read(key: _databasePasswordKey);
    if (existing != null && existing.length >= 32) {
      return existing;
    }

    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final password = base64UrlEncode(bytes);
    await _storage.write(key: _databasePasswordKey, value: password);
    return password;
  }

  Future<void> _migrateLegacyPlaintextDatabase(
    String legacyPath,
    Database encryptedDb,
  ) async {
    legacy_sqflite.Database? legacyDb;
    try {
      legacyDb = await legacy_sqflite.openDatabase(
        legacyPath,
        readOnly: true,
        singleInstance: false,
      );

      await encryptedDb.transaction((txn) async {
        final sourceDb = legacyDb!;
        await _copyTableIfPresent(sourceDb, txn, 'entities');
        await _copyTableIfPresent(sourceDb, txn, 'edges');
        await _copyTableIfPresent(sourceDb, txn, 'embeddings');
        await _copyTableIfPresent(sourceDb, txn, 'memories');
        await _copyTableIfPresent(sourceDb, txn, 'sync_events');
        await _copyTableIfPresent(sourceDb, txn, 'messages');
        await _copyTableIfPresent(sourceDb, txn, 'citations');
        await _copyTableIfPresent(sourceDb, txn, 'financial_transactions');
        await _copyTableIfPresent(
          sourceDb,
          txn,
          'financial_transaction_evidence',
        );
        await _rebuildFtsFromEntities(txn);
      });
    } catch (error, stackTrace) {
      developer.log(
        'Legacy plaintext database migration failed.',
        name: 'DatabaseService',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      await legacyDb?.close();
    }
  }

  Future<void> _copyTableIfPresent(
    legacy_sqflite.Database sourceDb,
    Transaction txn,
    String table,
  ) async {
    try {
      final rows = await sourceDb.query(table);
      for (final row in rows) {
        await txn.insert(
          table,
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    } catch (error, stackTrace) {
      developer.log(
        'Skipping legacy table migration for $table.',
        name: 'DatabaseService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _rebuildFtsFromEntities(Transaction txn) async {
    await txn.delete('entities_fts');
    final rows = await txn.query(
      'entities',
      columns: ['id', 'content'],
      where: 'content IS NOT NULL AND TRIM(content) <> ""',
    );

    for (final row in rows) {
      await txn.insert('entities_fts', {
        'entity_id': row['id'],
        'content': row['content'],
      });
    }
  }

  Future<void> _createDB(Database db, int version) async {
    // 1. Entities table representing nodes in our graph
    await db.execute('''
      CREATE TABLE entities (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        source_connector TEXT,
        content TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        is_synced INTEGER DEFAULT 0,
        content_hash TEXT
      )
    ''');

    // 2. Edges table representing connections
    await db.execute('''
      CREATE TABLE edges (
        id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        target_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        relationship_type TEXT NOT NULL,
        confidence_score REAL DEFAULT 1.0,
        valid_from INTEGER NOT NULL,
        valid_until INTEGER
      )
    ''');

    // 3. Vector Embeddings table layout (sqlite-vec virtual table layout)
    // Note: FTS5 and sqlite-vec are compiled dynamic modules loaded into SQLite.
    // We mock the schema here. Because standard Android/iOS sqflite doesn't ship with vec0,
    // we use a standard BLOB column for fallback representation while writing syntax matching vec0.
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE embeddings USING vec0(
          entity_id TEXT UNIQUE,
          embedding float[384]
        )
      ''');
    } catch (_) {
      // Fallback table for environments without sqlite-vec pre-compiled module
      await db.execute('''
        CREATE TABLE IF NOT EXISTS embeddings (
          entity_id TEXT PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
          embedding BLOB NOT NULL
        )
      ''');
    }

    // 4. Memories table
    await db.execute('''
      CREATE TABLE memories (
        id TEXT PRIMARY KEY,
        entity_id TEXT REFERENCES entities(id) ON DELETE SET NULL,
        memory_type TEXT NOT NULL,
        summary TEXT NOT NULL
      )
    ''');

    // 5. Sync Events Table (CRDT sorted Ledger)
    await db.execute('''
      CREATE TABLE sync_events (
        event_id TEXT PRIMARY KEY,
        mutation_type TEXT NOT NULL,
        target_table TEXT NOT NULL,
        payload TEXT NOT NULL,
        status TEXT NOT NULL,
        content_hash TEXT
      )
    ''');

    // 6. FTS4 Virtual table for full-text search
    await db.execute('''
      CREATE VIRTUAL TABLE entities_fts USING fts4(
        entity_id,
        content
      )
    ''');

    // 7. Messages and Citations for conversational history
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender TEXT NOT NULL,
        text TEXT NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE citations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id TEXT NOT NULL,
        document_id TEXT NOT NULL,
        title TEXT NOT NULL,
        chunk_index INTEGER NOT NULL,
        FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
      )
    ''');

    await _createIndexes(db);
    await _createActionTables(db);
    await _createGroundedIntelligenceTables(db);
    await _createLocalDataFreshnessTables(db);
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createIndexes(db);
    }
    if (oldVersion < 3) {
      await _createActionTables(db);
    }
    if (oldVersion < 4) {
      await _createPhoneAgentV2Tables(db);
    }
    if (oldVersion < 5) {
      await _createDedupeColumnsAndIndexes(db);
    }
    if (oldVersion < 8) {
      await _createGroundedIntelligenceTables(db);
    }
    if (oldVersion < 9) {
      await _createLocalDataFreshnessTables(db);
    }
  }

  Future<void> _createIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_entities_created_at ON entities(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_entities_type ON entities(entity_type)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_entities_source ON entities(source_connector)',
    );
    await _createDedupeColumnsAndIndexes(db);
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_edges_source ON edges(source_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_events_status ON sync_events(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_conversation_time ON messages(conversation_id, timestamp)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_citations_message ON citations(message_id)',
    );
  }

  Future<void> _createGroundedIntelligenceTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS financial_transactions (
        id TEXT PRIMARY KEY,
        canonical_key TEXT NOT NULL UNIQUE,
        direction TEXT NOT NULL,
        amount_minor INTEGER NOT NULL,
        currency TEXT NOT NULL,
        occurred_at INTEGER NOT NULL,
        source_connector TEXT NOT NULL,
        merchant TEXT,
        reference TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS financial_transaction_evidence (
        transaction_id TEXT NOT NULL REFERENCES financial_transactions(id) ON DELETE CASCADE,
        entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        source_connector TEXT NOT NULL,
        confidence REAL NOT NULL DEFAULT 1.0,
        created_at INTEGER NOT NULL,
        PRIMARY KEY(transaction_id, entity_id)
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_financial_transactions_time ON financial_transactions(occurred_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_financial_transactions_direction ON financial_transactions(direction, occurred_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_financial_evidence_entity ON financial_transaction_evidence(entity_id)',
    );
  }

  Future<void> _createLocalDataFreshnessTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS datasource_sync_state (
        source_id TEXT PRIMARY KEY,
        last_started_at INTEGER,
        last_success_at INTEGER,
        last_native_cursor TEXT,
        total_read INTEGER NOT NULL DEFAULT 0,
        imported INTEGER NOT NULL DEFAULT 0,
        skipped_duplicates INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_scheduled_at INTEGER,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_datasource_sync_state_success ON datasource_sync_state(last_success_at DESC)',
    );
  }

  Future<void> _createDedupeColumnsAndIndexes(Database db) async {
    await _addColumnIfMissing(db, 'entities', 'content_hash', 'TEXT');
    await _addColumnIfMissing(db, 'sync_events', 'content_hash', 'TEXT');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_entities_source_hash_unique ON entities(source_connector, content_hash) WHERE content_hash IS NOT NULL',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_events_hash_unique ON sync_events(target_table, content_hash) WHERE content_hash IS NOT NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_entities_content_hash ON entities(content_hash)',
    );
  }

  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String type,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((row) => row['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
    }
  }

  Future<void> _createActionTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS action_audit (
        id TEXT PRIMARY KEY,
        action_type TEXT NOT NULL,
        status TEXT NOT NULL,
        risk TEXT NOT NULL,
        target_app TEXT NOT NULL,
        recipient_label TEXT,
        payload_json TEXT NOT NULL,
        result_text TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS contact_aliases (
        alias TEXT PRIMARY KEY,
        contact_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        phone_number TEXT NOT NULL,
        normalized_phone_number TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS command_memories (
        id TEXT PRIMARY KEY,
        command_pattern TEXT NOT NULL,
        action_type TEXT NOT NULL,
        target_app TEXT NOT NULL,
        success_count INTEGER NOT NULL DEFAULT 0,
        failure_count INTEGER NOT NULL DEFAULT 0,
        last_used_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_action_audit_status ON action_audit(status, updated_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_action_audit_app ON action_audit(target_app, updated_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_contact_aliases_contact ON contact_aliases(contact_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_command_memories_action ON command_memories(action_type, target_app)',
    );
    await _createPhoneAgentV2Tables(db);
  }

  Future<void> _createPhoneAgentV2Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contact_profiles (
        contact_key TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        relationship_type TEXT NOT NULL,
        preferred_tone TEXT NOT NULL,
        language_preference TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS manual_recipients (
        id TEXT PRIMARY KEY,
        alias TEXT,
        display_name TEXT NOT NULL,
        recipient_kind TEXT NOT NULL,
        phone_number TEXT,
        normalized_phone_number TEXT,
        email_address TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS datasource_preferences (
        source_id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        is_enabled INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_unlock_policy (
        scope TEXT PRIMARY KEY,
        policy TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_drafts (
        id TEXT PRIMARY KEY,
        action_id TEXT NOT NULL,
        raw_command TEXT NOT NULL,
        detected_intent TEXT NOT NULL,
        detected_language TEXT NOT NULL,
        tone TEXT NOT NULL,
        drafted_text TEXT NOT NULL,
        final_text TEXT,
        email_subject TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_manual_recipients_alias ON manual_recipients(alias)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_manual_recipients_phone ON manual_recipients(normalized_phone_number)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_manual_recipients_email ON manual_recipients(email_address)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_message_drafts_action ON message_drafts(action_id)',
    );

    await _seedDatasourcePreferences(db);
    await db.insert('app_unlock_policy', {
      'scope': 'default',
      'policy': AppUnlockPolicy.unlockEachTime.name,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _seedDatasourcePreferences(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    const defaults = <String, String>{
      'notifications': 'Live Notifications',
      'files': 'Local Documents',
      'gmail_notifications': 'Gmail Notifications',
      'whatsapp_context': 'WhatsApp Notifications',
      'contacts_metadata': 'Contacts Metadata',
      'sms_messages': 'SMS Messages',
      'health_connect': 'Health Connect',
      'call_logs': 'Call Logs',
    };

    for (final entry in defaults.entries) {
      await db.insert('datasource_preferences', {
        'source_id': entry.key,
        'display_name': entry.value,
        'is_enabled': 0,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  String _buildFtsQuery(String rawQuery) {
    final terms = rawQuery
        .trim()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .map((term) => '"${term.replaceAll('"', '""')}"');

    return terms.join(' ');
  }

  String _buildFtsAnyQuery(String rawQuery) {
    final terms = _meaningfulSearchTerms(
      rawQuery,
    ).map((term) => '"${term.replaceAll('"', '""')}"').toList();
    return terms.join(' OR ');
  }

  List<String> _meaningfulSearchTerms(String rawQuery, {int limit = 12}) {
    const stopWords = <String>{
      'a',
      'about',
      'all',
      'am',
      'an',
      'and',
      'any',
      'are',
      'can',
      'check',
      'did',
      'do',
      'does',
      'for',
      'from',
      'get',
      'got',
      'had',
      'has',
      'have',
      'how',
      'i',
      'in',
      'is',
      'it',
      'me',
      'much',
      'my',
      'of',
      'on',
      'or',
      'please',
      'show',
      'tell',
      'that',
      'the',
      'this',
      'to',
      'was',
      'what',
      'when',
      'where',
      'which',
      'with',
      'you',
    };

    final seen = <String>{};
    final terms = <String>[];
    for (final raw
        in rawQuery
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9@+._\s-]'), ' ')
            .split(RegExp(r'\s+'))) {
      final term = raw.trim();
      if (term.length < 2 || stopWords.contains(term)) continue;
      if (seen.add(term)) terms.add(term);
      if (terms.length >= limit) break;
    }
    return terms;
  }

  Future<String> stableContentHash({
    required String? sourceConnector,
    required String? content,
  }) async {
    final normalized =
        '${sourceConnector ?? 'unknown'}\n${_canonicalContentForDedupe(content ?? '')}';
    final hash = await _sha256.hash(utf8.encode(normalized));
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String _canonicalContentForDedupe(String content) {
    final withoutFileHeader = content.trim().replaceFirst(
      RegExp(r'^File:\s*[^\r\n]+(?:\r?\n){1,2}', caseSensitive: false),
      '',
    );
    final withoutNotificationCount = withoutFileHeader.replaceFirstMapped(
      RegExp(
        r'^(Notification from .+?)\s+\(\d+\s+messages?\)\s*:',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}:',
    );
    return _normalizeContentForHash(withoutNotificationCount);
  }

  bool _shouldDropLowValueEntity(String? sourceConnector, String? content) {
    final source = sourceConnector?.trim().toUpperCase() ?? '';
    if (source != 'CHAT' && source != 'NOTIFICATION') return false;
    final normalized = _normalizeContentForHash(content ?? '');
    return RegExp(
      r'^notification from whatsapp:\s*\d+\s+messages?\s+from\s+\d+\s+chats?$',
    ).hasMatch(normalized);
  }

  String _normalizeContentForHash(String content) {
    return content.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  SyncEvent _entitySyncEvent(Entity entity, String contentHash) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return SyncEvent(
      eventId: 'entity_${contentHash.substring(0, 16)}_$now',
      mutationType: 'INSERT',
      targetTable: 'entities',
      payload: jsonEncode(entity.toJson()),
      status: 'PENDING',
      contentHash: contentHash,
    );
  }

  // --- Graph Ingestions ---
  Future<bool> insertEntity(Entity entity, {bool queueSync = false}) async {
    if (_shouldDropLowValueEntity(entity.sourceConnector, entity.content)) {
      return false;
    }

    final db = await instance.database;
    final computedHash =
        entity.contentHash ??
        await stableContentHash(
          sourceConnector: entity.sourceConnector,
          content: entity.content,
        );
    final entityWithHash = Entity(
      id: entity.id,
      entityType: entity.entityType,
      sourceConnector: entity.sourceConnector ?? 'unknown',
      content: entity.content,
      contentHash: computedHash,
      createdAt: entity.createdAt,
      updatedAt: entity.updatedAt,
      isSynced: entity.isSynced,
    );

    var inserted = false;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'entities',
        columns: ['id'],
        where: 'source_connector = ? AND content_hash = ?',
        whereArgs: [entityWithHash.sourceConnector, computedHash],
        limit: 1,
      );
      if (existing.isNotEmpty) return;

      final canonicalContent = _canonicalContentForDedupe(
        entityWithHash.content ?? '',
      );
      if (canonicalContent.isNotEmpty) {
        final legacyMatches = await txn.query(
          'entities',
          columns: ['id', 'content'],
          where: 'COALESCE(source_connector, ?) = ?',
          whereArgs: ['unknown', entityWithHash.sourceConnector],
        );
        final hasLegacyMatch = legacyMatches.any(
          (row) =>
              _canonicalContentForDedupe(row['content']?.toString() ?? '') ==
              canonicalContent,
        );
        if (hasLegacyMatch) return;
      }

      await txn.insert('entities', entityWithHash.toJson());
      inserted = true;
      await txn.delete(
        'entities_fts',
        where: 'entity_id = ?',
        whereArgs: [entityWithHash.id],
      );
      if (entityWithHash.content?.trim().isNotEmpty ?? false) {
        await txn.insert('entities_fts', {
          'entity_id': entityWithHash.id,
          'content': entityWithHash.content,
        });
      }
      if (queueSync) {
        await txn.insert(
          'sync_events',
          _entitySyncEvent(entityWithHash, computedHash).toJson(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
    return inserted;
  }

  Future<void> deleteEntity(String id) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await _deleteSyncEventsForEntity(txn, id);
      await txn.delete('entities', where: 'id = ?', whereArgs: [id]);
      await txn.delete('entities_fts', where: 'entity_id = ?', whereArgs: [id]);
    });
  }

  Future<Entity?> getEntityById(String id) async {
    final db = await instance.database;
    final rows = await db.query(
      'entities',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Entity.fromJson(rows.single);
  }

  Future<List<Entity>> getEntitiesByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final db = await instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      'entities',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    final byId = {
      for (final row in rows) row['id']?.toString() ?? '': Entity.fromJson(row),
    };
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Future<void> upsertFinancialTransaction({
    required FinancialTransaction transaction,
    required String evidenceEntityId,
    required double confidence,
  }) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.insert(
        'financial_transactions',
        transaction.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'financial_transaction_evidence',
        {
          'transaction_id': transaction.id,
          'entity_id': evidenceEntityId,
          'source_connector': transaction.sourceConnector,
          'confidence': confidence,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
  }

  Future<List<FinancialTransaction>> getFinancialTransactionsBetween({
    required int startAt,
    required int endAt,
    String direction = 'debit',
  }) async {
    final db = await instance.database;
    final rows = await db.query(
      'financial_transactions',
      where: 'occurred_at >= ? AND occurred_at < ? AND direction = ?',
      whereArgs: [startAt, endAt, direction],
      orderBy: 'occurred_at ASC',
    );
    return rows.map(FinancialTransaction.fromJson).toList();
  }

  Future<List<Map<String, dynamic>>>
  getFinancialTransactionsWithEvidenceBetween({
    required int startAt,
    required int endAt,
    String direction = 'debit',
  }) async {
    final db = await instance.database;
    final transactions = await db.query(
      'financial_transactions',
      where: 'occurred_at >= ? AND occurred_at < ? AND direction = ?',
      whereArgs: [startAt, endAt, direction],
      orderBy: 'occurred_at ASC',
    );
    final rows = <Map<String, dynamic>>[];
    for (final transaction in transactions) {
      final evidenceRows = await db.rawQuery(
        '''
        SELECT fte.entity_id, e.content AS evidence_content, e.entity_type, e.source_connector AS evidence_source
        FROM financial_transaction_evidence fte
        LEFT JOIN entities e ON e.id = fte.entity_id
        WHERE fte.transaction_id = ?
        ORDER BY fte.confidence DESC, fte.created_at ASC
        LIMIT 1
        ''',
        [transaction['id']],
      );
      rows.add({
        ...transaction,
        if (evidenceRows.isNotEmpty) ...evidenceRows.first,
      });
    }
    return rows;
  }

  Future<List<String>> getFinancialTransactionEvidenceIds(String id) async {
    final db = await instance.database;
    final rows = await db.query(
      'financial_transaction_evidence',
      columns: ['entity_id'],
      where: 'transaction_id = ?',
      whereArgs: [id],
      orderBy: 'confidence DESC, created_at ASC',
    );
    return rows
        .map((row) => row['entity_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  Future<EntityDedupeResult> deduplicateEntities() async {
    final db = await instance.database;
    final rows = await db.query(
      'entities',
      orderBy: 'created_at ASC, updated_at ASC',
    );
    final seenKeys = <String, String>{};
    final duplicateIds = <String>[];
    final backfillById = <String, _EntityHashBackfill>{};

    for (final row in rows) {
      final id = row['id']?.toString();
      if (id == null || id.isEmpty) continue;

      final content = row['content']?.toString() ?? '';
      final sourceConnector =
          row['source_connector']?.toString().trim().isNotEmpty == true
          ? row['source_connector'].toString().trim()
          : 'unknown';
      if (_shouldDropLowValueEntity(sourceConnector, content)) {
        duplicateIds.add(id);
        continue;
      }

      final canonicalContent = _canonicalContentForDedupe(content);
      if (canonicalContent.isEmpty) continue;

      final contentHash = await stableContentHash(
        sourceConnector: sourceConnector,
        content: canonicalContent,
      );
      final key = '$sourceConnector\n$contentHash';

      if (seenKeys.containsKey(key)) {
        duplicateIds.add(id);
      } else {
        seenKeys[key] = id;
        backfillById[id] = _EntityHashBackfill(
          sourceConnector: sourceConnector,
          contentHash: contentHash,
        );
      }
    }

    var removed = 0;
    var hashesBackfilled = 0;
    await db.transaction((txn) async {
      for (final id in duplicateIds) {
        await txn.delete(
          'entities_fts',
          where: 'entity_id = ?',
          whereArgs: [id],
        );
        await _deleteSyncEventsForEntity(txn, id);
        removed += await txn.delete(
          'entities',
          where: 'id = ?',
          whereArgs: [id],
        );
      }

      for (final entry in backfillById.entries) {
        final backfill = entry.value;
        hashesBackfilled += await txn.update(
          'entities',
          {
            'source_connector': backfill.sourceConnector,
            'content_hash': backfill.contentHash,
          },
          where:
              'id = ? AND (content_hash IS NULL OR content_hash <> ? OR source_connector IS NULL OR source_connector <> ?)',
          whereArgs: [
            entry.key,
            backfill.contentHash,
            backfill.sourceConnector,
          ],
        );
      }
    });

    return EntityDedupeResult(
      scanned: rows.length,
      removed: removed,
      hashesBackfilled: hashesBackfilled,
    );
  }

  Future<void> _deleteSyncEventsForEntity(Transaction txn, String id) async {
    await txn.delete(
      'sync_events',
      where: 'target_table = ? AND instr(payload, ?) > 0',
      whereArgs: ['entities', '"id":"$id"'],
    );
  }

  Future<List<Entity>> getAllEntities({
    String? typeFilter,
    String? searchQuery,
  }) async {
    final db = await instance.database;
    List<Map<String, dynamic>> maps;

    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      try {
        maps = await db.rawQuery(
          '''
          SELECT e.* 
          FROM entities_fts fts
          JOIN entities e ON fts.entity_id = e.id
          WHERE fts.content MATCH ?
          ORDER BY e.created_at DESC
        ''',
          [_buildFtsQuery(searchQuery)],
        );
      } on DatabaseException {
        maps = [];
      }
    } else {
      if (typeFilter != null && typeFilter != 'All') {
        maps = await db.query(
          'entities',
          where: 'entity_type = ? OR source_connector = ?',
          whereArgs: [typeFilter, typeFilter],
          orderBy: 'created_at DESC',
        );
      } else {
        maps = await db.query('entities', orderBy: 'created_at DESC');
      }
    }

    return List.generate(maps.length, (i) => Entity.fromJson(maps[i]));
  }

  Future<List<Entity>> getEntitiesCreatedBetween({
    required int startAt,
    required int endAt,
    List<String> sourceConnectors = const [],
  }) async {
    final db = await instance.database;
    final where = <String>['created_at >= ?', 'created_at < ?'];
    final args = <Object>[startAt, endAt];

    if (sourceConnectors.isNotEmpty) {
      final placeholders = List.filled(sourceConnectors.length, '?').join(',');
      where.add('source_connector IN ($placeholders)');
      args.addAll(sourceConnectors);
    }

    final maps = await db.query(
      'entities',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'created_at ASC',
    );

    return List.generate(maps.length, (i) => Entity.fromJson(maps[i]));
  }

  Future<List<Entity>> searchEntitiesForQuery(
    String query, {
    List<String> sourceConnectors = const [],
    int? startAt,
    int? endAt,
    int limit = 30,
  }) async {
    final db = await instance.database;
    final ftsQuery = _buildFtsAnyQuery(query);
    if (ftsQuery.isEmpty) return [];

    final filters = <String>['fts.content MATCH ?'];
    final args = <Object>[ftsQuery];

    if (startAt != null) {
      filters.add('e.created_at >= ?');
      args.add(startAt);
    }
    if (endAt != null) {
      filters.add('e.created_at < ?');
      args.add(endAt);
    }
    if (sourceConnectors.isNotEmpty) {
      final placeholders = List.filled(sourceConnectors.length, '?').join(',');
      filters.add('e.source_connector IN ($placeholders)');
      args.addAll(sourceConnectors);
    }
    args.add(limit);

    try {
      final rows = await db.rawQuery('''
        SELECT DISTINCT e.*
        FROM entities_fts fts
        JOIN entities e ON fts.entity_id = e.id
        WHERE ${filters.join(' AND ')}
        ORDER BY e.created_at DESC
        LIMIT ?
      ''', args);
      return List.generate(
        rows.length,
        (index) => Entity.fromJson(rows[index]),
      );
    } on DatabaseException {
      return _searchEntitiesByLike(
        query,
        sourceConnectors: sourceConnectors,
        startAt: startAt,
        endAt: endAt,
        limit: limit,
      );
    }
  }

  Future<List<Entity>> _searchEntitiesByLike(
    String query, {
    List<String> sourceConnectors = const [],
    int? startAt,
    int? endAt,
    int limit = 30,
  }) async {
    final db = await instance.database;
    final terms = _meaningfulSearchTerms(query, limit: 6);
    if (terms.isEmpty) return [];

    final where = <String>[];
    final args = <Object>[];
    if (startAt != null) {
      where.add('created_at >= ?');
      args.add(startAt);
    }
    if (endAt != null) {
      where.add('created_at < ?');
      args.add(endAt);
    }
    if (sourceConnectors.isNotEmpty) {
      final placeholders = List.filled(sourceConnectors.length, '?').join(',');
      where.add('source_connector IN ($placeholders)');
      args.addAll(sourceConnectors);
    }
    where.add(
      '(${List.filled(terms.length, 'LOWER(content) LIKE ?').join(' OR ')})',
    );
    args.addAll(terms.map((term) => '%$term%'));

    final rows = await db.query(
      'entities',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return List.generate(rows.length, (index) => Entity.fromJson(rows[index]));
  }

  Future<List<Edge>> getEdgesForEntity(String entityId) async {
    final db = await instance.database;
    final maps = await db.query(
      'edges',
      where: 'source_id = ? OR target_id = ?',
      whereArgs: [entityId, entityId],
    );
    return List.generate(maps.length, (i) => Edge.fromJson(maps[i]));
  }

  Future<void> insertEdge(Edge edge) async {
    final db = await instance.database;
    await db.insert(
      'edges',
      edge.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // --- sqlite-vec Query Mock & Fallback ---
  Future<void> insertEmbedding(
    String entityId,
    List<double> vectorValues,
  ) async {
    final db = await instance.database;
    final bytes = Float32List.fromList(vectorValues).buffer.asUint8List();
    try {
      await db.rawInsert(
        'INSERT OR REPLACE INTO embeddings (entity_id, embedding) VALUES (?, ?)',
        [entityId, bytes],
      );
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> searchEmbeddingsCosine(
    List<double> queryVector,
  ) async {
    final db = await instance.database;
    // C-extension sqlite-vec syntax
    try {
      final bytes = Float32List.fromList(queryVector).buffer.asUint8List();
      final results = await db.rawQuery(
        '''
        SELECT entity_id, vec_distance_cosine(embedding, ?) as distance
        FROM embeddings
        ORDER BY distance ASC
        LIMIT 10
      ''',
        [bytes],
      );
      return results;
    } catch (_) {
      // Return empty list if vec0 is not compiled on mock simulator environment
      return [];
    }
  }

  // --- Graph Traversal using Recursive CTEs ---
  Future<List<Map<String, dynamic>>> traverseGraphRecursive(
    String startEntityId, {
    int maxDepth = 3,
  }) async {
    final db = await instance.database;

    // Breadth-First search across edges and nodes completely offline
    final results = await db.rawQuery(
      '''
      WITH RECURSIVE graph_walk(entity_id, depth) AS (
          SELECT ? as entity_id, 0 as depth
          UNION
          SELECT CASE
              WHEN e.source_id = gw.entity_id THEN e.target_id
              ELSE e.source_id
            END,
            gw.depth + 1
          FROM edges e
          JOIN graph_walk gw
            ON e.source_id = gw.entity_id OR e.target_id = gw.entity_id
          WHERE gw.depth < ?
      )
      SELECT gw.entity_id, gw.depth, ent.entity_type, ent.content, ent.source_connector
      FROM graph_walk gw
      JOIN entities ent ON gw.entity_id = ent.id
    ''',
      [startEntityId, maxDepth],
    );

    return results;
  }

  // --- Ingestion Sync Events ---
  Future<void> insertSyncEvent(SyncEvent event) async {
    final db = await instance.database;
    await db.insert(
      'sync_events',
      event.toJson(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<SyncEvent>> getPendingSyncEvents() async {
    final db = await instance.database;
    final maps = await db.query('sync_events', where: "status = 'PENDING'");
    return List.generate(maps.length, (i) => SyncEvent.fromJson(maps[i]));
  }

  // --- Legacy helpers adapted to the new Entity graph schema ---
  Future<List<Map<String, dynamic>>> searchDocumentsFTS(String query) async {
    final db = await instance.database;
    try {
      final results = await db.rawQuery(
        '''
        SELECT entity_id, content
        FROM entities_fts
        WHERE content MATCH ?
        LIMIT 10
      ''',
        [_buildFtsQuery(query)],
      );
      return results;
    } on DatabaseException {
      return [];
    }
  }

  Future<SearchIndexMaintenanceResult?> ensureSearchIndexFresh({
    Duration minInterval = const Duration(minutes: 5),
  }) async {
    final now = DateTime.now();
    final lastRepair = _lastSearchIndexRepair;
    if (lastRepair != null && now.difference(lastRepair) < minInterval) {
      return null;
    }
    _lastSearchIndexRepair = now;
    return repairSearchIndex();
  }

  Future<SearchIndexMaintenanceResult> repairSearchIndex() async {
    final db = await instance.database;
    var inserted = 0;
    var updated = 0;
    var deleted = 0;

    await db.transaction((txn) async {
      deleted += await txn.rawDelete('''
        DELETE FROM entities_fts
        WHERE entity_id NOT IN (SELECT id FROM entities)
      ''');

      final rows = await txn.rawQuery('''
        SELECT e.id, e.content, fts.content AS fts_content
        FROM entities e
        LEFT JOIN entities_fts fts ON fts.entity_id = e.id
        WHERE e.content IS NOT NULL AND TRIM(e.content) <> ''
      ''');

      for (final row in rows) {
        final entityId = row['id']?.toString();
        final content = row['content']?.toString();
        final indexedContent = row['fts_content']?.toString();
        if (entityId == null || entityId.isEmpty || content == null) continue;

        if (indexedContent == null) {
          await txn.insert('entities_fts', {
            'entity_id': entityId,
            'content': content,
          });
          inserted += 1;
          continue;
        }

        if (indexedContent != content) {
          await txn.delete(
            'entities_fts',
            where: 'entity_id = ?',
            whereArgs: [entityId],
          );
          await txn.insert('entities_fts', {
            'entity_id': entityId,
            'content': content,
          });
          updated += 1;
        }
      }
    });

    return SearchIndexMaintenanceResult(
      inserted: inserted,
      updated: updated,
      deleted: deleted,
    );
  }

  Future<List<Map<String, dynamic>>> searchMemoriesFTS(String query) async {
    final db = await instance.database;
    try {
      final results = await db.rawQuery(
        '''
        SELECT e.id as memory_id, e.entity_type as type, fts.content
        FROM entities_fts fts
        JOIN entities e ON fts.entity_id = e.id
        WHERE fts.content MATCH ?
        LIMIT 10
      ''',
        [_buildFtsQuery(query)],
      );
      return results;
    } on DatabaseException {
      return [];
    }
  }

  Future<void> upsertContactAlias(
    String alias,
    ContactCandidate contact,
  ) async {
    final normalizedAlias = _normalizeAlias(alias);
    if (normalizedAlias.isEmpty) return;

    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('contact_aliases', {
      'alias': normalizedAlias,
      'contact_id': contact.id,
      'display_name': contact.displayName,
      'phone_number': contact.phoneNumber,
      'normalized_phone_number': contact.normalizedPhoneNumber,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<ContactCandidate?> getContactAlias(String alias) async {
    final normalizedAlias = _normalizeAlias(alias);
    if (normalizedAlias.isEmpty) return null;

    final db = await instance.database;
    final rows = await db.query(
      'contact_aliases',
      where: 'alias = ?',
      whereArgs: [normalizedAlias],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final row = rows.single;
    return ContactCandidate(
      id: row['contact_id']?.toString() ?? '',
      displayName: row['display_name']?.toString() ?? '',
      phoneNumber: row['phone_number']?.toString() ?? '',
      normalizedPhoneNumber: row['normalized_phone_number']?.toString() ?? '',
      source: 'alias',
    );
  }

  Future<Map<String, dynamic>?> getContactProfile(String contactKey) async {
    final db = await instance.database;
    final rows = await db.query(
      'contact_profiles',
      where: 'contact_key = ?',
      whereArgs: [contactKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> upsertContactProfile(
    ContactCandidate contact, {
    required RelationshipType relationshipType,
    required MessageTone preferredTone,
    required MessageLanguage languagePreference,
  }) async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('contact_profiles', {
      'contact_key': contactProfileKey(contact),
      'display_name': contact.safeLabel,
      'relationship_type': relationshipType.name,
      'preferred_tone': preferredTone.name,
      'language_preference': languagePreference.name,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertManualRecipient(ContactCandidate recipient) async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('manual_recipients', {
      'id': contactProfileKey(recipient),
      'alias': recipient.displayName.trim().isEmpty
          ? null
          : _normalizeAlias(recipient.displayName),
      'display_name': recipient.safeLabel,
      'recipient_kind': recipient.recipientKind.name,
      'phone_number': recipient.phoneNumber,
      'normalized_phone_number': recipient.normalizedPhoneNumber,
      'email_address': recipient.emailAddress,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getDatasourcePreferences() async {
    final db = await instance.database;
    await _seedDatasourcePreferences(db);
    return db.query('datasource_preferences', orderBy: 'display_name ASC');
  }

  Future<void> setDatasourcePreference(String sourceId, bool isEnabled) async {
    final db = await instance.database;
    await db.update(
      'datasource_preferences',
      {
        'is_enabled': isEnabled ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
  }

  Future<bool> isDatasourceEnabled(String sourceId) async {
    final db = await instance.database;
    await _seedDatasourcePreferences(db);
    final rows = await db.query(
      'datasource_preferences',
      columns: ['is_enabled'],
      where: 'source_id = ?',
      whereArgs: [sourceId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return rows.single['is_enabled'] == 1;
  }

  Future<Map<String, dynamic>?> getDatasourceSyncState(String sourceId) async {
    final db = await instance.database;
    final rows = await db.query(
      'datasource_sync_state',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  Future<List<Map<String, dynamic>>> getDatasourceSyncStates() async {
    final db = await instance.database;
    return db.query('datasource_sync_state', orderBy: 'source_id ASC');
  }

  Future<void> markDatasourceSyncStarted({
    required String sourceId,
    required int startedAt,
    int? nextScheduledAt,
  }) async {
    final db = await instance.database;
    await db.insert('datasource_sync_state', {
      'source_id': sourceId,
      'last_started_at': startedAt,
      'next_scheduled_at': nextScheduledAt,
      'updated_at': startedAt,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update(
      'datasource_sync_state',
      {
        'last_started_at': startedAt,
        'next_scheduled_at': ?nextScheduledAt,
        'updated_at': startedAt,
      },
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
  }

  Future<void> markDatasourceSyncSuccess({
    required String sourceId,
    required int finishedAt,
    required int totalRead,
    required int imported,
    required int skippedDuplicates,
    String? nativeCursor,
    int? nextScheduledAt,
  }) async {
    final db = await instance.database;
    await db.insert('datasource_sync_state', {
      'source_id': sourceId,
      'last_started_at': finishedAt,
      'last_success_at': finishedAt,
      'last_native_cursor': nativeCursor,
      'total_read': totalRead,
      'imported': imported,
      'skipped_duplicates': skippedDuplicates,
      'last_error': null,
      'next_scheduled_at': nextScheduledAt,
      'updated_at': finishedAt,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update(
      'datasource_sync_state',
      {
        'last_success_at': finishedAt,
        'last_native_cursor': nativeCursor,
        'total_read': totalRead,
        'imported': imported,
        'skipped_duplicates': skippedDuplicates,
        'last_error': null,
        'next_scheduled_at': ?nextScheduledAt,
        'updated_at': finishedAt,
      },
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
  }

  Future<void> markDatasourceSyncFailure({
    required String sourceId,
    required int finishedAt,
    required String error,
    int? nextScheduledAt,
  }) async {
    final db = await instance.database;
    await db.insert('datasource_sync_state', {
      'source_id': sourceId,
      'last_started_at': finishedAt,
      'last_error': error,
      'next_scheduled_at': nextScheduledAt,
      'updated_at': finishedAt,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update(
      'datasource_sync_state',
      {
        'last_error': error,
        'next_scheduled_at': ?nextScheduledAt,
        'updated_at': finishedAt,
      },
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
  }

  Future<AppUnlockPolicy> getAppUnlockPolicy() async {
    final db = await instance.database;
    final rows = await db.query(
      'app_unlock_policy',
      where: 'scope = ?',
      whereArgs: ['default'],
      limit: 1,
    );
    final policyName = rows.isEmpty ? null : rows.single['policy']?.toString();
    return AppUnlockPolicy.values.firstWhere(
      (policy) => policy.name == policyName,
      orElse: () => AppUnlockPolicy.unlockEachTime,
    );
  }

  Future<void> setAppUnlockPolicy(AppUnlockPolicy policy) async {
    final db = await instance.database;
    await db.insert('app_unlock_policy', {
      'scope': 'default',
      'policy': policy.name,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> recordMessageDraft(PhoneActionPlan plan) async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('message_drafts', {
      'id': '${plan.id}_draft',
      'action_id': plan.id,
      'raw_command': plan.rawCommand,
      'detected_intent': plan.intent,
      'detected_language': plan.language.name,
      'tone': plan.tone.name,
      'drafted_text': plan.draftText ?? plan.messageBody,
      'final_text': plan.finalText,
      'email_subject': plan.emailSubject,
      'created_at': plan.createdAt.millisecondsSinceEpoch,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  String contactProfileKey(ContactCandidate contact) {
    if (contact.recipientKind == RecipientKind.manualEmail ||
        contact.emailAddress.isNotEmpty &&
            contact.normalizedPhoneNumber.isEmpty) {
      return 'email:${contact.emailAddress.trim().toLowerCase()}';
    }
    if (contact.normalizedPhoneNumber.isNotEmpty) {
      return 'phone:${contact.normalizedPhoneNumber}';
    }
    return 'contact:${contact.id}';
  }

  Future<void> recordActionAudit(
    PhoneActionPlan plan,
    PhoneActionStatus status, {
    String? resultText,
  }) async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('action_audit', {
      'id': plan.id,
      'action_type': plan.type.name,
      'status': status.name,
      'risk': plan.risk.name,
      'target_app': plan.targetApp,
      'recipient_label': plan.contact?.safeLabel ?? plan.recipientQuery,
      'payload_json': plan.encodeForAudit(),
      'result_text': resultText,
      'created_at': plan.createdAt.millisecondsSinceEpoch,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getRecentActionAudit({
    int limit = 20,
  }) async {
    final db = await instance.database;
    return db.query('action_audit', orderBy: 'updated_at DESC', limit: limit);
  }

  String _normalizeAlias(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9+ ]'), '')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  // --- CRUD Memories ---
  Future<void> insertMemory(Memory memory) async {
    final db = await instance.database;
    await db.insert('memories', {
      'id': memory.id,
      'entity_id': memory.entityId,
      'memory_type': memory.memoryType,
      'summary': memory.summary,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Memory>> getMemories() async {
    final db = await instance.database;
    final List<Map<String, dynamic>> maps = await db.query('memories');
    return List.generate(maps.length, (i) {
      return Memory(
        id: maps[i]['id'] as String,
        entityId: maps[i]['entity_id'] as String?,
        memoryType: maps[i]['memory_type'] as String,
        summary: maps[i]['summary'] as String,
      );
    });
  }

  // --- Messages & Citations ---
  Future<void> insertMessage(Message message) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.insert('messages', {
        'id': message.id,
        'conversation_id': message.conversationId,
        'sender': message.sender == MessageSender.user ? 'user' : 'agent',
        'text': message.text,
        'timestamp': message.timestamp.toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await txn.delete(
        'citations',
        where: 'message_id = ?',
        whereArgs: [message.id],
      );

      for (var citation in message.citations) {
        await txn.insert('citations', {
          'message_id': message.id,
          'document_id': citation.documentId,
          'title': citation.title,
          'chunk_index': citation.chunkIndex,
        });
      }
    });
  }

  Future<List<Message>> getMessages(String conversationId) async {
    final db = await instance.database;
    final msgMaps = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp ASC',
    );

    List<Message> messages = [];
    for (var m in msgMaps) {
      final citMaps = await db.query(
        'citations',
        where: 'message_id = ?',
        whereArgs: [m['id']],
      );

      final citations = List.generate(
        citMaps.length,
        (i) => Citation.fromJson(citMaps[i]),
      );
      messages.add(
        Message(
          id: m['id'] as String,
          conversationId: m['conversation_id'] as String,
          sender: m['sender'] == 'user'
              ? MessageSender.user
              : MessageSender.agent,
          text: m['text'] as String,
          timestamp: DateTime.parse(m['timestamp'] as String),
          citations: citations,
        ),
      );
    }
    return messages;
  }
}
