import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';

import '../services/watermark_service.dart';
import 'models/watermark_data.dart';
import 'models/watermark_style.dart';
import 'watermark_factory.dart';

/// Single entry point untuk menghasilkan foto ber-watermark di EXPORT
/// (bukan preview).
///
/// Sebelumnya ada dua "dunia" watermark:
///  - `WatermarkFactory` + `WatermarkLayout` (Polaroid/Minimal/Professional/
///    Stamp) → hanya dipakai untuk preview di settings sheet.
///  - `WatermarkService` (legacy) → satu-satunya yang dipanggil saat export
///    foto sungguhan, dan TIDAK peduli `style` sama sekali.
///
/// `WatermarkRenderer` menyatukan ini: untuk style yang sudah punya
/// implementasi render asli (computeMetrics + paintOnCanvas), hasil export
/// sekarang sama dengan yang ditampilkan di preview. Untuk style yang belum
/// punya implementasi render asli (masih preview-only), kita fallback ke
/// `WatermarkService` lama supaya tidak crash — bukan solusi akhir, tapi
/// aman sambil layout-layout itu diimplementasikan menyusul.
class WatermarkRenderer {
  /// Style yang sudah punya implementasi `computeMetrics`/`paintOnCanvas`
  /// asli di `WatermarkLayout`-nya. Style lain di luar daftar ini masih
  /// preview-only dan akan dialihkan ke engine legacy.
  static const Set<WatermarkStyle> _stylesWithRealRenderer = {
    WatermarkStyle.polaroid,
    WatermarkStyle.minimal,
    WatermarkStyle.professional,
    WatermarkStyle.stamp,
  };

  static final WatermarkService _legacyService = WatermarkService();

  /// Render watermark untuk EXPORT. Mengembalikan path file hasil, atau
  /// null jika gagal.
  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required String operatorName,
    required WatermarkStyle style,
    String? barcodeValue,
    String? barcodeFormat,
    required DateTime timestamp,
    double? latitude,
    double? longitude,
    String? locationName,
    String? logoPath,
  }) async {
    if (!_stylesWithRealRenderer.contains(style)) {
      debugPrint(
        '⚠️ WatermarkRenderer: "${style.name}" belum punya render asli, '
        'fallback ke legacy WatermarkService.',
      );
      return _legacyService.addWatermark(
        imagePath: imagePath,
        outputPath: outputPath,
        operatorName: operatorName,
        style: style,
        barcodeValue: barcodeValue,
        barcodeFormat: barcodeFormat,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        locationName: locationName,
        logoPath: logoPath,
      );
    }

    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        debugPrint('❌ WatermarkRenderer: file tidak ditemukan: $imagePath');
        return null;
      }

      final imageBytes = await file.readAsBytes();
      final targetWidth = await _getOptimalTargetWidth(imageBytes);

      final codec = await ui.instantiateImageCodec(
        imageBytes,
        targetWidth: targetWidth,
      );
      final frame = await codec.getNextFrame();
      final srcImage = frame.image;

      final photoWidth = srcImage.width.toDouble();
      final photoHeight = srcImage.height.toDouble();

      ui.Image? logoImage;
      if (logoPath != null && logoPath.isNotEmpty) {
        logoImage = await _loadLogo(logoPath, targetWidth: targetWidth);
      }

      final data = WatermarkData(
        timestamp: timestamp,
        operatorName: operatorName,
        barcodeValue: barcodeValue,
        barcodeFormat: barcodeFormat,
        latitude: latitude,
        longitude: longitude,
        locationName: locationName,
        logoPath: logoPath,
      );

      final layout = WatermarkFactory.create(style);
      final metrics = layout.computeMetrics(
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        data: data,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      layout.paintOnCanvas(
        canvas: canvas,
        metrics: metrics,
        srcImage: srcImage,
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        logoImage: logoImage,
        data: data,
      );

      final picture = recorder.endRecording();
      final canvasWidth = metrics.canvasWidth.round();
      final canvasHeight = metrics.canvasHeight.round();
      final outputImage = await picture.toImage(canvasWidth, canvasHeight);
      final byteData = await outputImage.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData == null) {
        debugPrint('❌ WatermarkRenderer: gagal encode PNG');
        return null;
      }

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(byteData.buffer.asUint8List());

      debugPrint('✅ WatermarkRenderer: watermark (${style.name}) disimpan: $outputPath');
      return outputPath;
    } catch (e, stack) {
      debugPrint('❌ WatermarkRenderer: error saat render: $e\n$stack');
      return null;
    }
  }

  static Future<int> _getOptimalTargetWidth(Uint8List imageBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      final originalWidth = frame.image.width;
      return originalWidth <= 1024 ? originalWidth : 1024;
    } catch (e) {
      debugPrint('⚠️ WatermarkRenderer: error membaca ukuran gambar: $e');
      return 1024;
    }
  }

  static Future<ui.Image?> _loadLogo(
    String logoPath, {
    required int targetWidth,
  }) async {
    try {
      final logoFile = File(logoPath);
      if (!await logoFile.exists()) return null;

      final logoBytes = await logoFile.readAsBytes();
      final logoTargetWidth = (targetWidth * 0.15).round().clamp(40, 200);
      final logoCodec = await ui.instantiateImageCodec(
        logoBytes,
        targetWidth: logoTargetWidth,
      );
      final logoFrame = await logoCodec.getNextFrame();
      return logoFrame.image;
    } catch (e) {
      debugPrint('⚠️ WatermarkRenderer: error memuat logo: $e');
      return null;
    }
  }
}
