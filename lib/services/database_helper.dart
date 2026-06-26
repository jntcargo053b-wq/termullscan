// ============================================================
// lib/services/database_helper.dart (FINAL)
// ============================================================
import 'dart:async';
import 'dart:io';
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
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'scan_log.db');
    return await openDatabase(
      path,
      version: 2,
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
        photoPaths TEXT
      )
    ''');
    await db.execute('CREATE INDEX idx_value ON scan_entries(value)');
    await db.execute('CREATE INDEX idx_timestamp ON scan_entries(timestamp)');
    await db.execute('CREATE INDEX idx_type ON scan_entries(type)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Tambahkan kolom photoPaths untuk migrasi dari versi 1 ke 2
      await db.execute('ALTER TABLE scan_entries ADD COLUMN photoPaths TEXT');
    }
  }

  // ─── CRUD ──────────────────────────────────────────

  Future<void> insert(ScanEntry entry) async {
    final db = await database;
    await db.insert('scan_entries', entry.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> insertAll(List<ScanEntry> entries) async {
    final db = await database;
    final batch = db.batch();
    for (var entry in entries) {
      batch.insert('scan_entries', entry.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit();
  }

  Future<List<ScanEntry>> getAll() async {
    final db = await database;
    final result = await db.query('scan_entries',
        orderBy: 'timestamp DESC', limit: 10000);
    return result.map((map) => ScanEntry.fromMap(map)).toList();
  }

  Future<ScanEntry?> getEntry(String id) async {
    final db = await database;
    final result = await db.query('scan_entries',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (result.isEmpty) return null;
    return ScanEntry.fromMap(result.first);
  }

  Future<List<ScanEntry>> getEntries({
    int limit = 20,
    int offset = 0,
    String? searchQuery,
    String? period,
  }) async {
    final db = await database;
    String sql = 'SELECT * FROM scan_entries';
    final List<String> where = [];
    final List<dynamic> args = [];

    if (searchQuery != null && searchQuery.isNotEmpty) {
      where.add('value LIKE ?');
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

    sql += ' ORDER BY timestamp DESC LIMIT ? OFFSET ?';
    args.add(limit);
    args.add(offset);

    final List<Map<String, dynamic>> maps = await db.rawQuery(sql, args);
    return maps.map((map) => ScanEntry.fromMap(map)).toList();
  }

  Future<int> getCount({
    String? searchQuery,
    String? period,
  }) async {
    final db = await database;
    String sql = 'SELECT COUNT(*) as count FROM scan_entries';
    final List<String> where = [];
    final List<dynamic> args = [];

    if (searchQuery != null && searchQuery.isNotEmpty) {
      where.add('value LIKE ?');
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
  }

  Future<void> delete(String id) async {
    final db = await database;
    await db.delete('scan_entries', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteAll() async {
    final db = await database;
    await db.delete('scan_entries');
  }

  Future<void> update(ScanEntry entry) async {
    final db = await database;
    await db.update('scan_entries', entry.toMap(),
        where: 'id = ?', whereArgs: [entry.id]);
  }

  // ─── MIGRASI ──────────────────────────────────────

  Future<void> migrateFromJson(List<ScanEntry> entries) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var entry in entries) {
        await txn.insert('scan_entries', entry.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }
}
