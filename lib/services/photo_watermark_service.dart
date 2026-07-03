import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img; // optional, jika butuh manipulasi lebih lanjut
import '../models/scan_entry.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/watermark_style.dart';
import '../utils/image_compression.dart';
import 'video_watermark_service.dart'; // untuk memakai cache yang sama

class PhotoWatermarkService {
  final _WatermarkCache _cache = _WatermarkCache();

  /// Tambahkan watermark ke foto, lalu kompres dengan kualitas adaptif.
  Future<File> addWatermark({
    required ui.Image originalImage,
    required ScanEntry entry,
    required WatermarkSettings settings,
    required String outputPath,
    int baseQuality = 92,
  }) async {
    // 1. Inisialisasi cache (font, logo, layout)
    await _cache.initialize(settings);

    // 2. Gambar watermark di atas originalImage
    final watermarked = await _drawWatermark(
      image: originalImage,
      entry: entry,
      settings: settings,
    );

    // 3. Kompresi adaptif
    final compressedBytes = await compressImageAdaptively(
      image: watermarked,
      baseQuality: baseQuality,
    );

    // 4. Simpan ke file
    final file = File(outputPath);
    await file.writeAsBytes(compressedBytes);
    return file;
  }

  // ─── Metode menggambar watermark ──────────────────────────

  Future<ui.Image> _drawWatermark({
    required ui.Image image,
    required ScanEntry entry,
    required WatermarkSettings settings,
  }) async {
    // Buat recorder
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Gambar foto asli
    final paint = Paint();
    canvas.drawImage(image, Offset.zero, paint);

    // Siapkan data watermark (gunakan cache)
    final fontPath = _cache._cachedFontPath!;
    final font = await _loadFont(fontPath);
    final logo = await _cache.getLogoImage();

    // Tentukan layout berdasarkan gaya
    if (settings.style == WatermarkStyle.timestamp) {
      _drawTimestampWatermark(
        canvas: canvas,
        entry: entry,
        settings: settings,
        font: font,
        logo: logo,
        imageWidth: image.width,
        imageHeight: image.height,
      );
    } else {
      _drawGeneralWatermark(
        canvas: canvas,
        entry: entry,
        settings: settings,
        font: font,
        logo: logo,
        imageWidth: image.width,
        imageHeight: image.height,
      );
    }

    // Selesai
    final picture = recorder.endRecording();
    final img = await picture.toImage(image.width, image.height);
    return img;
  }

  // ─── Implementasi menggambar untuk berbagai gaya ──────────

  void _drawGeneralWatermark({
    required Canvas canvas,
    required ScanEntry entry,
    required WatermarkSettings settings,
    required ui.Font? font,
    required ui.Image? logo,
    required int imageWidth,
    required int imageHeight,
  }) {
    // ... implementasi menggambar untuk gaya professional, polaroid, stamp, minimal
    // Menggunakan font dan logo dari cache, serta data entry.
    // Untuk brevity, ini adalah contoh placeholder.
    // Anda bisa mengimplementasikan sesuai kebutuhan, mirip dengan versi video
    // tetapi menggunakan Canvas dan TextPainter.
  }

  void _drawTimestampWatermark({
    required Canvas canvas,
    required ScanEntry entry,
    required WatermarkSettings settings,
    required ui.Font? font,
    required ui.Image? logo,
    required int imageWidth,
    required int imageHeight,
  }) {
    // ... implementasi timestamp layout di Canvas
  }

  // ─── Helper loading font ──────────────────────────────────

  Future<ui.Font?> _loadFont(String path) async {
    try {
      final data = await File(path).readAsBytes();
      final font = ui.FontLoader('customFont')..loadFromBytes(data);
      await font.load();
      return font;
    } catch (e) {
      debugPrint('❌ Gagal load font: $e');
      return null;
    }
  }
}
