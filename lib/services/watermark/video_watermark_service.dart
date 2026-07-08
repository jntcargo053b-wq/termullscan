// lib/services/watermark/watermark_service.dart

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/scan_entry.dart';            // Sesuaikan path model Anda
import '../../watermark/watermark_renderer.dart'; // Renderer yang sudah Anda kirim
import '../../watermark/watermark_settings.dart'; // Settings baru

class WatermarkService {
  // ========== SINGLETON ==========
  static final WatermarkService _instance = WatermarkService._internal();
  factory WatermarkService() => _instance;
  WatermarkService._internal();

  final WatermarkSettings settings = WatermarkSettings();

  // Opsional: flag untuk hapus file asli setelah export (sesuai nama lama)
  bool deleteLocalVideoAfterGalleryExport = false; // Bisa diubah dari luar

  /// Fungsi utama untuk menambahkan watermark ke gambar (PNG).
  /// Mengembalikan path file output, atau null jika gagal.
  Future<String?> applyWatermark({
    required String imagePath,
    required ScanEntry entry,
    String? outputPath,
  }) async {
    // 1. Load settings
    await settings.load();

    // 2. Generate output path jika tidak disediakan
    final outPath = outputPath ?? await _generateOutputPath(imagePath);

    // 3. Panggil renderer STATIC
    final result = await WatermarkRenderer.render(
      imagePath: imagePath,
      outputPath: outPath,
      settings: settings,
      entry: entry,
    );

    // 4. Jika sukses dan flag aktif, hapus file asli
    if (result != null && deleteLocalVideoAfterGalleryExport) {
      try {
        await File(imagePath).delete();
        if (kDebugMode) debugPrint('🗑️ Original image deleted: $imagePath');
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Gagal hapus original: $e');
      }
    }

    if (kDebugMode) {
      debugPrint(result == null ? '❌ Watermark gagal' : '✅ Watermark berhasil: $result');
    }
    return result;
  }

  // ========== HELPER ==========
  Future<String> _generateOutputPath(String inputPath) async {
    final dir = await getTemporaryDirectory();
    final fileName = 'watermarked_${DateTime.now().millisecondsSinceEpoch}.png';
    return '${dir.path}/$fileName';
  }
}
