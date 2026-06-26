// ============================================================
// lib/services/storage_service.dart (FIXED - savePhoto naming)
// ============================================================
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../models/scan_entry.dart';
import 'database_helper.dart';

class StorageService {
  final Uuid _uuid = const Uuid();
  final DatabaseHelper _db = DatabaseHelper();

  String generateId() => _uuid.v4();

  // ─── CRUD ──────────────────────────────────────────────────────

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

  // ─── QUERY ────────────────────────────────────────────────────

  Future<List<ScanEntry>> loadAll() async {
    return await _db.getAll();
  }

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

  Future<ScanEntry?> getEntry(String id) async {
    return await _db.getEntry(id);
  }

  // ─── MIGRASI ──────────────────────────────────────────────────

  Future<void> migrateFromJson(List<ScanEntry> entries) async {
    await _db.migrateFromJson(entries);
  }

  // ─── PHOTO ────────────────────────────────────────────────────

  Future<String> savePhoto(String sourcePath, {String? name}) async {
    try {
      final source = File(sourcePath);
      if (!await source.exists()) {
        throw FileSystemException('Source file not found', sourcePath);
      }
      final dir = await getApplicationDocumentsDirectory();
      final photosDir = Directory('${dir.path}/photos');
      if (!await photosDir.exists()) {
        await photosDir.create(recursive: true);
      }

      // ✅ Jika name diberikan, gunakan langsung tanpa timestamp
      String fileName;
      if (name != null && name.isNotEmpty) {
        // Jika name sudah berakhiran .jpg, biarkan; jika tidak tambahkan .jpg
        fileName = name.endsWith('.jpg') ? name : '$name.jpg';
      } else {
        fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      }

      final destPath = '${photosDir.path}/$fileName';
      await source.copy(destPath);
      if (sourcePath != destPath && await source.exists()) {
        await source.delete();
      }
      debugPrint('📸 Photo saved: $destPath');
      return destPath;
    } catch (e) {
      debugPrint('⚠️ Storage: error saving photo: $e');
      rethrow;
    }
  }

  Future<void> deletePhoto(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        debugPrint('🗑️ Photo deleted: $path');
      }
    } catch (e) {
      debugPrint('⚠️ Storage: error deleting photo: $e');
    }
  }

  // ─── EXPORT ────────────────────────────────────────────────────

  Future<String> exportTxt(List<ScanEntry> entries) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/scan_export_${DateTime.now().millisecondsSinceEpoch}.txt');
    final buffer = StringBuffer();
    for (var entry in entries) {
      buffer.writeln('${entry.timestamp} | ${entry.type} | ${entry.value} | ${entry.barcodeFormat ?? ''} | ${entry.locationName ?? ''}');
    }
    await file.writeAsString(buffer.toString());
    return file.path;
  }

  Future<void> shareTxt(String path) async {
    try {
      final xFile = XFile(path);
      await Share.shareXFiles([xFile], text: 'Export scan log');
      debugPrint('✅ Share successful');
    } catch (e) {
      debugPrint('⚠️ Share error: $e');
    }
  }
}
