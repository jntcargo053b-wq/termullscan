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
  // ... (delete, loadAll, getEntries, getCount, getEntry, migrateFromJson tetap sama)

  // ─── Sanitasi filename ──────────────────────────────────────
  String _sanitizeFilename(String name) {
    // Ganti karakter tidak valid dengan '_'
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  }

  // ─── Verifikasi file ──────────────────────────────────────
  Future<void> _verifyFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('File tidak ditemukan: $path');
    }
    final size = await file.length();
    if (size == 0) {
      throw Exception('File kosong: $path');
    }
    debugPrint('✅ File verified: $path (${size ~/ 1024}KB)');
  }

  // ─── Move file dengan rename fallback ──────────────────────
  Future<String> _moveFile(String sourcePath, String destPath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Source file not found: $sourcePath');
    }
    final destDir = Directory(dirname(destPath));
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }
    try {
      await source.rename(destPath);
    } catch (e) {
      debugPrint('⚠️ Rename failed, fallback copy+delete: $e');
      await source.copy(destPath);
      await source.delete();
    }
    await _verifyFile(destPath);
    return destPath;
  }

  // ─── Save Photo ─────────────────────────────────────────────
  Future<String> savePhoto(String sourcePath, {String? name}) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final photosDir = Directory(join(appDir.path, 'photos'));
      if (!await photosDir.exists()) await photosDir.create(recursive: true);

      String baseName = name ?? 'photo_${DateTime.now().millisecondsSinceEpoch}';
      baseName = _sanitizeFilename(baseName);
      String fileName = baseName.endsWith('.jpg') ? baseName : '$baseName.jpg';

      String finalName = fileName;
      int counter = 1;
      while (await File(join(photosDir.path, finalName)).exists()) {
        finalName = '${baseName}_$counter.jpg';
        counter++;
      }

      final destPath = join(photosDir.path, finalName);
      final result = await _moveFile(sourcePath, destPath);
      debugPrint('📸 Photo saved: $result');
      return result;
    } catch (e) {
      debugPrint('⚠️ Storage: error saving photo: $e');
      rethrow;
    }
  }

  // ─── Save Video ─────────────────────────────────────────────
  Future<String> saveVideo(String sourcePath, {String? name}) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final videosDir = Directory(join(appDir.path, 'videos'));
      if (!await videosDir.exists()) await videosDir.create(recursive: true);

      String baseName = name ?? 'video_${DateTime.now().millisecondsSinceEpoch}';
      baseName = _sanitizeFilename(baseName);
      String fileName = baseName.endsWith('.mp4') ? baseName : '$baseName.mp4';

      String finalName = fileName;
      int counter = 1;
      while (await File(join(videosDir.path, finalName)).exists()) {
        finalName = '${baseName}_$counter.mp4';
        counter++;
      }

      final destPath = join(videosDir.path, finalName);
      final result = await _moveFile(sourcePath, destPath);
      debugPrint('🎥 Video saved: $result');
      return result;
    } catch (e) {
      debugPrint('⚠️ Storage: error saving video: $e');
      rethrow;
    }
  }

  // ─── Cleanup Berbasis Database ──────────────────────────────
  Future<void> cleanupOrphanFiles({int days = 45}) async {
    try {
      final entries = await _db.getAll();
      final activePaths = <String>{};

      for (final entry in entries) {
        if (entry.videoPath != null) activePaths.add(entry.videoPath!);
        activePaths.addAll(entry.photoPaths ?? []);
        if (entry.videoThumbnail != null) activePaths.add(entry.videoThumbnail!);
      }

      final appDir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final cutoff = now.subtract(Duration(days: days));

      final dirs = [
        Directory(join(appDir.path, 'photos')),
        Directory(join(appDir.path, 'videos')),
      ];

      for (final dir in dirs) {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is File) {
            final stat = await entity.stat();
            final isOld = stat.modified.isBefore(cutoff);
            final isOrphan = !activePaths.contains(entity.path);
            if (isOrphan && isOld) {
              await entity.delete();
              debugPrint('🧹 Deleted orphan file: ${entity.path}');
            } else if (isOrphan) {
              debugPrint('⚠️ Orphan file (new): ${entity.path}');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error in cleanupOrphanFiles: $e');
    }
  }

  // ─── Legacy cleanup (tetap dipertahankan) ───────────────────
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

  Future<void> cleanupOldFilesInBackground({int days = 90}) async {
    final appDir = await getApplicationDocumentsDirectory();
    final args = _CleanupArgs(
      photosDir: join(appDir.path, 'photos'),
      videosDir: join(appDir.path, 'videos'),
      days: days,
    );
    await compute(_cleanupInIsolate, args);
  }

  // ─── Delete methods ──────────────────────────────────────
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

  // ─── Storage indicator, backup, export (placeholder) ───
  // ... (getTotalStorageUsed, backup, restore, exportTxt, shareTxt, close)
}

// ─── Isolate cleanup helper ──────────────────────────────────
class _CleanupArgs {
  final String photosDir;
  final String videosDir;
  final int days;
  _CleanupArgs({required this.photosDir, required this.videosDir, required this.days});
}

Future<void> _cleanupInIsolate(_CleanupArgs args) async {
  // Implementasi sama seperti sebelumnya
}
