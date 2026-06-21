import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import '../watermark/watermark_style.dart';

class WatermarkService {
  /// Mendapatkan ukuran optimal untuk gambar
  Future<int> _getOptimalTargetWidth(Uint8List imageBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      final originalWidth = frame.image.width;
      
      // Gunakan ukuran asli atau maksimal 1024, mana yang lebih kecil
      return originalWidth <= 1024 ? originalWidth : 1024;
    } catch (e) {
      debugPrint('⚠️ Error getting image size: $e');
      return 1024; // Fallback aman
    }
  }

  /// Mendapatkan posisi watermark berdasarkan style
  Rect _getWatermarkRect({
    required double width,
    required double height,
    required WatermarkStyle style,
    required double padding,
  }) {
    final bottomOffset = 120.0;
    final heightSize = 100.0;
    
    switch (style) {
      case WatermarkStyle.topLeft:
        return Rect.fromLTWH(
          padding,
          padding,
          width - (padding * 2),
          heightSize,
        );
      case WatermarkStyle.topRight:
        return Rect.fromLTWH(
          padding,
          padding,
          width - (padding * 2),
          heightSize,
        );
      case WatermarkStyle.bottomLeft:
        return Rect.fromLTWH(
          padding,
          height - heightSize - padding,
          width - (padding * 2),
          heightSize,
        );
      case WatermarkStyle.bottomRight:
        return Rect.fromLTWH(
          padding,
          height - heightSize - padding,
          width - (padding * 2),
          heightSize,
        );
      case WatermarkStyle.standard:
      default:
        return Rect.fromLTWH(
          padding,
          height - heightSize - padding,
          width - (padding * 2),
          heightSize,
        );
    }
  }

  /// Menambahkan watermark ke gambar
  Future<String?> addWatermark({
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
    try {
      // Baca file gambar
      final file = File(imagePath);
      if (!await file.exists()) {
        debugPrint('❌ File not found: $imagePath');
        return null;
      }

      final imageBytes = await file.readAsBytes();
      
      // Dapatkan ukuran optimal
      final targetWidth = await _getOptimalTargetWidth(imageBytes);
      
      // Decode gambar
      final codec = await ui.instantiateImageCodec(
        imageBytes,
        targetWidth: targetWidth,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // Buat canvas
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint();

      // Gambar original
      canvas.drawImage(image, Offset.zero, paint);

      // ── WATERMARK ──────────────────────────────────────────────
      final width = image.width.toDouble();
      final height = image.height.toDouble();

      // Background semi-transparan
      final bgPaint = Paint()
        ..color = const Color(0xCC000000)
        ..style = PaintingStyle.fill;

      final padding = 16.0;
      final fontSize = style.fontSize * (targetWidth / 1024);

      // Posisi watermark
      final rect = _getWatermarkRect(
        width: width,
        height: height,
        style: style,
        padding: padding,
      );
      
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        bgPaint,
      );

      // ── TEXT ──────────────────────────────────────────────────
      final textStyle = TextStyle(
        color: Colors.white,
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        fontFamily: 'Roboto',
      );
      final textSpan = TextSpan(
        text: operatorName,
        style: textStyle,
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout(maxWidth: width - 40);

      textPainter.paint(
        canvas,
        Offset(padding + 8, rect.top + 8),
      );

      // ── TIMESTAMP ─────────────────────────────────────────────
      final timeStyle = TextStyle(
        color: Colors.white70,
        fontSize: fontSize * 0.7,
        fontWeight: FontWeight.w400,
      );
      final timeSpan = TextSpan(
        text: DateFormat('dd/MM/yyyy HH:mm:ss').format(timestamp),
        style: timeStyle,
      );
      final timePainter = TextPainter(
        text: timeSpan,
        textDirection: TextDirection.ltr,
      );
      timePainter.layout(maxWidth: width - 40);

      timePainter.paint(
        canvas,
        Offset(padding + 8, rect.top + 30),
      );

      // ── BARCODE ──────────────────────────────────────────────
      if (barcodeValue != null && barcodeValue.isNotEmpty) {
        final barcodeStyle = TextStyle(
          color: Colors.amber,
          fontSize: fontSize * 0.8,
          fontWeight: FontWeight.w700,
        );
        final barcodeSpan = TextSpan(
          text: barcodeValue,
          style: barcodeStyle,
        );
        final barcodePainter = TextPainter(
          text: barcodeSpan,
          textDirection: TextDirection.ltr,
        );
        barcodePainter.layout(maxWidth: width - 40);

        barcodePainter.paint(
          canvas,
          Offset(padding + 8, rect.top + 50),
        );
      }

      // ── LOGO ──────────────────────────────────────────────────
      if (logoPath != null && logoPath.isNotEmpty) {
        try {
          final logoFile = File(logoPath);
          if (await logoFile.exists()) {
            final logoBytes = await logoFile.readAsBytes();
            // ✅ FIX: Ukuran logo proporsional
            final logoSize = (targetWidth * 0.04).round().clamp(30, 80);
            final logoCodec = await ui.instantiateImageCodec(
              logoBytes,
              targetWidth: logoSize,
            );
            final logoFrame = await logoCodec.getNextFrame();
            final logoImage = logoFrame.image;

            canvas.drawImage(
              logoImage,
              Offset(width - logoSize - 16, rect.top + 8),
              Paint(),
            );
          }
        } catch (e) {
          debugPrint('⚠️ Error loading logo: $e');
        }
      }

      // ── LOCATION ──────────────────────────────────────────────
      if (locationName != null && locationName.isNotEmpty) {
        final locStyle = TextStyle(
          color: Colors.white54,
          fontSize: fontSize * 0.5,
          fontWeight: FontWeight.w300,
        );
        final locSpan = TextSpan(
          text: locationName,
          style: locStyle,
        );
        final locPainter = TextPainter(
          text: locSpan,
          textDirection: TextDirection.ltr,
        );
        locPainter.layout(maxWidth: width - 40);

        // Posisi dinamis
        final yPosition = barcodeValue != null && barcodeValue.isNotEmpty
            ? rect.top + 75
            : rect.top + 50;
            
        locPainter.paint(
          canvas,
          Offset(padding + 8, yPosition),
        );
      }

      // ── COORDINATES ──────────────────────────────────────────
      if (latitude != null && longitude != null) {
        final coordText = '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
        final coordStyle = TextStyle(
          color: Colors.white38,
          fontSize: fontSize * 0.4,
          fontWeight: FontWeight.w300,
        );
        final coordSpan = TextSpan(
          text: coordText,
          style: coordStyle,
        );
        final coordPainter = TextPainter(
          text: coordSpan,
          textDirection: TextDirection.ltr,
        );
        coordPainter.layout(maxWidth: width - 40);

        // Posisi dinamis
        final hasLocation = locationName != null && locationName.isNotEmpty;
        final yPosition = hasLocation
            ? rect.top + 85
            : (barcodeValue != null && barcodeValue.isNotEmpty
                ? rect.top + 75
                : rect.top + 50);
            
        coordPainter.paint(
          canvas,
          Offset(padding + 8, yPosition),
        );
      }

      // ── SAVE ──────────────────────────────────────────────────
      final picture = recorder.endRecording();
      final outputImage = await picture.toImage(
        image.width,
        image.height,
      );
      final byteData = await outputImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      
      if (byteData == null) {
        debugPrint('❌ Failed to encode image');
        return null;
      }

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(byteData.buffer.asUint8List());

      debugPrint('✅ Watermark saved: $outputPath');
      return outputPath;
      
    } catch (e, stack) {
      debugPrint('❌ Error adding watermark: $e\n$stack');
      return null;
    }
  }

  /// Bersihkan file watermark sementara
  Future<void> cleanupTempWatermarks(Directory tempDir) async {
    try {
      if (!await tempDir.exists()) return;
      
      final files = await tempDir.list().toList();
      int count = 0;
      
      for (var entity in files) {
        if (entity is File && entity.path.contains('wm_')) {
          await entity.delete();
          count++;
        }
      }
      
      if (count > 0) {
        debugPrint('✅ Cleaned $count temp watermark files');
      }
    } catch (e) {
      debugPrint('⚠️ Error cleaning watermarks: $e');
    }
  }

  /// Kompres gambar jika terlalu besar
  Future<Uint8List> compressImage(Uint8List bytes, {int quality = 65}) async {
    try {
      final img.Image image = img.decodeImage(bytes)!;
      final compressed = img.encodeJpg(image, quality: quality);
      return Uint8List.fromList(compressed);
    } catch (e) {
      debugPrint('⚠️ Error compressing image: $e');
      return bytes;
    }
  }
}
