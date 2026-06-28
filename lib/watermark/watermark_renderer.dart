// ============================================================
// lib/watermark/watermark_renderer.dart
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
  /// Proses terjadi di UI thread, namun dengan single decode & dispose dini
  /// performa tetap ringan untuk gambar yang sudah di-resize ke 1600px.
  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    if (kDebugMode) {
      debugPrint('🎯 ===== WATERMARK RENDER START =====');
      debugPrint('  Style: ${settings.style.name}');
      debugPrint('  Position: ${settings.position.name}');
      debugPrint('  FontSize: ${settings.fontSize}');
      debugPrint('  Opacity: ${settings.backgroundOpacity}');
      debugPrint('  FontFamily: ${settings.fontFamily}');
      debugPrint('  Operator: ${settings.operatorName}');
      debugPrint('  Barcode: ${entry.value}');
      debugPrint('======================================');
    }

    ui.Image? srcImage;
    ui.Image? logoImage;
    ui.Codec? codec;
    ui.Codec? logoCodec;
    ui.Image? outputImage;

    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        if (kDebugMode) debugPrint('❌ File tidak ditemukan: $imagePath');
        return null;
      }

      final imageBytes = await file.readAsBytes();

      // ✅ Single decode – langsung ambil dimensi + gambar
      codec = await ui.instantiateImageCodec(
        imageBytes,
        targetWidth: 1600,
      );
      final frame = await codec.getNextFrame();
      srcImage = frame.image;

      // Codec sudah tidak diperlukan – dispose segera
      codec.dispose();
      codec = null;

      final photoWidth = srcImage.width.toDouble();
      final photoHeight = srcImage.height.toDouble();

      // 3. Muat logo opsional (juga single decode)
      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoCodec = await _loadLogoCodec(settings.logoPath!, targetWidth: 1600);
        if (logoCodec != null) {
          final logoFrame = await logoCodec.getNextFrame();
          logoImage = logoFrame.image;
          logoCodec.dispose();
          logoCodec = null;
        }
      }

      // 4. Siapkan data watermark
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
        fontFamily: settings.fontFamily,
      );

      final layout = WatermarkFactory.create(settings.style);
      if (kDebugMode) debugPrint('✅ Layout created: ${layout.runtimeType}');

      // 5. Hitung ukuran kanvas
      final metrics = layout.computeMetrics(
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        data: data,
      );

      if (metrics.canvasWidth <= 0 || metrics.canvasHeight <= 0) {
        throw Exception('Canvas size invalid');
      }

      // 6. Gambar di canvas UI (picture recorder)
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

      // 7. Render gambar akhir
      outputImage = await picture.toImage(canvasWidth, canvasHeight);

      // 8. Encode ke PNG lalu tulis file
      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      outputImage.dispose();
      outputImage = null; // hindari double dispose

      if (byteData == null) {
        if (kDebugMode) debugPrint('❌ Gagal encode PNG');
        return null;
      }

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(byteData.buffer.asUint8List());

      if (kDebugMode) {
        debugPrint('✅ Watermark saved with style: ${settings.style.name}');
        debugPrint('   Output: $outputPath');
      }
      return outputPath;
    } catch (e, stack) {
      if (kDebugMode) debugPrint('❌ Error: $e\n$stack');
      return null;
    } finally {
      // Pastikan semua native resource dibersihkan
      codec?.dispose();
      logoCodec?.dispose();
      srcImage?.dispose();
      logoImage?.dispose();
      outputImage?.dispose();
    }
  }

  /// Memuat logo dalam ukuran yang proporsional terhadap lebar target.
  static Future<ui.Codec?> _loadLogoCodec(
    String logoPath, {
    required int targetWidth,
  }) async {
    try {
      final logoFile = File(logoPath);
      if (!await logoFile.exists()) return null;

      final logoBytes = await logoFile.readAsBytes();
      // Ukuran logo = ~15% dari lebar target, dibatasi 40–200 px
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
