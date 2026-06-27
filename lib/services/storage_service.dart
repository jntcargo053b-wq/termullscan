// ============================================================
// lib/services/storage_service.dart (FINAL - fully optimized)
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

  // Cache untuk menyimpan angka terakhir per barcode prefix
  // Agar tidak scan ulang direktori setiap kali
  final Map<String, int> _maxNumberCache = {};

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

      String fileName;
      if (name != null && name.isNotEmpty) {
        // Ekstrak base name tanpa ekstensi dan tanpa angka di akhir
        String baseName = name.endsWith('.jpg') ? name.substring(0, name.length - 4) : name;
        String pureBase = baseName.replaceFirst(RegExp(r'\d+$'), '');
        String candidate = '$pureBase.jpg';

        if (!await File('${photosDir.path}/$candidate').exists()) {
          fileName = candidate;
          // Reset cache untuk prefix ini karena file baru dibuat
          _maxNumberCache.remove(pureBase);
        } else {
          // Cari angka maksimum untuk prefix ini
          int maxNumber = await _findMaxNumberForPrefix(photosDir, pureBase);
          int nextNumber = maxNumber + 1;
          fileName = '$pureBase${nextNumber.toString().padLeft(3, '0')}.jpg';
        }
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

  // ─── FIND MAX NUMBER FOR PREFIX (dengan stream) ──────────────

  Future<int> _findMaxNumberForPrefix(Directory photosDir, String pureBase) async {
    // Cek cache dulu
    if (_maxNumberCache.containsKey(pureBase)) {
      return _maxNumberCache[pureBase]!;
    }

    int maxNumber = 0;
    final RegExp regExp = RegExp(r'^' + RegExp.escape(pureBase) + r'(\d{0,3})\.jpg$');

    // ✅ Scan direktori dengan stream, tidak load semua ke memory
    await for (final entity in photosDir.list()) {
      if (entity is File) {
        final filename = entity.path.split('/').last;
        final match = regExp.firstMatch(filename);
        if (match != null) {
          final numStr = match.group(1);
          if (numStr != null && numStr.isNotEmpty) {
            final num = int.tryParse(numStr) ?? 0;
            if (num > maxNumber) maxNumber = num;
          }
        }
      }
    }

    // Simpan di cache
    _maxNumberCache[pureBase] = maxNumber;
    return maxNumber;
  }

  // ─── CLEAR CACHE (opsional, saat file dihapus) ──────────────

  void _clearCacheForPrefix(String pureBase) {
    _maxNumberCache.remove(pureBase);
  }

  // ─── CLEANUP OLD FILES ────────────────────────────────────────

  /// Hapus file foto yang sudah lebih dari [days] hari.
  /// Default 45 hari.
  Future<void> cleanupOldFiles({int days = 45}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final photosDir = Directory('${dir.path}/photos');
      if (!await photosDir.exists()) return;

      final now = DateTime.now();
      final cutoff = now.subtract(Duration(days: days));
      int deletedCount = 0;

      // ✅ Stream tidak load semua ke memory
      await for (final entity in photosDir.list()) {
        if (entity is File && entity.path.endsWith('.jpg')) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            // Hapus file
            await entity.delete();
            deletedCount++;

            // Bersihkan cache untuk prefix yang terpengaruh
            final filename = entity.path.split('/').last;
            final baseName = filename.endsWith('.jpg') ? filename.substring(0, filename.length - 4) : filename;
            final pureBase = baseName.replaceFirst(RegExp(r'\d+$'), '');
            _clearCacheForPrefix(pureBase);
          }
        }
      }
      if (deletedCount > 0) {
        debugPrint('🧹 Cleaned up $deletedCount old files (>$days days)');
      }
    } catch (e) {
      debugPrint('⚠️ Error cleaning up old files: $e');
    }
  }

  // ─── DELETE PHOTO (update cache) ─────────────────────────────

  Future<void> deletePhoto(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        final filename = file.path.split('/').last;
        final baseName = filename.endsWith('.jpg') ? filename.substring(0, filename.length - 4) : filename;
        final pureBase = baseName.replaceFirst(RegExp(r'\d+$'), '');
        await file.delete();
        _clearCacheForPrefix(pureBase);
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
