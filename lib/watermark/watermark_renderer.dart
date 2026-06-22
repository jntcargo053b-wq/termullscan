import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import '../models/scan_entry.dart';
import 'models/watermark_data.dart';
import 'models/watermark_style.dart';
import 'watermark_factory.dart';
import 'watermark_settings.dart';
import '../services/watermark_service.dart';

class WatermarkRenderer {
  static const Set<WatermarkStyle> _stylesWithRealRenderer = {
    WatermarkStyle.minimal,
    WatermarkStyle.professional,
    WatermarkStyle.polaroid,
    WatermarkStyle.stamp,
  };

  static final WatermarkService _legacyService = WatermarkService();

  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    if (!_stylesWithRealRenderer.contains(settings.style)) {
      debugPrint(
        '⚠️ WatermarkRenderer: "${settings.style.name}" belum punya render asli, fallback ke legacy.',
      );
      return _legacyService.addWatermark(
        imagePath: imagePath,
        outputPath: outputPath,
        operatorName: settings.operatorName,
        style: settings.style,
        barcodeValue: entry.value,
        barcodeFormat: entry.barcodeFormat,
        timestamp: entry.timestamp,
        latitude: entry.latitude,
        longitude: entry.longitude,
        locationName: entry.locationName,
        logoPath: settings.logoPath,
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
      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoImage = await _loadLogo(settings.logoPath!, targetWidth: targetWidth);
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
      );

      final layout = WatermarkFactory.create(settings.style);
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

      debugPrint('✅ WatermarkRenderer: watermark (${settings.style.name}) disimpan: $outputPath');
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
