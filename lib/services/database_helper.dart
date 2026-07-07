import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import '../models/scan_entry.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null && _database!.isOpen) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'scan_log.db');
    return await openDatabase(
      path,
      version: 5, // ⬆️ upgrade ke versi 5
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE scan_entries (
        id TEXT PRIMARY KEY,
        type TEXT,
        value TEXT,
        barcodeFormat TEXT,
        timestamp INTEGER,
        latitude REAL,
        longitude REAL,
        locationName TEXT,
        note TEXT,
        photoPaths TEXT,
        videoPath TEXT,
        videoDuration INTEGER,
        videoThumbnail TEXT,
        galleryExported INTEGER DEFAULT 0,
        videoLocalDeleted INTEGER DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX idx_value ON scan_entries(value)');
    await db.execute('CREATE INDEX idx_timestamp ON scan_entries(timestamp)');
    await db.execute('CREATE INDEX idx_type ON scan_entries(type)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE scan_entries ADD COLUMN photoPaths TEXT');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE scan_entries ADD COLUMN videoPath TEXT');
      await db.execute('ALTER TABLE scan_entries ADD COLUMN videoDuration INTEGER');
      await db.execute('ALTER TABLE scan_entries ADD COLUMN videoThumbnail TEXT');
    }
    // ─── MIGRASI VERSI 3 → 4 ──────────────────────────────
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE scan_entries ADD COLUMN galleryExported INTEGER DEFAULT 0');
      debugPrint('✅ Database migrated to version 4: added galleryExported column');
    }
    // ─── MIGRASI VERSI 4 → 5 ──────────────────────────────
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE scan_entries ADD COLUMN videoLocalDeleted INTEGER DEFAULT 0');
      debugPrint('✅ Database migrated to version 5: added videoLocalDeleted column');
    }
  }

  // ─── Safe operation wrapper ──────────────────────────
  Future<T> _runWithProtection<T>(
    Future<T> Function(DatabaseExecutor db) action, {
    bool useTransaction = false,
  }) async {
    try {
      final db = await database;
      if (useTransaction) {
        return await db.transaction((txn) => action(txn));
      } else {
        return await action(db);
      }
    } on DatabaseException catch (e) {
      debugPrint('❌ Database error: $e');
      rethrow;
    } catch (e) {
      debugPrint('❌ Unexpected database error: $e');
      rethrow;
    }
  }

  // ─── CRUD ──────────────────────────────────────────

  Future<void> insert(ScanEntry entry) async {
    await _runWithProtection((db) async {
      await db.insert('scan_entries', entry.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> insertAll(List<ScanEntry> entries) async {
    await _runWithProtection((db) async {
      for (final entry in entries) {
        await db.insert('scan_entries', entry.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }, useTransaction: true);
  }

  Future<List<ScanEntry>> getAll() async {
    return _runWithProtection((db) async {
      final result = await db.query('scan_entries', orderBy: 'timestamp DESC');
      return result.map((map) => ScanEntry.fromMap(map)).toList();
    });
  }

  Future<ScanEntry?> getEntry(String id) async {
    return _runWithProtection((db) async {
      final result = await db.query('scan_entries',
          where: 'id = ?', whereArgs: [id], limit: 1);
      if (result.isEmpty) return null;
      return ScanEntry.fromMap(result.first);
    });
  }

  Future<List<ScanEntry>> getEntries({
    int limit = 20,
    int offset = 0,
    String? searchQuery,
    String? period,
    String sortField = 'timestamp',
    String sortDir = 'DESC',
  }) async {
    return _runWithProtection((db) async {
      String sql = 'SELECT * FROM scan_entries';
      final List<String> where = [];
      final List<dynamic> args = [];

      if (searchQuery != null && searchQuery.isNotEmpty) {
        where.add('(value LIKE ? OR photoPaths LIKE ? OR videoPath LIKE ? OR note LIKE ? OR locationName LIKE ?)');
        args.add('%$searchQuery%');
        args.add('%$searchQuery%');
        args.add('%$searchQuery%');
        args.add('%$searchQuery%');
        args.add('%$searchQuery%');
      }

      if (period != null && period != 'Semua') {
        final now = DateTime.now();
        DateTime start;
        switch (period) {
          case 'Hari ini':
            start = DateTime(now.year, now.month, now.day);
            break;
          case 'Minggu ini':
            start = now.subtract(Duration(days: now.weekday - 1));
            start = DateTime(start.year, start.month, start.day);
            break;
          case 'Bulan ini':
            start = DateTime(now.year, now.month, 1);
            break;
          default:
            start = DateTime(0);
        }
        where.add('timestamp >= ?');
        args.add(start.millisecondsSinceEpoch);
      }

      if (where.isNotEmpty) {
        sql += ' WHERE ' + where.join(' AND ');
      }

      String orderBy;
      switch (sortField) {
        case 'value':
          orderBy = 'value $sortDir';
          break;
        case 'timestamp':
        default:
          orderBy = 'timestamp $sortDir';
      }
      sql += ' ORDER BY $orderBy LIMIT ? OFFSET ?';
      args.add(limit);
      args.add(offset);

      final maps = await db.rawQuery(sql, args);
      return maps.map((map) => ScanEntry.fromMap(map)).toList();
    });
  }

  Future<int> getCount({
    String? searchQuery,
    String? period,
  }) async {
    return _runWithProtection((db) async {
      String sql = 'SELECT COUNT(*) as count FROM scan_entries';
      final List<String> where = [];
      final List<dynamic> args = [];

      if (searchQuery != null && searchQuery.isNotEmpty) {
        where.add('(value LIKE ? OR photoPaths LIKE ? OR videoPath LIKE ? OR note LIKE ? OR locationName LIKE ?)');
        args.add('%$searchQuery%');
        args.add('%$searchQuery%');
        args.add('%$searchQuery%');
        args.add('%$searchQuery%');
        args.add('%$searchQuery%');
      }

      if (period != null && period != 'Semua') {
        final now = DateTime.now();
        DateTime start;
        switch (period) {
          case 'Hari ini':
            start = DateTime(now.year, now.month, now.day);
            break;
          case 'Minggu ini':
            start = now.subtract(Duration(days: now.weekday - 1));
            start = DateTime(start.year, start.month, start.day);
            break;
          case 'Bulan ini':
            start = DateTime(now.year, now.month, 1);
            break;
          default:
            start = DateTime(0);
        }
        where.add('timestamp >= ?');
        args.add(start.millisecondsSinceEpoch);
      }

      if (where.isNotEmpty) {
        sql += ' WHERE ' + where.join(' AND ');
      }

      final result = await db.rawQuery(sql, args);
      return result.first['count'] as int;
    });
  }

  Future<void> delete(String id) async {
    await _runWithProtection((db) async {
      await db.delete('scan_entries', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> deleteAll() async {
    await _runWithProtection((db) async {
      await db.delete('scan_entries');
    }, useTransaction: true);
  }

  Future<void> update(ScanEntry entry) async {
    await _runWithProtection((db) async {
      await db.update('scan_entries', entry.toMap(),
          where: 'id = ?', whereArgs: [entry.id]);
    });
  }

  Future<void> migrateFromJson(List<ScanEntry> entries) async {
    await _runWithProtection((db) async {
      for (final entry in entries) {
        await db.insert('scan_entries', entry.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }, useTransaction: true);
  }

  Future<void> close() async {
    final db = _database;
    if (db != null && db.isOpen) {
      await db.close();
      _database = null;
    }
  }
}
