import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../models/scan_entry.dart';

class StorageService {
  static const String _fileName = 'scan_log.json';
  List<ScanEntry> _cache = [];
  bool _initialized = false;
  bool _isSaving = false; // lock sederhana

  final Uuid _uuid = const Uuid();

  String generateId() => _uuid.v4();

  Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  // Lock sederhana untuk mencegah race condition
  Future<void> _withLock(Future<void> Function() action) async {
    while (_isSaving) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    _isSaving = true;
    try {
      await action();
    } finally {
      _isSaving = false;
    }
  }

  Future<void> _loadCache() async {
    if (_initialized) return;
    await _withLock(() async {
      if (_initialized) return;
      try {
        final f = await _getFile();
        if (!await f.exists()) {
          _cache = [];
          _initialized = true;
          return;
        }
        final raw = await f.readAsString();
        if (raw.trim().isEmpty) {
          _cache = [];
          _initialized = true;
          return;
        }
        final decoded = json.decode(raw);
        if (decoded is! List) throw FormatException('Invalid JSON');
        _cache = decoded.map((e) => ScanEntry.fromJson(e as Map<String, dynamic>)).toList();
        _initialized = true;
        debugPrint('📦 Storage: loaded ${_cache.length} entries');
      } catch (e) {
        debugPrint('⚠️ Storage: error loading cache: $e, trying backup');
        try {
          final f = await _getFile();
          final backup = File('${f.path}.bak');
          if (await backup.exists()) {
            await backup.copy(f.path);
            final raw = await f.readAsString();
            final decoded = json.decode(raw);
            _cache = (decoded as List).map((e) => ScanEntry.fromJson(e as Map<String, dynamic>)).toList();
            _initialized = true;
            debugPrint('✅ Storage: restored from backup');
            return;
          }
        } catch (backupError) {
          debugPrint('⚠️ Backup restore failed: $backupError');
        }
        _cache = [];
        _initialized = true;
      }
    });
  }

  Future<void> _saveCache() async {
    await _withLock(() async {
      try {
        final f = await _getFile();
        final jsonData = jsonEncode(_cache.map((e) => e.toJson()).toList());
        final tempFile = File('${f.path}.tmp');
        await tempFile.writeAsString(jsonData);

        // Backup sebelum overwrite
        if (await f.exists()) {
          await f.copy('${f.path}.bak');
        }

        // Rename temp ke file utama
        await tempFile.rename(f.path);

        debugPrint('💾 Storage: saved ${_cache.length} entries');
      } catch (e) {
        debugPrint('⚠️ Storage: error saving cache: $e');
        rethrow;
      }
    });
  }

  // --- Method yang dibutuhkan oleh layar lain ---

  Future<List<ScanEntry>> loadAll() async {
    await _loadCache();
    return List.unmodifiable(_cache);
  }

  Future<List<ScanEntry>> getAll() async {
    return loadAll();
  }

  Future<ScanEntry?> getEntry(String id) async {
    await _loadCache();
    try {
      return _cache.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> add(ScanEntry entry) async {
    await _withLock(() async {
      await _loadCache();
      _cache.insert(0, entry);
      await _saveCache();
    });
  }

  Future<void> update(ScanEntry entry) async {
    await _withLock(() async {
      await _loadCache();
      final index = _cache.indexWhere((e) => e.id == entry.id);
      if (index != -1) {
        _cache[index] = entry;
        await _saveCache();
      }
    });
  }

  Future<void> delete(String id) async {
    await _withLock(() async {
      await _loadCache();
      _cache.removeWhere((e) => e.id == id);
      await _saveCache();
    });
  }

  Future<void> deleteAll() async {
    await _withLock(() async {
      _cache = [];
      await _saveCache();
    });
  }

  Future<void> clearAll() async {
    await deleteAll();
  }

  // Export ke file teks
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

  // Share file teks menggunakan share_plus
  Future<void> shareTxt(String path) async {
    try {
      final result = await Share.shareFiles([path], text: 'Export scan log');
      debugPrint('Share result: $result');
    } catch (e) {
      debugPrint('Share error: $e');
    }
  }

  // Simpan foto ke folder dokumen
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
      final fileName = name != null
          ? '${DateTime.now().millisecondsSinceEpoch}_$name.jpg'
          : '${DateTime.now().millisecondsSinceEpoch}.jpg';
      final destPath = '${photosDir.path}/$fileName';
      final dest = File(destPath);
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

  Future<int> getCount() async {
    await _loadCache();
    return _cache.length;
  }

  Future<void> restoreFromBackup() async {
    try {
      final f = await _getFile();
      final backup = File('${f.path}.bak');
      if (await backup.exists()) {
        await backup.copy(f.path);
        _initialized = false;
        await _loadCache();
        debugPrint('✅ Storage: restored from backup');
      }
    } catch (e) {
      debugPrint('⚠️ Storage: error restoring backup: $e');
    }
  }
}
