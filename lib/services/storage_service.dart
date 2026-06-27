// ============================================================
// lib/services/storage_service.dart (FINAL - optimized stream)
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

      String fileName;
      if (name != null && name.isNotEmpty) {
        // Ekstrak base name tanpa ekstensi dan tanpa angka di akhir
        String baseName = name.endsWith('.jpg') ? name.substring(0, name.length - 4) : name;
        // Hapus angka di akhir (jika ada) untuk mendapatkan base murni
        String pureBase = baseName.replaceFirst(RegExp(r'\d+$'), '');
        // Cek apakah file dengan nama persis sudah ada
        String candidate = '$pureBase.jpg';
        if (!await File('${photosDir.path}/$candidate').exists()) {
          fileName = candidate;
        } else {
          // Scan direktori untuk mencari angka maksimum (gunakan stream, tidak load semua ke memori)
          int maxNumber = 1; // ABC.jpg dianggap angka 1 (foto pertama)
          final RegExp regExp = RegExp(r'^' + RegExp.escape(pureBase) + r'(\d{0,3})\.jpg$');
          await for (var entity in photosDir.list()) {
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

      await for (var entity in photosDir.list()) {
        if (entity is File && entity.path.endsWith('.jpg')) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
            deletedCount++;
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
