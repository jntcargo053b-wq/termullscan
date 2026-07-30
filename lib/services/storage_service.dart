// lib/services/storage_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:archive/archive_io.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
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
  Future<void> updateLocation(
    String id, {
    required double latitude,
    required double longitude,
    String? locationName,
  }) async =>
      _db.updateLocation(
        id,
        latitude: latitude,
        longitude: longitude,
        locationName: locationName,
      );
  Future<void> delete(String id) async => _db.delete(id);
  Future<void> deleteAll() async => _db.deleteAll();

  Future<List<ScanEntry>> loadAll() async => _db.getAll();

  Future<List<ScanEntry>> getEntries({
    int? limit = 20,
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

  Future<List<ScanEntry>> getEntriesForExport({
    String? searchQuery,
    String? period,
    String sortField = 'timestamp',
    String sortDir = 'DESC',
  }) =>
      _db.getEntries(
        limit: null,
        searchQuery: searchQuery,
        period: period,
        sortField: sortField,
        sortDir: sortDir,
      );

  Future<int> getCount({String? searchQuery, String? period}) async =>
      _db.getCount(searchQuery: searchQuery, period: period);

  Future<ScanEntry?> getEntry(String id) async => _db.getEntry(id);

  /// Cek duplikat kode (barcode/manual) sebelum membuat entry baru.
  /// Exact match by `value`, bukan LIKE — lihat catatan di
  /// DatabaseHelper.getEntryByValue.
  Future<ScanEntry?> getEntryByValue(String value) async =>
      _db.getEntryByValue(value);

  Future<void> migrateFromJson(List<ScanEntry> entries) async =>
      _db.migrateFromJson(entries);

  Future<ScanEntry?> appendPhotoPath(String entryId, String photoPath) =>
      _db.appendPhotoPath(entryId, photoPath);

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

  // ─── Save to Gallery (PUBLIC) ──────────────────────────────

  Future<bool> _hasGalleryWritePermission() async {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      // MediaStore tidak memerlukan permission tulis pada Android 10+ ketika
      // skipIfExists=false. Android lama masih membutuhkan storage permission.
      if (info.version.sdkInt >= 29) return true;
      return (await Permission.storage.request()).isGranted;
    }
    if (Platform.isIOS) {
      return (await Permission.photosAddOnly.request()).isGranted;
    }
    return false;
  }

  Future<bool> saveVideoToGallery(String filePath, {String? fileName}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('❌ File not found: $filePath');
        return false;
      }

      final size = await file.length();
      if (size == 0) {
        debugPrint('❌ File is empty: $filePath');
        return false;
      }

      if (!await _hasGalleryWritePermission()) {
        debugPrint('❌ Storage permission denied');
        return false;
      }

      final saved = await SaverGallery.saveFile(
        filePath: filePath,
        fileName: fileName ?? 'watermarked_${DateTime.now().millisecondsSinceEpoch}.mp4',
        androidRelativePath: 'Movies/TermulScan',
        skipIfExists: false,
      );

      if (saved.isSuccess) {
        debugPrint('✅ Video saved to gallery: $filePath');
        return true;
      } else {
        debugPrint('❌ SaverGallery.saveFile returned: $saved');
        return false;
      }
    } catch (e, stack) {
      debugPrint('❌ Error saving video to gallery: $e\n$stack');
      return false;
    }
  }

  Future<bool> savePhotoToGallery(String filePath, {String? fileName}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;

      if (!await _hasGalleryWritePermission()) return false;

      final saved = await SaverGallery.saveFile(
        filePath: filePath,
        fileName: fileName ?? 'watermarked_${DateTime.now().millisecondsSinceEpoch}.jpg',
        androidRelativePath: 'Pictures/TermulScan',
        skipIfExists: false,
      );

      return saved.isSuccess;
    } catch (e) {
      debugPrint('❌ Error saving photo to gallery: $e');
      return false;
    }
  }

  // ─── Sanitasi & Verifikasi ────────────────────────────────

  String _sanitizeFilename(String name) {
    // Koma juga tidak boleh dipakai karena imagePath menyimpan beberapa path
    // dalam format CSV sederhana.
    return name.replaceAll(RegExp(r'[<>:"/\\|?*,]'), '_');
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

    bool usedCopyFallback = false;
    try {
      try {
        await source.rename(destPath);
      } catch (e) {
        debugPrint('⚠️ Rename failed, fallback copy+delete: $e');
        usedCopyFallback = true;
        await source.copy(destPath);
      }

      // PENTING: verifikasi dest SEBELUM menghapus source. Kalau hasil
      // copy/rename ternyata korup/kosong, source harus tetap ada supaya
      // tidak terjadi kehilangan data (foto/video POD).
      await _verifyFile(destPath);

      if (usedCopyFallback) {
        await source.delete();
      }

      return destPath;
    } catch (e) {
      // Bersihkan dest yang gagal verifikasi agar tidak ada file setengah
      // jadi tertinggal. Source tidak disentuh di sini -> tetap aman.
      try {
        final destFile = File(destPath);
        if (await destFile.exists()) await destFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      debugPrint('🔁 _moveFile selesai: $sourcePath -> $destPath (fallback: $usedCopyFallback)');
    }
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
        // 🔥 FIX: photoPaths sekarang getter (bukan nullable)
        activePaths.addAll(entry.photoPaths);

        // 🔥 FIX: videoThumbnail sekarang getter
        if (entry.videoThumbnail != null) {
          activePaths.add(entry.videoThumbnail!);
        }
        if (entry.videoPath != null) {
          activePaths.add(entry.videoPath!);
        }
        if (entry.imagePath != null) {
          activePaths.add(entry.imagePath!);
        }
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
    await cleanupOrphanFiles(days: days);
  }

  Future<void> cleanupOldFilesInBackground({int days = 90}) async {
    // Nama lama dipertahankan untuk kompatibilitas pemanggil, tetapi
    // implementasinya tetap aman: hanya file orphan yang boleh dihapus.
    await cleanupOrphanFiles(days: days);
  }

  // ─── Backup & Restore ──────────────────────────────────────

  Future<String> backup() async {
    try {
      final entries = await _db.getAll();
      final backupEntries = <Map<String, dynamic>>[];
      final archivedPaths = <String, String>{};
      final mediaFiles = <String, File>{};
      int mediaIndex = 0;

      Future<String?> archiveMedia(
        String sourcePath,
        String folder, {
        String? relativePath,
      }) async {
        final existing = archivedPaths[sourcePath];
        if (existing != null) return existing;

        final file = File(sourcePath);
        if (!await file.exists() || await file.length() == 0) return null;

        final safeBase = _sanitizeFilename(basenameWithoutExtension(sourcePath));
        final ext = extension(sourcePath);
        final relative = relativePath ??
            '$folder/${mediaIndex++}_${safeBase.isEmpty ? 'media' : safeBase}$ext';
        mediaFiles[relative] = file;
        archivedPaths[sourcePath] = relative;
        return relative;
      }

      for (final entry in entries) {
        final map = Map<String, dynamic>.from(entry.toJson());

        final photoPaths = <String>[];
        for (final path in entry.photoPaths) {
          final relative = await archiveMedia(path, 'photos');
          if (relative != null) photoPaths.add(relative);
        }
        map['imagePath'] = photoPaths.isEmpty ? null : photoPaths.join(',');

        final videoPath = entry.videoPath;
        if (videoPath != null && videoPath.isNotEmpty) {
          final relativeVideo = await archiveMedia(videoPath, 'videos');
          map['videoPath'] = relativeVideo;

          final thumbnail = entry.videoThumbnail;
          if (relativeVideo != null &&
              thumbnail != null &&
              await File(thumbnail).exists()) {
            final relativeThumbnail =
                '${withoutExtension(relativeVideo)}_thumb.jpg';
            await archiveMedia(
              thumbnail,
              'videos',
              relativePath: relativeThumbnail,
            );
          }
        } else {
          map['videoPath'] = null;
        }
        backupEntries.add(map);
      }

      final payload = <String, dynamic>{
        'version': 2,
        'createdAt': DateTime.now().toIso8601String(),
        'entries': backupEntries,
      };
      final jsonString = jsonEncode(payload);
      final jsonBytes = utf8.encode(jsonString);

      final tempDir = await getTemporaryDirectory();
      final zipPath = join(tempDir.path, 'backup_${DateTime.now().millisecondsSinceEpoch}.zip');
      final zipFile = File(zipPath);
      final encoder = ZipFileEncoder();
      var encoderOpen = false;
      try {
        encoder.create(zipPath);
        encoderOpen = true;
        encoder.addArchiveFile(
          ArchiveFile('data.json', jsonBytes.length, jsonBytes),
        );
        for (final media in mediaFiles.entries) {
          // JPG/MP4 sudah terkompresi. STORE menghindari encode ulang dan
          // ZipFileEncoder membaca file sebagai stream, jadi video besar
          // tidak perlu dimuat seluruhnya ke RAM.
          await encoder.addFile(
            media.value,
            'media/${media.key}',
            ZipFileEncoder.STORE,
          );
        }
        await encoder.close();
        encoderOpen = false;
      } catch (_) {
        if (encoderOpen) {
          try {
            await encoder.close();
          } catch (_) {}
        }
        if (await zipFile.exists()) {
          await zipFile.delete();
        }
        rethrow;
      }

      if (!await zipFile.exists() || await zipFile.length() == 0) {
        throw Exception('Gagal membuat zip');
      }
      return zipPath;
    } catch (e) {
      debugPrint('⚠️ Backup error: $e');
      rethrow;
    }
  }

  Future<bool> restore(String zipPath) async {
    Directory? stagingDir;
    InputFileStream? zipStream;
    final copiedFiles = <File>[];
    try {
      final zipFile = File(zipPath);
      if (!await zipFile.exists() || await zipFile.length() == 0) {
        throw FileSystemException('File backup tidak ditemukan atau kosong');
      }

      zipStream = InputFileStream(zipPath);
      final zipDecoder = ZipDecoder();
      final archive = zipDecoder.decodeBuffer(zipStream);
      final dataFile = archive.files.firstWhere((f) => f.name == 'data.json');
      final dataBytes = List<int>.from(dataFile.content as List);
      dataFile.clear();
      final decoded = jsonDecode(utf8.decode(dataBytes));
      final isVersioned = decoded is Map<String, dynamic>;
      final rawEntries = isVersioned ? decoded['entries'] : decoded;
      if (rawEntries is! List) {
        throw const FormatException('Format backup tidak valid');
      }

      final appDir = await getApplicationDocumentsDirectory();
      final tempDir = await getTemporaryDirectory();
      final restoreTag = DateTime.now().millisecondsSinceEpoch.toString();
      final createdStagingDir =
          Directory(join(tempDir.path, 'termulscan_restore_$restoreTag'));
      stagingDir = createdStagingDir;
      await createdStagingDir.create(recursive: true);

      final archiveFiles = <String, ArchiveFile>{
        for (final file in archive.files)
          file.name.replaceAll('\\', '/'): file,
      };
      final resolvedMedia = <String, String>{};

      Future<String> stageMedia(String relativePath) async {
        final normalizedRelative =
            relativePath.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
        final parts = normalizedRelative.split('/');
        if (parts.length != 2 ||
            !const {'photos', 'videos'}.contains(parts.first) ||
            parts.contains('..')) {
          throw FormatException('Path media backup tidak aman: $relativePath');
        }

        final cached = resolvedMedia[normalizedRelative];
        if (cached != null) return cached;

        final archiveFile = archiveFiles['media/$normalizedRelative'];
        if (archiveFile == null || !archiveFile.isFile) {
          throw FormatException('Media backup tidak ditemukan: $relativePath');
        }

        final finalName = 'restore_${restoreTag}_${parts.last}';
        final finalPath = join(appDir.path, parts.first, finalName);
        final stagedPath = join(createdStagingDir.path, parts.first, finalName);
        if (!isWithin(createdStagingDir.path, stagedPath)) {
          throw FormatException('Target restore berada di luar staging');
        }

        final stagedFile = File(stagedPath);
        await stagedFile.parent.create(recursive: true);
        final output = OutputFileStream(stagedPath);
        try {
          // Buang cache FileContent agar decompress() menyalurkan isi ZIP
          // langsung ke file staging melalui buffer kecil.
          archiveFile.clear();
          archiveFile.decompress(output);
        } finally {
          await output.close();
          archiveFile.clear();
        }
        if (!await stagedFile.exists() ||
            await stagedFile.length() != archiveFile.size) {
          throw FormatException('Media backup rusak: $relativePath');
        }
        resolvedMedia[normalizedRelative] = finalPath;
        return finalPath;
      }

      final entryMaps = <Map<String, dynamic>>[];
      for (final raw in rawEntries) {
        final map = Map<String, dynamic>.from(raw as Map);
        if (isVersioned) {
          final imagePath = map['imagePath'] as String?;
          if (imagePath != null && imagePath.isNotEmpty) {
            final restoredPhotos = <String>[];
            for (final relative in imagePath.split(',').where((p) => p.isNotEmpty)) {
              restoredPhotos.add(await stageMedia(relative));
            }
            map['imagePath'] =
                restoredPhotos.isEmpty ? null : restoredPhotos.join(',');
          }

          final relativeVideo = map['videoPath'] as String?;
          if (relativeVideo != null && relativeVideo.isNotEmpty) {
            map['videoPath'] = await stageMedia(relativeVideo);
            final relativeThumbnail =
                '${withoutExtension(relativeVideo)}_thumb.jpg';
            if (archiveFiles.containsKey('media/$relativeThumbnail')) {
              await stageMedia(relativeThumbnail);
            }
          }
        }
        entryMaps.add(map);
      }

      // Semua metadata divalidasi sebelum data lama disentuh.
      final entries = entryMaps.map(ScanEntry.fromJson).toList();

      // Pindahkan media yang sudah lengkap dari staging. Nama file diberi
      // restoreTag sehingga tidak menimpa media aktif yang sudah ada.
      await for (final entity in createdStagingDir.list(recursive: true)) {
        if (entity is! File) continue;
        final restoredRelativePath =
            relative(entity.path, from: createdStagingDir.path);
        final destination = File(join(appDir.path, restoredRelativePath));
        await destination.parent.create(recursive: true);
        await entity.copy(destination.path);
        copiedFiles.add(destination);
      }

      await _db.replaceAll(entries);
      return true;
    } catch (e) {
      // Database lama tetap utuh jika validasi/copy/transaction gagal.
      for (final file in copiedFiles) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      debugPrint('⚠️ Restore error: $e');
      return false;
    } finally {
      try {
        await zipStream?.close();
      } catch (_) {}
      try {
        final directory = stagingDir;
        if (directory != null && await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<void> shareBackup(String zipPath) async {
    final file = File(zipPath);
    if (!await file.exists() || await file.length() == 0) {
      throw FileSystemException('File backup tidak ditemukan atau kosong', zipPath);
    }
    await Share.shareXFiles([XFile(file.path)], text: 'Backup TermulScan');
  }

  // ─── Export & Share TXT ──────────────────────────────────

  Future<String> exportTxt(List<ScanEntry> entries) async {
    if (entries.isEmpty) {
      throw ArgumentError('Tidak ada data untuk diekspor');
    }
    final tempDir = await getTemporaryDirectory();
    await _cleanupOldExports(tempDir);
    final path = join(
      tempDir.path,
      'termulscan_export_${DateTime.now().millisecondsSinceEpoch}.txt',
    );
    final file = File(path);
    await file.writeAsString(
      '\uFEFF${buildTxtExport(entries)}',
      encoding: utf8,
      flush: true,
    );
    if (!await file.exists() || await file.length() == 0) {
      throw FileSystemException('File export gagal dibuat');
    }
    return path;
  }

  String buildTxtExport(
    List<ScanEntry> entries, {
    DateTime? generatedAt,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('TERMULScan - Ekspor Data');
    buffer.writeln('Dibuat: ${(generatedAt ?? DateTime.now()).toIso8601String()}');
    buffer.writeln('Jumlah data: ${entries.length}');
    buffer.writeln('=' * 48);
    for (final entry in entries) {
      buffer.writeln('ID: ${entry.id}');
      buffer.writeln('Jenis: ${entry.type.name.toUpperCase()}');
      buffer.writeln('Kode: ${_singleLine(entry.value)}');
      buffer.writeln('Waktu: ${entry.formattedTimestamp}');
      if (entry.operatorName.isNotEmpty) {
        buffer.writeln('Operator: ${_singleLine(entry.operatorName)}');
      }
      if (entry.companyName != null && entry.companyName!.isNotEmpty) {
        buffer.writeln('Perusahaan: ${_singleLine(entry.companyName!)}');
      }
      buffer.writeln('Input manual: ${entry.isManual ? 'Ya' : 'Tidak'}');
      if (entry.hasLocation) {
        buffer.writeln('Lokasi: ${_singleLine(entry.displayLocation)}');
      }
      if (entry.latitude != null && entry.longitude != null) {
        buffer.writeln('Koordinat: ${entry.latitude}, ${entry.longitude}');
      }
      if (entry.address != null && entry.address!.isNotEmpty) {
        buffer.writeln('Alamat: ${_singleLine(entry.address!)}');
      }
      final area = <String>[
        if (entry.city != null && entry.city!.isNotEmpty) entry.city!,
        if (entry.province != null && entry.province!.isNotEmpty) entry.province!,
        if (entry.country != null && entry.country!.isNotEmpty) entry.country!,
        if (entry.postalCode != null && entry.postalCode!.isNotEmpty)
          entry.postalCode!,
      ].map(_singleLine).join(', ');
      if (area.isNotEmpty) buffer.writeln('Wilayah: $area');
      if (entry.photoPaths.isNotEmpty) {
        final photoNames =
            entry.photoPaths.map(_basenameAnyOs).toSet().join(', ');
        buffer.writeln('Foto (${entry.photoPaths.length}): $photoNames');
      }
      if (entry.videoPath != null && entry.videoPath!.isNotEmpty) {
        buffer.writeln('Video: ${_basenameAnyOs(entry.videoPath!)}');
        if (entry.videoDuration != null) {
          buffer.writeln('Durasi: ${_formatDuration(entry.videoDuration!)}');
        }
      }
      buffer.writeln('-' * 48);
    }
    return buffer.toString();
  }

  String _singleLine(String value) =>
      value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

  /// Basename yang aman lintas-OS: `package:path`'s basename() ikut context
  /// OS runner (di Linux, `\` dianggap karakter biasa bukan separator), jadi
  /// path bergaya Windows bisa lolos utuh tanpa terpotong saat build/test
  /// jalan di Linux CI. Ini selalu split di kedua separator `/` dan `\`.
  String _basenameAnyOs(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/').where((s) => s.isNotEmpty);
    return segments.isEmpty ? path : segments.last;
  }

  Future<void> _cleanupOldExports(Directory tempDir) async {
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    try {
      await for (final entity in tempDir.list(followLinks: false)) {
        final name = basename(entity.path);
        final isExport = name.startsWith('termulscan_export_') ||
            name.startsWith('export_');
        if (entity is! File || !isExport || !name.endsWith('.txt')) {
          continue;
        }
        final modified = await entity.lastModified();
        if (modified.isBefore(cutoff)) await entity.delete();
      }
    } catch (e) {
      debugPrint('Tidak dapat membersihkan export lama: $e');
    }
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  Future<ShareResult> shareTxt(String path) async {
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) {
      throw FileSystemException('File export tidak ditemukan atau kosong', path);
    }
    return Share.shareXFiles(
      [XFile(file.path)],
      text: 'Export scan log TermulScan',
    );
  }

  // ─── Close database ──────────────────────────────────────

  Future<void> close() async {
    await _db.close();
  }
}
