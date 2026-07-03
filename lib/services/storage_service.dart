// ================================================================
// lib/services/storage_service.dart (OPTIMASI RENAME + CLEANUP)
// ================================================================
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
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  final Uuid _uuid = const Uuid();
  final DatabaseHelper _db = DatabaseHelper();

  String generateId() => _uuid.v4();

  // ─── Database methods ──────────────────────────────────────
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
  }) async =>
      _db.getEntries(
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

  // ─── Utility: move file (rename jika mungkin, fallback copy+delete) ──
  Future<String> _moveFile(String sourcePath, String destPath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Source file not found: $sourcePath');
    }

    // Pastikan folder tujuan ada
    final destDir = Directory(dirname(destPath));
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }

    try {
      // Coba rename (instan jika di volume yang sama)
      await source.rename(destPath);
      debugPrint('✅ File moved (rename) to: $destPath');
      return destPath;
    } catch (e) {
      // Fallback: copy + delete (misal lintas filesystem)
      debugPrint('⚠️ Rename failed, fallback to copy+delete: $e');
      await source.copy(destPath);
      await source.delete();
      debugPrint('✅ File moved (copy+delete) to: $destPath');
      return destPath;
    }
  }

  // ──────────────────────────────────────────────────────────
  // PHOTO – simpan ke internal (tidak terdeteksi galeri)
  // ──────────────────────────────────────────────────────────
  Future<String> savePhoto(String sourcePath, {String? name}) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final photosDir = Directory(join(appDir.path, 'photos'));
      if (!await photosDir.exists()) {
        await photosDir.create(recursive: true);
      }

      String fileName;
      if (name != null && name.isNotEmpty) {
        final baseName = name.endsWith('.jpg') ? name.substring(0, name.length - 4) : name;
        final candidate = '$baseName.jpg';
        if (!await File(join(photosDir.path, candidate)).exists()) {
          fileName = candidate;
        } else {
          fileName = '${baseName}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        }
      } else {
        fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      }

      final destPath = join(photosDir.path, fileName);
      // Gunakan _moveFile (rename jika mungkin)
      final finalPath = await _moveFile(sourcePath, destPath);
      debugPrint('📸 Photo saved: $finalPath');
      return finalPath;
    } catch (e) {
      debugPrint('⚠️ Storage: error saving photo: $e');
      rethrow;
    }
  }

  // ──────────────────────────────────────────────────────────
  // VIDEO – simpan ke internal
  // ──────────────────────────────────────────────────────────
  Future<String> saveVideo(String sourcePath, {String? name}) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final videosDir = Directory(join(appDir.path, 'videos'));
      if (!await videosDir.exists()) {
        await videosDir.create(recursive: true);
      }

      final fileName = name != null
          ? '${name}_${DateTime.now().millisecondsSinceEpoch}.mp4'
          : '${DateTime.now().millisecondsSinceEpoch}.mp4';

      final destPath = join(videosDir.path, fileName);
      final finalPath = await _moveFile(sourcePath, destPath);
      debugPrint('🎥 Video saved: $finalPath');
      return finalPath;
    } catch (e) {
      debugPrint('⚠️ Storage: error saving video: $e');
      rethrow;
    }
  }

  // ──────────────────────────────────────────────────────────
  // CLEANUP (FOTO & VIDEO) – dengan isolate
  // ──────────────────────────────────────────────────────────
  Future<void> cleanupOldFiles({int days = 90}) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      await _cleanupDir(Directory(join(appDir.path, 'photos')), days: days);
      await _cleanupDir(Directory(join(appDir.path, 'videos')), days: days);
    } catch (e) {
      debugPrint('⚠️ Error cleaning up old files: $e');
    }
  }

  Future<void> _cleanupDir(Directory dir, {required int days}) async {
    if (!await dir.exists()) return;
    final now = DateTime.now();
    final cutoff = now.subtract(Duration(days: days));
    int deletedCount = 0;
    await for (final entity in dir.list()) {
      if (entity is File) {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
          deletedCount++;
        }
      }
    }
    if (deletedCount > 0) {
      debugPrint('🧹 Cleaned up $deletedCount old files from ${dir.path} (>$days days)');
    }
  }

  /// Jalankan cleanup di isolate agar tidak blocking UI
  Future<void> cleanupOldFilesInBackground({int days = 90}) async {
    final appDir = await getApplicationDocumentsDirectory();
    final args = _CleanupArgs(
      photosDir: join(appDir.path, 'photos'),
      videosDir: join(appDir.path, 'videos'),
      days: days,
    );
    await compute(_cleanupInIsolate, args);
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

  Future<void> deleteVideo(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        debugPrint('🗑️ Video deleted: $path');
      }
    } catch (e) {
      debugPrint('⚠️ Storage: error deleting video: $e');
    }
  }

  // ──────────────────────────────────────────────────────────
  // STORAGE INDICATOR
  // ──────────────────────────────────────────────────────────
  Future<int> getTotalStorageUsed() async {
    int totalBytes = 0;
    final appDir = await getApplicationDocumentsDirectory();
    totalBytes += await _dirSize(Directory(join(appDir.path, 'photos')));
    totalBytes += await _dirSize(Directory(join(appDir.path, 'videos')));
    return totalBytes;
  }

  Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    int size = 0;
    await for (final entity in dir.list()) {
      if (entity is File) size += await entity.length();
    }
    return size;
  }

  // ──────────────────────────────────────────────────────────
  // BACKUP & RESTORE
  // ──────────────────────────────────────────────────────────
  Future<String> backup() async {
    // Implementasi backup ke zip
    // ...
    return '';
  }

  Future<bool> restore(String zipPath) async {
    // Implementasi restore dari zip
    // ...
    return false;
  }

  Future<void> shareBackup(String zipPath) async {
    await Share.shareXFiles([XFile(zipPath)], text: 'Backup TermulScan');
  }

  // ──────────────────────────────────────────────────────────
  // EXPORT TXT
  // ──────────────────────────────────────────────────────────
  Future<String> exportTxt(List<ScanEntry> entries) async {
    // Implementasi export ke txt
    // ...
    return '';
  }

  Future<void> shareTxt(String path) async {
    await Share.shareXFiles([XFile(path)], text: 'Export scan log');
  }

  // ──────────────────────────────────────────────────────────
  // CLOSE DATABASE
  // ──────────────────────────────────────────────────────────
  Future<void> close() async {
    await _db.close();
  }
}

// ──────────────────────────────────────────────────────────────
// ISOLATE CLEANUP HELPER
// ──────────────────────────────────────────────────────────────
class _CleanupArgs {
  final String photosDir;
  final String videosDir;
  final int days;
  _CleanupArgs({
    required this.photosDir,
    required this.videosDir,
    required this.days,
  });
}

Future<void> _cleanupInIsolate(_CleanupArgs args) async {
  await _cleanupDir(Directory(args.photosDir), args.days);
  await _cleanupDir(Directory(args.videosDir), args.days);
}

Future<void> _cleanupDir(Directory dir, int days) async {
  if (!await dir.exists()) return;
  final now = DateTime.now();
  final cutoff = now.subtract(Duration(days: days));
  int deletedCount = 0;
  await for (final entity in dir.list()) {
    if (entity is File) {
      final stat = await entity.stat();
      if (stat.modified.isBefore(cutoff)) {
        await entity.delete();
        deletedCount++;
      }
    }
  }
  if (deletedCount > 0) {
    debugPrint('🧹 Isolate deleted $deletedCount old files from ${dir.path}');
  }
}
