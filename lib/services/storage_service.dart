import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:archive/archive.dart';
import '../models/scan_entry.dart';
import 'database_helper.dart';

class StorageService {
  // ========== SINGLETON ==========
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  final Uuid _uuid = const Uuid();
  final DatabaseHelper _db = DatabaseHelper();

  final Map<String, int> _maxNumberCache = {};

  String generateId() => _uuid.v4();

  Future<void> add(ScanEntry entry) async => _db.insert(entry);
  Future<void> update(ScanEntry entry) async => _db.update(entry);
  Future<void> delete(String id) async => _db.delete(id);
  Future<void> deleteAll() async => _db.deleteAll();

  Future<List<ScanEntry>> loadAll() => _db.getAll();

  Future<List<ScanEntry>> getEntries({
    int limit = 20,
    int offset = 0,
    String? searchQuery,
    String? period,
    String sortField = 'timestamp',
    String sortDir = 'DESC',
  }) async => _db.getEntries(
        limit: limit,
        offset: offset,
        searchQuery: searchQuery,
        period: period,
        sortField: sortField,
        sortDir: sortDir,
      );

  Future<int> getCount({String? searchQuery, String? period}) async =>
      _db.getCount(searchQuery: searchQuery, period: period);

  Future<ScanEntry?> getEntry(String id) async => _db.getEntry(id);

  Future<void> migrateFromJson(List<ScanEntry> entries) async =>
      _db.migrateFromJson(entries);

  // ... (sisanya sama persis seperti sebelumnya, tidak ada perubahan lain)
}
