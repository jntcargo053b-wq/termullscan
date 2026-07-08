// ============================================================
// lib/watermark/watermark_renderer.dart (dart:ui – stabil + companyName)
// ============================================================
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import '../models/scan_entry.dart';
import 'models/watermark_data.dart';
import 'watermark_style.dart';
import 'watermark_factory.dart';
import 'watermark_settings.dart';

class WatermarkRenderer {
  static const Set<WatermarkStyle> _stylesWithRealRenderer = {
    WatermarkStyle.minimal,
    WatermarkStyle.professional,
    WatermarkStyle.polaroid,
    WatermarkStyle.stamp,
  };

  /// Render watermark ke file output.
  /// Masih di UI thread, namun dengan single decode & dispose dini
  /// performa tetap ringan untuk gambar yang sudah di‑resize ke 1600px.
  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    if (kDebugMode) {
      debugPrint('🎯 WATERMARK RENDER START');
      debugPrint('  Style: ${settings.style.name}');
    }

    ui.Image? srcImage;
    ui.Image? logoImage;
    ui.Codec? codec;
    ui.Codec? logoCodec;
    ui.Image? outputImage;

    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        debugPrint('❌ File tidak ditemukan: $imagePath');
        return null;
      }

      final imageBytes = await file.readAsBytes();

      // ✅ Single decode
      codec = await ui.instantiateImageCodec(
        imageBytes,
        targetWidth: 1600,
      );
      final frame = await codec.getNextFrame();
      srcImage = frame.image;
      codec.dispose();
      codec = null;

      final photoWidth = srcImage.width.toDouble();
      final photoHeight = srcImage.height.toDouble();

      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoCodec = await _loadLogoCodec(settings.logoPath!, targetWidth: 1600);
        if (logoCodec != null) {
          final logoFrame = await logoCodec.getNextFrame();
          logoImage = logoFrame.image;
          logoCodec.dispose();
          logoCodec = null;
        }
      }

      final data = WatermarkData(
        timestamp: entry.timestamp,
        operatorName: settings.operatorName,
        companyName: settings.companyName, // ← DITAMBAHKAN
        barcodeValue: entry.value,
        barcodeFormat: entry.barcodeFormat,
        latitude: entry.latitude,
        longitude: entry.longitude,
        locationName: entry.locationName,
        logoPath: settings.logoPath,
        position: settings.position,
        fontSize: settings.fontSize,
        backgroundOpacity: settings.backgroundOpacity,
        fontFamily: settings.fontFamily,
      );

      final layout = WatermarkFactory.create(settings.style);
      final metrics = layout.computeMetrics(
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        data: data,
      );

      if (metrics.canvasWidth <= 0 || metrics.canvasHeight <= 0) {
        throw Exception('Canvas size invalid');
      }

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
      outputImage = await picture.toImage(
        metrics.canvasWidth.round(),
        metrics.canvasHeight.round(),
      );

      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      outputImage.dispose();
      outputImage = null;

      if (byteData == null) {
        debugPrint('❌ Gagal encode PNG');
        return null;
      }

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(byteData.buffer.asUint8List());

      if (kDebugMode) debugPrint('✅ Watermark saved: $outputPath');
      return outputPath;
    } catch (e, stack) {
      if (kDebugMode) debugPrint('❌ Error: $e\n$stack');
      return null;
    } finally {
      codec?.dispose();
      logoCodec?.dispose();
      srcImage?.dispose();
      logoImage?.dispose();
      outputImage?.dispose();
    }
  }

  static Future<ui.Codec?> _loadLogoCodec(
    String logoPath, {
    required int targetWidth,
  }) async {
    try {
      final logoFile = File(logoPath);
      if (!await logoFile.exists()) return null;

      final logoBytes = await logoFile.readAsBytes();
      final logoTargetWidth = (targetWidth * 0.15).round().clamp(40, 200);
      return await ui.instantiateImageCodec(
        logoBytes,
        targetWidth: logoTargetWidth,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error memuat logo: $e');
      return null;
    }
  }
}
