import 'dart:convert'; // ✅ untuk jsonEncode, jsonDecode, utf8
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
  Future<void> insert(ScanEntry entry) async => _db.insert(entry);
  Future<void> update(ScanEntry entry) async => _db.update(entry);
  Future<void> delete(String id) async => _db.delete(id);
  Future<void> deleteAll() async => _db.deleteAll();

  Future<List<ScanEntry>> loadAll() async => _db.getAll();

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

  // ─── File storage ──────────────────────────────────────────

  Future<String> savePhoto(String sourcePath, {String? name}) async {
    try {
      final source = File(sourcePath);
      if (!await source.exists()) throw FileSystemException('Source file not found', sourcePath);
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

  Future<String> saveVideo(String sourcePath, {String? name}) async {
    try {
      final source = File(sourcePath);
      if (!await source.exists()) throw FileSystemException('Source file not found', sourcePath);
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

  // ─── Sanitasi & Verifikasi ────────────────────────────────

  String _sanitizeFilename(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  }

  Future<void> _verifyFile(String path) async {
    final file = File(path);
    if (!await file.exists()) throw Exception('File tidak ditemukan: $path');
    final size = await file.length();
    if (size == 0) throw Exception('File kosong: $path');
    debugPrint('✅ File verified: $path (${size ~/ 1024}KB)');
  }

  Future<String> _moveFile(String sourcePath, String destPath) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw FileSystemException('Source file not found: $sourcePath');
    final destDir = Directory(dirname(destPath));
    if (!await destDir.exists()) await destDir.create(recursive: true);
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

  // ─── Delete files ──────────────────────────────────────────

  Future<void> deletePhoto(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
      debugPrint('🗑️ Photo deleted: $path');
    } catch (e) {
      debugPrint('⚠️ Storage: error deleting photo: $e');
    }
  }

  Future<void> deleteVideo(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
      debugPrint('🗑️ Video deleted: $path');
    } catch (e) {
      debugPrint('⚠️ Storage: error deleting video: $e');
    }
  }

  // ─── Storage size ──────────────────────────────────────────

  Future<int> getTotalStorageUsed() async {
    int total = 0;
    final appDir = await getApplicationDocumentsDirectory();
    total += await _dirSize(Directory(join(appDir.path, 'photos')));
    total += await _dirSize(Directory(join(appDir.path, 'videos')));
    return total;
  }

  Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    int size = 0;
    await for (final entity in dir.list()) {
      if (entity is File) size += await entity.length();
    }
    return size;
  }

  // ─── Cleanup ──────────────────────────────────────────────

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
            }
          }
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error in cleanupOrphanFiles: $e');
    }
  }

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

  // ─── Backup & Restore ──────────────────────────────────────

  Future<String> backup() async {
    try {
      final entries = await _db.getAll();
      final json = entries.map((e) => e.toJson()).toList();
      final archive = Archive();
      final jsonString = jsonEncode(json);
      final jsonBytes = utf8.encode(jsonString);
      archive.addFile(ArchiveFile('data.json', jsonBytes.length, jsonBytes));

      final zipEncoder = ZipEncoder();
      final zipData = zipEncoder.encode(archive);
      if (zipData == null) throw Exception('Gagal membuat zip');

      final tempDir = await getTemporaryDirectory();
      final zipPath = join(tempDir.path, 'backup_${DateTime.now().millisecondsSinceEpoch}.zip');
      await File(zipPath).writeAsBytes(zipData);
      return zipPath;
    } catch (e) {
      debugPrint('⚠️ Backup error: $e');
      rethrow;
    }
  }

  Future<bool> restore(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final zipDecoder = ZipDecoder();
      final archive = zipDecoder.decodeBytes(bytes);
      final dataFile = archive.files.firstWhere((f) => f.name == 'data.json');
      final jsonString = utf8.decode(dataFile.content);
      final list = jsonDecode(jsonString) as List;
      final entries = list.map((e) => ScanEntry.fromJson(e as Map<String, dynamic>)).toList();

      await _db.deleteAll();
      for (final entry in entries) {
        await _db.insert(entry);
      }
      return true;
    } catch (e) {
      debugPrint('⚠️ Restore error: $e');
      return false;
    }
  }

  Future<void> shareBackup(String zipPath) async {
    await Share.shareXFiles([XFile(zipPath)], text: 'Backup TermulScan');
  }

  // ─── Export & Share TXT ──────────────────────────────────

  Future<String> exportTxt(List<ScanEntry> entries) async {
    final tempDir = await getTemporaryDirectory();
    final path = join(tempDir.path, 'export_${DateTime.now().millisecondsSinceEpoch}.txt');
    final buffer = StringBuffer();
    buffer.writeln('TERMULScan - Data Export');
    buffer.writeln('Generated: ${DateTime.now().toIso8601String()}');
    buffer.writeln('Total entries: ${entries.length}');
    buffer.writeln('---');
    for (final entry in entries) {
      buffer.writeln('ID: ${entry.id}');
      buffer.writeln('Type: ${entry.type.name}');
      buffer.writeln('Value: ${entry.value}');
      buffer.writeln('Time: ${entry.timestampFormatted}');
      if (entry.locationName != null) buffer.writeln('Location: ${entry.locationName}');
      if (entry.photoPaths != null && entry.photoPaths!.isNotEmpty) {
        buffer.writeln('Photos: ${entry.photoPaths!.join(', ')}');
      }
      if (entry.hasVideo) {
        buffer.writeln('Video: ${entry.videoPath}');
        buffer.writeln('Duration: ${entry.videoDurationFormatted}');
      }
      buffer.writeln('---');
    }
    await File(path).writeAsString(buffer.toString());
    return path;
  }

  Future<void> shareTxt(String path) async {
    await Share.shareXFiles([XFile(path)], text: 'Export scan log');
  }

  // ─── Close database ──────────────────────────────────────

  Future<void> close() async {
    await _db.close();
  }
}

// ─── Isolate cleanup helper ──────────────────────────────────

class _CleanupArgs {
  final String photosDir;
  final String videosDir;
  final int days;
  _CleanupArgs({required this.photosDir, required this.videosDir, required this.days});
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
