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
  
  // Lock sederhana untuk mencegah race condition
  bool _isLocked = false;
  final List<Completer<void>> _waiting = [];

  Future<void> _lock() async {
    while (_isLocked) {
      final completer = Completer<void>();
      _waiting.add(completer);
      await completer.future;
    }
    _isLocked = true;
  }

  void _unlock() {
    _isLocked = false;
    if (_waiting.isNotEmpty) {
      final completer = _waiting.removeAt(0);
      completer.complete();
    }
  }

  final Uuid _uuid = const Uuid();

  String generateId() => _uuid.v4();

  Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  // Inisialisasi cache - dipanggil sekali tanpa lock
  Future<void> _initCache() async {
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
  }

  // Method untuk operasi baca/tulis dengan lock
  Future<void> _withLock(Future<void> Function() action) async {
    await _lock();
    try {
      await action();
    } finally {
      _unlock();
    }
  }

  // Pastikan cache sudah diinisialisasi sebelum operasi
  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await _initCache();
    }
  }

  // --- Public methods ---

  Future<List<ScanEntry>> loadAll() async {
    await _ensureInitialized();
    return List.unmodifiable(_cache);
  }

  Future<List<ScanEntry>> getAll() async {
    return loadAll();
  }

  Future<ScanEntry?> getEntry(String id) async {
    await _ensureInitialized();
    try {
      return _cache.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> add(ScanEntry entry) async {
    await _withLock(() async {
      await _ensureInitialized();
      _cache.insert(0, entry);
      await _saveCache();
    });
  }

  Future<void> update(ScanEntry entry) async {
    await _withLock(() async {
      await _ensureInitialized();
      final index = _cache.indexWhere((e) => e.id == entry.id);
      if (index != -1) {
        _cache[index] = entry;
        await _saveCache();
      }
    });
  }

  Future<void> delete(String id) async {
    await _withLock(() async {
      await _ensureInitialized();
      _cache.removeWhere((e) => e.id == id);
      await _saveCache();
    });
  }

  Future<void> deleteAll() async {
    await _withLock(() async {
      await _ensureInitialized();
      _cache = [];
      await _saveCache();
    });
  }

  Future<void> clearAll() async {
    await deleteAll();
  }

  Future<void> _saveCache() async {
    try {
      final f = await _getFile();
      final jsonData = jsonEncode(_cache.map((e) => e.toJson()).toList());
      final tempFile = File('${f.path}.tmp');
      await tempFile.writeAsString(jsonData);

      if (await f.exists()) {
        await f.copy('${f.path}.bak');
      }

      await tempFile.rename(f.path);
      debugPrint('💾 Storage: saved ${_cache.length} entries');
    } catch (e) {
      debugPrint('⚠️ Storage: error saving cache: $e');
      rethrow;
    }
  }

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
    await _ensureInitialized();
    return _cache.length;
  }

  Future<void> restoreFromBackup() async {
    try {
      final f = await _getFile();
      final backup = File('${f.path}.bak');
      if (await backup.exists()) {
        await backup.copy(f.path);
        _initialized = false;
        await _initCache();
        debugPrint('✅ Storage: restored from backup');
      }
    } catch (e) {
      debugPrint('⚠️ Storage: error restoring backup: $e');
    }
  }
}
