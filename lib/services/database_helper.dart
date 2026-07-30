import 'dart:async';
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
      version: 6, // ⬆️ upgrade ke versi 6: tambah kolom yang dipakai ScanEntry.toMap()
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
        videoLocalDeleted INTEGER DEFAULT 0,
        imagePath TEXT,
        operatorName TEXT DEFAULT '',
        companyName TEXT,
        address TEXT,
        city TEXT,
        province TEXT,
        country TEXT,
        postalCode TEXT,
        isManual INTEGER DEFAULT 0,
        isSynced INTEGER DEFAULT 0
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
    // ─── MIGRASI VERSI 5 → 6 ──────────────────────────────
    // Kolom-kolom ini sudah lama ditulis oleh ScanEntry.toMap() tapi belum
    // pernah ada di skema tabel, sehingga SETIAP db.insert() (scan otomatis
    // maupun input manual) gagal dengan error "no such column" dan proses
    // scan terlihat "tidak berfungsi" karena entry-nya di-rollback diam-diam.
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE scan_entries ADD COLUMN imagePath TEXT');
      await db.execute("ALTER TABLE scan_entries ADD COLUMN operatorName TEXT DEFAULT ''");
      await db.execute('ALTER TABLE scan_entries ADD COLUMN companyName TEXT');
      await db.execute('ALTER TABLE scan_entries ADD COLUMN address TEXT');
      await db.execute('ALTER TABLE scan_entries ADD COLUMN city TEXT');
      await db.execute('ALTER TABLE scan_entries ADD COLUMN province TEXT');
      await db.execute('ALTER TABLE scan_entries ADD COLUMN country TEXT');
      await db.execute('ALTER TABLE scan_entries ADD COLUMN postalCode TEXT');
      await db.execute('ALTER TABLE scan_entries ADD COLUMN isManual INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE scan_entries ADD COLUMN isSynced INTEGER DEFAULT 0');
      debugPrint('✅ Database migrated to version 6: added operatorName/companyName/address/'
          'city/province/country/postalCode/isManual/isSynced/imagePath columns');
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

  /// Mengganti seluruh isi database dalam satu transaksi.
  ///
  /// Jika salah satu insert gagal, penghapusan dan insert sebelumnya ikut
  /// di-rollback sehingga restore tidak meninggalkan database kosong/parsial.
  Future<void> replaceAll(List<ScanEntry> entries) async {
    await _runWithProtection((db) async {
      await db.delete('scan_entries');
      for (final entry in entries) {
        await db.insert(
          'scan_entries',
          entry.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }, useTransaction: true);
  }

  /// Menambahkan path foto secara atomik agar worker batch tidak saling
  /// menimpa daftar foto ketika selesai hampir bersamaan.
  Future<ScanEntry?> appendPhotoPath(String entryId, String photoPath) async {
    return _runWithProtection((db) async {
      final rows = await db.query(
        'scan_entries',
        where: 'id = ?',
        whereArgs: [entryId],
        limit: 1,
      );
      if (rows.isEmpty) return null;

      final entry = ScanEntry.fromMap(rows.first);
      final paths = List<String>.from(entry.photoPaths);
      if (!paths.contains(photoPath)) {
        paths.add(photoPath);
      }
      final updated = entry.copyWith(imagePath: paths.join(','));
      await db.update(
        'scan_entries',
        updated.toMap(),
        where: 'id = ?',
        whereArgs: [entryId],
      );
      return updated;
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

  /// Exact-match lookup by kode barcode/manual (kolom `value`), dipakai
  /// untuk cek duplikat saat scan. Sengaja terpisah dari `getEntries`
  /// (yang pakai `searchQuery` LIKE lintas banyak kolom untuk pencarian
  /// bebas) karena cek duplikat butuh exact match yang cepat & presisi,
  /// bukan substring match yang bisa false-positive (mis. kode "123"
  /// akan match "1234", "0123", dst kalau pakai LIKE).
  Future<ScanEntry?> getEntryByValue(String value) async {
    return _runWithProtection((db) async {
      final result = await db.query(
        'scan_entries',
        where: 'value = ?',
        whereArgs: [value],
        orderBy: 'timestamp DESC',
        limit: 1,
      );
      if (result.isEmpty) return null;
      return ScanEntry.fromMap(result.first);
    });
  }

  Future<List<ScanEntry>> getEntries({
    int? limit = 20,
    int offset = 0,
    String? searchQuery,
    String? period,
    String sortField = 'timestamp',
    String sortDir = 'DESC',
  }) async {
    return _runWithProtection((db) async {
      String sql = 'SELECT * FROM scan_entries';
      final filters = _buildFilters(searchQuery: searchQuery, period: period);
      final where = filters.where;
      final args = filters.args;

      if (where.isNotEmpty) {
        sql += ' WHERE ' + where.join(' AND ');
      }

      final direction = sortDir.toUpperCase() == 'ASC' ? 'ASC' : 'DESC';
      String orderBy;
      switch (sortField) {
        case 'value':
          orderBy = 'value COLLATE NOCASE $direction, timestamp DESC, id ASC';
          break;
        case 'timestamp':
        default:
          orderBy = 'timestamp $direction, id $direction';
      }
      sql += ' ORDER BY $orderBy';
      if (limit != null) {
        sql += ' LIMIT ? OFFSET ?';
        args.add(limit);
        args.add(offset);
      }

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
      final filters = _buildFilters(searchQuery: searchQuery, period: period);
      final where = filters.where;
      final args = filters.args;

      if (where.isNotEmpty) {
        sql += ' WHERE ' + where.join(' AND ');
      }

      final result = await db.rawQuery(sql, args);
      return result.first['count'] as int;
    });
  }

  ({List<String> where, List<Object?> args}) _buildFilters({
    String? searchQuery,
    String? period,
    DateTime? now,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    final query = searchQuery?.trim();

    if (query != null && query.isNotEmpty) {
      const columns = <String>[
        'value',
        'imagePath',
        'photoPaths',
        'videoPath',
        'note',
        'locationName',
        'address',
        'city',
        'province',
        'country',
        'postalCode',
        'operatorName',
        'companyName',
      ];
      where.add(
        '(${columns.map((column) => "instr(lower(COALESCE($column, '')), lower(?)) > 0").join(' OR ')})',
      );
      args.addAll(List<Object?>.filled(columns.length, query));
    }

    if (period != null && period != 'Semua') {
      final current = now ?? DateTime.now();
      late final DateTime start;
      late final DateTime end;
      switch (period) {
        case 'Hari ini':
          start = DateTime(current.year, current.month, current.day);
          end = start.add(const Duration(days: 1));
          break;
        case 'Minggu ini':
          final monday = current.subtract(Duration(days: current.weekday - 1));
          start = DateTime(monday.year, monday.month, monday.day);
          end = start.add(const Duration(days: 7));
          break;
        case 'Bulan ini':
          start = DateTime(current.year, current.month, 1);
          end = DateTime(current.year, current.month + 1, 1);
          break;
        default:
          return (where: where, args: args);
      }
      where.add('timestamp >= ? AND timestamp < ?');
      args
        ..add(start.millisecondsSinceEpoch)
        ..add(end.millisecondsSinceEpoch);
    }

    return (where: where, args: args);
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

  Future<void> updateLocation(
    String id, {
    required double latitude,
    required double longitude,
    String? locationName,
  }) async {
    await _runWithProtection((db) async {
      await db.update(
        'scan_entries',
        {
          'latitude': latitude,
          'longitude': longitude,
          'locationName': locationName,
          'address': null,
          'city': null,
          'province': null,
          'country': null,
          'postalCode': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
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
