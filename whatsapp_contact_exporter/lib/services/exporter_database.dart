import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/export_models.dart';

class ExporterCounts {
  const ExporterCounts({
    required this.contacts,
    required this.groups,
    required this.groupMembers,
    required this.exports,
  });

  final int contacts;
  final int groups;
  final int groupMembers;
  final int exports;
}

class ExporterDatabase {
  ExporterDatabase({FlutterSecureStorage? secureStorage, Uuid? uuid})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
      _uuid = uuid ?? const Uuid();

  static const _databaseName = 'wa_group_extractor_v1.db';
  static const _passwordKey = 'wa_group_extractor_db_password';

  final FlutterSecureStorage _secureStorage;
  final Uuid _uuid;
  Database? _database;

  Future<Database> get _db async {
    final existing = _database;
    if (existing != null) {
      return existing;
    }
    final directory = await getApplicationDocumentsDirectory();
    final password = await _databasePassword();
    final database = await openDatabase(
      p.join(directory.path, _databaseName),
      password: password,
      version: 2,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.rawQuery('PRAGMA journal_mode = WAL');
        await db.rawQuery('PRAGMA secure_delete = ON');
      },
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
    );
    _database = database;
    return database;
  }

  Future<String> _databasePassword() async {
    final existing = await _secureStorage.read(key: _passwordKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final password = _uuid.v4() + _uuid.v4();
    await _secureStorage.write(key: _passwordKey, value: password);
    return password;
  }

  Future<void> _createSchema(Database db, int version) async {
    await _createExtractionRunsTable(db);
    await db.execute('''
      CREATE TABLE contacts (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT NOT NULL DEFAULT '',
        email TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL,
        normalized_phone TEXT NOT NULL DEFAULT '',
        tags TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX contacts_normalized_phone_idx ON contacts(normalized_phone)',
    );
    await db.execute('''
      CREATE TABLE groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        captured_at TEXT NOT NULL,
        source_account_label TEXT NOT NULL DEFAULT '',
        whatsapp_id TEXT NOT NULL DEFAULT '',
        extraction_run_id TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute(
      'CREATE INDEX groups_extraction_run_id_idx ON groups(extraction_run_id)',
    );
    await db.execute('''
      CREATE TABLE group_members (
        id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
        display_name TEXT NOT NULL,
        phone TEXT NOT NULL DEFAULT '',
        normalized_phone TEXT NOT NULL DEFAULT '',
        role TEXT NOT NULL DEFAULT 'unknown',
        confidence TEXT NOT NULL DEFAULT 'low',
        source TEXT NOT NULL,
        whatsapp_id TEXT NOT NULL DEFAULT '',
        phone_visibility TEXT NOT NULL DEFAULT 'visible',
        is_admin INTEGER NOT NULL DEFAULT 0,
        extraction_run_id TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute(
      'CREATE INDEX group_members_group_id_idx ON group_members(group_id)',
    );
    await db.execute(
      'CREATE INDEX group_members_normalized_phone_idx ON group_members(normalized_phone)',
    );
    await db.execute(
      'CREATE INDEX group_members_extraction_run_id_idx ON group_members(extraction_run_id)',
    );
    await db.execute('''
      CREATE TABLE exports (
        id TEXT PRIMARY KEY,
        export_type TEXT NOT NULL,
        path TEXT NOT NULL,
        row_count INTEGER NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createExtractionRunsTable(db);
      await _addColumnIfMissing(
        db,
        'groups',
        'whatsapp_id',
        "TEXT NOT NULL DEFAULT ''",
      );
      await _addColumnIfMissing(
        db,
        'groups',
        'extraction_run_id',
        "TEXT NOT NULL DEFAULT ''",
      );
      await _addColumnIfMissing(
        db,
        'group_members',
        'whatsapp_id',
        "TEXT NOT NULL DEFAULT ''",
      );
      await _addColumnIfMissing(
        db,
        'group_members',
        'phone_visibility',
        "TEXT NOT NULL DEFAULT 'visible'",
      );
      await _addColumnIfMissing(
        db,
        'group_members',
        'is_admin',
        'INTEGER NOT NULL DEFAULT 0',
      );
      await _addColumnIfMissing(
        db,
        'group_members',
        'extraction_run_id',
        "TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS groups_extraction_run_id_idx ON groups(extraction_run_id)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS group_members_extraction_run_id_idx ON group_members(extraction_run_id)',
      );
    }
  }

  Future<void> _createExtractionRunsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS extraction_runs (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        status TEXT NOT NULL,
        started_at TEXT NOT NULL,
        finished_at TEXT NOT NULL DEFAULT '',
        selected_group_count INTEGER NOT NULL DEFAULT 0,
        member_count INTEGER NOT NULL DEFAULT 0,
        error TEXT NOT NULL DEFAULT ''
      )
    ''');
  }

  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((row) => row['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  Future<void> upsertContacts(List<ExportedContact> contacts) async {
    if (contacts.isEmpty) {
      return;
    }
    final db = await _db;
    await db.transaction((txn) async {
      for (final contact in contacts) {
        await txn.insert('contacts', {
          ...contact.toJson(),
          'normalized_phone': contact.normalizedPhone,
          'created_at': contact.createdAt.toIso8601String(),
          'tags': jsonEncode(contact.tags),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> insertGroupWithMembers(
    WhatsAppGroup group,
    List<GroupMember> members,
  ) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert('groups', group.toJson());
      for (final member in members) {
        await txn.insert('group_members', member.toJson());
      }
    });
  }

  Future<void> insertExtractionRunWithGroups({
    required ExtractionRun run,
    required List<WhatsAppGroup> groups,
    required List<GroupMember> members,
  }) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert('extraction_runs', run.toJson());
      for (final group in groups) {
        await txn.insert('groups', group.toJson());
      }
      for (final member in members) {
        await txn.insert('group_members', member.toJson());
      }
    });
  }

  Future<List<ExportedContact>> contacts() async {
    final rows = await (await _db).query(
      'contacts',
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(ExportedContact.fromJson).toList();
  }

  Future<List<WhatsAppGroup>> groups() async {
    final rows = await (await _db).query('groups', orderBy: 'captured_at DESC');
    return rows.map(WhatsAppGroup.fromJson).toList();
  }

  Future<List<GroupMember>> groupMembers() async {
    final rows = await (await _db).query(
      'group_members',
      orderBy: 'display_name COLLATE NOCASE',
    );
    return rows.map(GroupMember.fromJson).toList();
  }

  Future<List<ExtractionRun>> extractionRuns() async {
    final rows = await (await _db).query(
      'extraction_runs',
      orderBy: 'started_at DESC',
    );
    return rows.map(ExtractionRun.fromJson).toList();
  }

  Future<void> insertExportRecord(ExportRecord record) async {
    await (await _db).insert('exports', record.toJson());
  }

  Future<List<ExportRecord>> exports() async {
    final rows = await (await _db).query('exports', orderBy: 'created_at DESC');
    return rows.map(ExportRecord.fromJson).toList();
  }

  Future<ExporterCounts> counts() async {
    final db = await _db;
    Future<int> count(String table) async {
      final result = await db.rawQuery('SELECT COUNT(*) AS count FROM $table');
      return Sqflite.firstIntValue(result) ?? 0;
    }

    return ExporterCounts(
      contacts: await count('contacts'),
      groups: await count('groups'),
      groupMembers: await count('group_members'),
      exports: await count('exports'),
    );
  }
}
