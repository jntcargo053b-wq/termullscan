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

  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    debugPrint('🎯 ===== WATERMARK RENDER START =====');
    debugPrint('  Style: ${settings.style.name}');
    debugPrint('  Position: ${settings.position.name}');
    debugPrint('  FontSize: ${settings.fontSize}');
    debugPrint('  Opacity: ${settings.backgroundOpacity}');
    debugPrint('  FontFamily: ${settings.fontFamily}'); // ✅ TAMBAHKAN
    debugPrint('  Operator: ${settings.operatorName}');
    debugPrint('  Barcode: ${entry.value}');
    debugPrint('======================================');

    // ✅ Selalu gunakan layout, tidak ada fallback ke legacy
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
      final targetWidth = await _getOptimalTargetWidth(imageBytes);

      codec = await ui.instantiateImageCodec(
        imageBytes,
        targetWidth: targetWidth,
      );
      final frame = await codec.getNextFrame();
      srcImage = frame.image;

      final photoWidth = srcImage.width.toDouble();
      final photoHeight = srcImage.height.toDouble();

      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoCodec = await _loadLogoCodec(settings.logoPath!, targetWidth: targetWidth);
        if (logoCodec != null) {
          final logoFrame = await logoCodec.getNextFrame();
          logoImage = logoFrame.image;
        }
      }

      final data = WatermarkData(
        timestamp: entry.timestamp,
        operatorName: settings.operatorName,
        barcodeValue: entry.value,
        barcodeFormat: entry.barcodeFormat,
        latitude: entry.latitude,
        longitude: entry.longitude,
        locationName: entry.locationName,
        logoPath: settings.logoPath,
        position: settings.position,
        fontSize: settings.fontSize,
        backgroundOpacity: settings.backgroundOpacity,
        fontFamily: settings.fontFamily, // ✅ TAMBAHKAN
      );

      final layout = WatermarkFactory.create(settings.style);
      debugPrint('✅ Layout created: ${layout.runtimeType}');

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
      final canvasWidth = metrics.canvasWidth.round();
      final canvasHeight = metrics.canvasHeight.round();

      outputImage = await picture.toImage(canvasWidth, canvasHeight);

      final ByteData? byteData;
      try {
        byteData = await outputImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
      } finally {
        outputImage.dispose();
        outputImage = null;
      }

      if (byteData == null) {
        debugPrint('❌ Gagal encode PNG');
        return null;
      }

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(byteData.buffer.asUint8List());

      debugPrint('✅ Watermark saved with style: ${settings.style.name}');
      debugPrint('   Output: $outputPath');
      return outputPath;
    } catch (e, stack) {
      debugPrint('❌ Error: $e\n$stack');
      return null;
    } finally {
      codec?.dispose();
      logoCodec?.dispose();
      srcImage?.dispose();
      logoImage?.dispose();
      outputImage?.dispose();
    }
  }

  static Future<int> _getOptimalTargetWidth(Uint8List imageBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      try {
        final frame = await codec.getNextFrame();
        final originalWidth = frame.image.width;
        return originalWidth <= 1024 ? originalWidth : 1024;
      } finally {
        codec.dispose();
      }
    } catch (e) {
      debugPrint('⚠️ Error membaca ukuran gambar: $e');
      return 1024;
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
      debugPrint('⚠️ Error memuat logo: $e');
      return null;
    }
  }
}
