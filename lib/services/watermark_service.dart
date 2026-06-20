import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../watermark/models/watermark_data.dart';
import '../watermark/models/watermark_style.dart';
import '../watermark/watermark_factory.dart';

Future<String?> _renderWatermark({
  required String imagePath,
  required String outputPath,
  required WatermarkStyle style,
  required String? barcodeValue,
  required String? barcodeFormat,
  required DateTime timestamp,
  required double? latitude,
  required double? longitude,
  required String? locationName,
  required String operatorName,
  required String? logoPath,
}) async {
  ui.Image? srcImage;
  ui.Image? logoImage;
  try {
    final file = File(imagePath);
    if (!await file.exists()) {
      debugPrint('⚠️ Watermark: file not found at $imagePath');
      return null;
    }

    final imageBytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(
      imageBytes,
      targetWidth: 2048,
    );
    final frame = await codec.getNextFrame();
    srcImage = frame.image;

    final photoWidth = srcImage.width.toDouble();
    final photoHeight = srcImage.height.toDouble();

    // 🔥 Langsung pakai Layout
    final layout = WatermarkFactory.createLayout(style);
    debugPrint('🖼️ Watermark: using layout ${layout.displayName}');

    // Load logo, jika ada.
    if (logoPath != null && logoPath.isNotEmpty) {
      try {
        final logoFile = File(logoPath);
        if (await logoFile.exists()) {
          final logoBytes = await logoFile.readAsBytes();
          final logoCodec = await ui.instantiateImageCodec(logoBytes);
          final logoFrame = await logoCodec.getNextFrame();
          logoImage = logoFrame.image;
          debugPrint('🖼️ Watermark: logo loaded');
        }
      } catch (e) {
        debugPrint('⚠️ Watermark: logo load failed - $e');
      }
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

    // Hitung metrik dan kanvas
    final metrics = layout.computeMetrics(
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      data: data,
    );

    final canvasSize = layout.computeCanvasSize(
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      data: data,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, canvasSize.width, canvasSize.height),
    );

    // Gambar via layout
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
    final img = await picture.toImage(
      canvasSize.width.toInt(),
      canvasSize.height.toInt(),
    );

    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();

    if (byteData == null) {
      debugPrint('⚠️ Watermark: byteData is null');
      return null;
    }

    final pngBytes = byteData.buffer.asUint8List();
    await File(outputPath).writeAsBytes(pngBytes);

    debugPrint('✅ Watermark: saved ${layout.displayName} ${canvasSize.width.toInt()}x${canvasSize.height.toInt()}');
    return outputPath;
  } catch (e, stack) {
    debugPrint('❌ Watermark render error: $e');
    debugPrint('   Stack: $stack');
    return null;
  } finally {
    srcImage?.dispose();
    logoImage?.dispose();
  }
}

class WatermarkService {
  static final WatermarkService _instance = WatermarkService._();
  factory WatermarkService() => _instance;
  WatermarkService._();

  Future<String?> addWatermark({
    required String imagePath,
    required String outputPath,
    required String operatorName,
    WatermarkStyle style = WatermarkStyle.polaroid,
    String? barcodeValue,
    String? barcodeFormat,
    required DateTime timestamp,
    double? latitude,
    double? longitude,
    String? locationName,
    String? logoPath,
  }) async {
    debugPrint('🖼️ WatermarkService.addWatermark called (style: ${style.name})');
    return _renderWatermark(
      imagePath: imagePath,
      outputPath: outputPath,
      style: style,
      barcodeValue: barcodeValue,
      barcodeFormat: barcodeFormat,
      timestamp: timestamp,
      latitude: latitude,
      longitude: longitude,
      locationName: locationName,
      operatorName: operatorName,
      logoPath: logoPath,
    );
  }
}
