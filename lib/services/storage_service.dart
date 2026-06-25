import 'dart:io';
import 'package:uuid/uuid.dart';
import '../models/scan_entry.dart';
import 'database_helper.dart';

class StorageService {
  final Uuid _uuid = const Uuid();
  final DatabaseHelper _db = DatabaseHelper();

  String generateId() => _uuid.v4();

  // ─── CRUD ──────────────────────────────────────────

  Future<void> add(ScanEntry entry) async {
    await _db.insert(entry);
  }

  Future<void> update(ScanEntry entry) async {
    await _db.update(entry);
  }

  Future<void> delete(String id) async {
    await _db.delete(id);
  }

  Future<void> deleteAll() async {
    await _db.deleteAll();
  }

  // ─── QUERY DENGAN PAGINATION ──────────────────────

  Future<List<ScanEntry>> getEntries({
    int limit = 20,
    int offset = 0,
    String? searchQuery,
    String? period,
  }) async {
    return await _db.getEntries(
      limit: limit,
      offset: offset,
      searchQuery: searchQuery,
      period: period,
    );
  }

  Future<int> getCount({
    String? searchQuery,
    String? period,
  }) async {
    return await _db.getCount(
      searchQuery: searchQuery,
      period: period,
    );
  }

  // ─── MIGRASI ──────────────────────────────────────

  Future<void> migrateFromJson(List<ScanEntry> entries) async {
    await _db.migrateFromJson(entries);
  }

  // ─── PHOTO ────────────────────────────────────────

  Future<String> savePhoto(String sourcePath, {String? name}) async {
    // sama seperti sebelumnya
    // ... (copy dari kode lama)
  }

  Future<void> deletePhoto(String path) async {
    // sama seperti sebelumnya
  }

  // ─── EXPORT ───────────────────────────────────────

  Future<String> exportTxt(List<ScanEntry> entries) async {
    // sama seperti sebelumnya
  }

  Future<void> shareTxt(String path) async {
    // sama seperti sebelumnya
  }
}
