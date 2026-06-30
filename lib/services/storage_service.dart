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

  // ================================================================
  // CRUD
  // ================================================================

  Future<void> add(ScanEntry entry) async => _db.insert(entry);
  Future<void> update(ScanEntry entry) async => _db.update(entry);
  Future<void> delete(String id) async => _db.delete(id);
  Future<void> deleteAll() async => _db.deleteAll();

  // ================================================================
  // QUERY
  // ================================================================

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

  // ================================================================
  // PHOTO
  // ================================================================

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
        String baseName = name.endsWith('.jpg')
            ? name.substring(0, name.length - 4)
            : name;
        String pureBase = baseName.replaceFirst(RegExp(r'\d+$'), '');
        String candidate = '$pureBase.jpg';

        if (!await File('${photosDir.path}/$candidate').exists()) {
          fileName = candidate;
          _maxNumberCache.remove(pureBase);
        } else {
          int maxNumber = await _findMaxNumberForPrefixStream(photosDir, pureBase);
          if (maxNumber == 0) maxNumber = 1;
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

  Future<int> _findMaxNumberForPrefixStream(
      Directory photosDir, String pureBase) async {
    if (_maxNumberCache.containsKey(pureBase)) {
      return _maxNumberCache[pureBase]!;
    }

    int maxNumber = 0;
    final RegExp regExp =
        RegExp(r'^' + RegExp.escape(pureBase) + r'(\d*)\.jpg$');

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

    _maxNumberCache[pureBase] = maxNumber;
    return maxNumber;
  }

  // ================================================================
  // CLEANUP
  // ================================================================

  Future<void> cleanupOldFilesInBackground({int days = 90}) async {
    final dir = await getApplicationDocumentsDirectory();
    final photosDir = '${dir.path}/photos';
    await compute(_cleanupInIsolate, _CleanupArgs(photosDir, days));
  }

  Future<void> cleanupOldFiles({int days = 90}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final photosDir = Directory('${dir.path}/photos');
      if (!await photosDir.exists()) return;

      final now = DateTime.now();
      final cutoff = now.subtract(Duration(days: days));
      int deletedCount = 0;

      await for (final entity in photosDir.list()) {
        if (entity is File && entity.path.endsWith('.jpg')) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
            deletedCount++;
            final filename = entity.path.split('/').last;
            final base = filename.endsWith('.jpg')
                ? filename.substring(0, filename.length - 4)
                : filename;
            final pureBase = base.replaceFirst(RegExp(r'\d+$'), '');
            _maxNumberCache.remove(pureBase);
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

  Future<void> deletePhoto(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        final filename = file.path.split('/').last;
        final base = filename.endsWith('.jpg')
            ? filename.substring(0, filename.length - 4)
            : filename;
        final pureBase = base.replaceFirst(RegExp(r'\d+$'), '');
        await file.delete();
        _maxNumberCache.remove(pureBase);
        debugPrint('🗑️ Photo deleted: $path');
      }
    } catch (e) {
      debugPrint('⚠️ Storage: error deleting photo: $e');
    }
  }

  // ================================================================
  // VIDEO
  // ================================================================

  Future<String> saveVideo(String sourcePath, {String? name}) async {
    try {
      final source = File(sourcePath);
      if (!await source.exists()) {
        throw FileSystemException('Source file not found', sourcePath);
      }
      final dir = await getApplicationDocumentsDirectory();
      final videosDir = Directory('${dir.path}/videos');
      if (!await videosDir.exists()) {
        await videosDir.create(recursive: true);
      }
      final fileName = name != null
          ? '${name}_${DateTime.now().millisecondsSinceEpoch}.mp4'
          : '${DateTime.now().millisecondsSinceEpoch}.mp4';
      final destPath = '${videosDir.path}/$fileName';
      await source.copy(destPath);
      if (sourcePath != destPath && await source.exists()) {
        await source.delete();
      }
      debugPrint('🎥 Video saved: $destPath');
      return destPath;
    } catch (e) {
      debugPrint('⚠️ Storage: error saving video: $e');
      rethrow;
    }
  }

  // ================================================================
  // STORAGE INDICATOR
  // ================================================================

  Future<int> getTotalStorageUsed() async {
    int totalBytes = 0;
    final appDir = await getApplicationDocumentsDirectory();

    final photosDir = Directory(join(appDir.path, 'photos'));
    if (await photosDir.exists()) {
      await for (final entity in photosDir.list()) {
        if (entity is File) totalBytes += await entity.length();
      }
    }

    final videosDir = Directory(join(appDir.path, 'videos'));
    if (await videosDir.exists()) {
      await for (final entity in videosDir.list()) {
        if (entity is File) totalBytes += await entity.length();
      }
    }

    return totalBytes;
  }

  // ================================================================
  // BACKUP & RESTORE
  // ================================================================

  Future<String> backup() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dbFile = File(join(appDir.path, 'scan_log.db'));
    final photosDir = Directory(join(appDir.path, 'photos'));
    final videosDir = Directory(join(appDir.path, 'videos'));

    final archive = Archive();

    if (await dbFile.exists()) {
      final bytes = await dbFile.readAsBytes();
      archive.addFile(ArchiveFile('scan_log.db', bytes.length, Stream.value(bytes)));
    }

    if (await photosDir.exists()) {
      await for (final entity in photosDir.list()) {
        if (entity is File) {
          final bytes = await entity.readAsBytes();
          archive.addFile(ArchiveFile(
            'photos/${entity.path.split('/').last}',
            bytes.length,
            Stream.value(bytes),
          ));
        }
      }
    }

    if (await videosDir.exists()) {
      await for (final entity in videosDir.list()) {
        if (entity is File) {
          final bytes = await entity.readAsBytes();
          archive.addFile(ArchiveFile(
            'videos/${entity.path.split('/').last}',
            bytes.length,
            Stream.value(bytes),
          ));
        }
      }
    }

    final zipData = ZipEncoder().encode(archive);
    if (zipData == null) {
      debugPrint('❌ Gagal membuat ZIP');
      return '';
    }

    final backupDir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final zipPath = '${backupDir.path}/termulscan_backup_$timestamp.zip';
    await File(zipPath).writeAsBytes(zipData);

    debugPrint('✅ Backup berhasil: $zipPath');
    return zipPath;
  }

  Future<bool> restore(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final appDir = await getApplicationDocumentsDirectory();

      for (final file in archive) {
        if (file.isFile) {
          final filePath = join(appDir.path, file.name);
          await File(filePath).parent.create(recursive: true);
          await File(filePath).writeAsBytes(file.content as List<int>);
        }
      }

      debugPrint('✅ Restore berhasil dari $zipPath');
      return true;
    } catch (e) {
      debugPrint('❌ Restore gagal: $e');
      return false;
    }
  }

  Future<void> shareBackup(String zipPath) async {
    await Share.shareXFiles([XFile(zipPath)], text: 'Backup TermulScan');
  }

  // ================================================================
  // EXPORT TXT
  // ================================================================

  Future<String> exportTxt(List<ScanEntry> entries) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(
        '${dir.path}/scan_export_${DateTime.now().millisecondsSinceEpoch}.txt');
    final buffer = StringBuffer();
    for (var entry in entries) {
      buffer.writeln(
          '${entry.timestamp} | ${entry.type} | ${entry.value} | ${entry.barcodeFormat ?? ''} | ${entry.locationName ?? ''}');
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

// ================================================================
// ISOLATE CLEANUP HELPER
// ================================================================

class _CleanupArgs {
  final String photosDir;
  final int days;
  _CleanupArgs(this.photosDir, this.days);
}

Future<void> _cleanupInIsolate(_CleanupArgs args) async {
  final dir = Directory(args.photosDir);
  if (!await dir.exists()) return;

  final now = DateTime.now();
  final cutoff = now.subtract(Duration(days: args.days));
  int deletedCount = 0;

  await for (final entity in dir.list()) {
    if (entity is File && entity.path.endsWith('.jpg')) {
      final stat = await entity.stat();
      if (stat.modified.isBefore(cutoff)) {
        await entity.delete();
        deletedCount++;
      }
    }
  }

  if (deletedCount > 0) {
    debugPrint('🧹 Isolate deleted $deletedCount old files');
  }
}
