// ============================================================
// lib/services/storage_service.dart (FINAL - dengan getEntries & getCount)
// ============================================================
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../models/scan_entry.dart';

class StorageService {
  static const String _fileName = 'scan_log.json';
  List<ScanEntry> _cache = [];
  bool _initialized = false;
  bool _isSaving = false;

  final Uuid _uuid = const Uuid();

  String generateId() => _uuid.v4();

  Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

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

        if (await f.exists()) {
          await f.copy('${f.path}.bak');
        }
        await tempFile.rename(f.path);
        debugPrint('💾 Storage: saved ${_cache.length} entries');
      } catch (e) {
        debugPrint('⚠️ Storage: error saving cache: $e');
        rethrow;
      }
    });
  }

  // ─── PUBLIC METHODS ─────────────────────────────────────────────

  /// Load semua data (untuk keperluan filter di memory)
  Future<List<ScanEntry>> loadAll() async {
    await _loadCache();
    return List.unmodifiable(_cache);
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

  // ─── PAGINATION & FILTER (berbasis memory) ──────────────────────
  Future<List<ScanEntry>> getEntries({
    int limit = 20,
    int offset = 0,
    String? searchQuery,
    String? period,
  }) async {
    await _loadCache();
    List<ScanEntry> result = List.from(_cache);

    // Filter period
    if (period != null && period != 'Semua') {
      final now = DateTime.now();
      DateTime start;
      switch (period) {
        case 'Hari ini':
          start = DateTime(now.year, now.month, now.day);
          break;
        case 'Minggu ini':
          start = now.subtract(Duration(days: now.weekday - 1));
          start = DateTime(start.year, start.month, start.day);
          break;
        case 'Bulan ini':
          start = DateTime(now.year, now.month, 1);
          break;
        default:
          start = DateTime(0);
      }
      result = result.where((e) => e.timestamp.isAfter(start)).toList();
    }

    // Filter search
    if (searchQuery != null && searchQuery.isNotEmpty) {
      final query = searchQuery.toLowerCase();
      final df = DateFormat('dd/MM/yyyy HH:mm:ss');
      result = result.where((e) {
        final matchesBarcode = e.value.toLowerCase().contains(query);
        final matchesDate = df.format(e.timestamp).contains(query);
        return matchesBarcode || matchesDate;
      }).toList();
    }

    // Sort
    result.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // Pagination
    final start = offset;
    final end = (offset + limit).clamp(0, result.length);
    return result.sublist(start, end);
  }

  Future<int> getCount({
    String? searchQuery,
    String? period,
  }) async {
    await _loadCache();
    List<ScanEntry> result = List.from(_cache);

    if (period != null && period != 'Semua') {
      final now = DateTime.now();
      DateTime start;
      switch (period) {
        case 'Hari ini':
          start = DateTime(now.year, now.month, now.day);
          break;
        case 'Minggu ini':
          start = now.subtract(Duration(days: now.weekday - 1));
          start = DateTime(start.year, start.month, start.day);
          break;
        case 'Bulan ini':
          start = DateTime(now.year, now.month, 1);
          break;
        default:
          start = DateTime(0);
      }
      result = result.where((e) => e.timestamp.isAfter(start)).toList();
    }

    if (searchQuery != null && searchQuery.isNotEmpty) {
      final query = searchQuery.toLowerCase();
      final df = DateFormat('dd/MM/yyyy HH:mm:ss');
      result = result.where((e) {
        final matchesBarcode = e.value.toLowerCase().contains(query);
        final matchesDate = df.format(e.timestamp).contains(query);
        return matchesBarcode || matchesDate;
      }).toList();
    }

    return result.length;
  }

  // ─── PHOTO ────────────────────────────────────────────────────────
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

  // ─── EXPORT ──────────────────────────────────────────────────────
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
