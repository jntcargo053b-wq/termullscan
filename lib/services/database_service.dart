// lib/services/database_service.dart
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/scan_entry.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'termulscan.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE scan_entries(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        value TEXT,
        timestamp INTEGER,
        latitude REAL,
        longitude REAL,
        locationName TEXT,
        operatorName TEXT,
        imagePath TEXT,
        videoPath TEXT,
        createdAt INTEGER
      )
    ''');
  }

  // ─── PAGINATION ──────────────────────────────────────────────

  /// Ambil data dengan pagination.
  /// [limit] : jumlah data per halaman (default 50)
  /// [offset] : posisi awal (0 untuk halaman pertama)
  Future<List<ScanEntry>> getEntries({
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await database;
    final result = await db.query(
      'scan_entries',
      orderBy: 'createdAt DESC',
      limit: limit,
      offset: offset,
    );
    return result.map((map) => ScanEntry.fromMap(map)).toList();
  }

  /// Hitung total jumlah data di database (opsional, untuk mengetahui apakah masih ada data lagi).
  Future<int> getTotalCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM scan_entries');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ─── CRUD lainnya ──────────────────────────────────────────

  Future<void> insertEntry(ScanEntry entry) async {
    final db = await database;
    await db.insert('scan_entries', entry.toMap());
  }

  // ... metode lainnya
}
