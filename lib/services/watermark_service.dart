import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import '../watermark/watermark_style.dart';

class WatermarkService {
  /// Tambahkan fungsi helper untuk mendapatkan ukuran optimal
  Future<int> _getOptimalTargetWidth(Uint8List imageBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      final originalWidth = frame.image.width;
      
      // Gunakan ukuran asli atau maksimal 1024, mana yang lebih kecil
      // ✅ FIX: Dari 2048 menjadi dinamis
      return originalWidth <= 1024 ? originalWidth : 1024;
    } catch (e) {
      debugPrint('Error getting image size: $e');
      return 1024; // Fallback aman
    }
  }

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
        debugPrint('File not found: $imagePath');
        return null;
      }

      final imageBytes = await file.readAsBytes();
      
      // ✅ FIX: Dapatkan ukuran optimal (dinamis, bukan fixed 2048)
      final targetWidth = await _getOptimalTargetWidth(imageBytes);
      
      // Decode gambar dengan ukuran optimal
      final codec = await ui.instantiateImageCodec(
        imageBytes,
        targetWidth: targetWidth,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // Buat canvas untuk watermark
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint();

      // Gambar original
      canvas.drawImage(image, Offset.zero, paint);

      // ── WATERMARK LOGIC ──────────────────────────────────────────────
      final width = image.width.toDouble();
      final height = image.height.toDouble();

      // Background semi-transparan
      final bgPaint = Paint()
        ..color = const Color(0xCC000000)
        ..style = PaintingStyle.fill;

      final padding = 16.0;
      final fontSize = style.fontSize * (targetWidth / 1024); // Scale font

      // Posisi watermark (bawah)
      final rect = Rect.fromLTWH(
        padding,
        height - 120 - padding,
        width - (padding * 2),
        100,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        bgPaint,
      );

      // ── TEXT WATERMARK ──────────────────────────────────────────────
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

      // Gambar teks
      textPainter.paint(
        canvas,
        Offset(padding + 8, height - 100 - padding),
      );

      // ── TIMESTAMP ────────────────────────────────────────────────────
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
        Offset(padding + 8, height - 60 - padding),
      );

      // ── BARCODE VALUE (jika ada) ────────────────────────────────────
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
          Offset(padding + 8, height - 80 - padding),
        );
      }

      // ── LOGO (jika ada) ──────────────────────────────────────────────
      if (logoPath != null && logoPath.isNotEmpty) {
        try {
          final logoFile = File(logoPath);
          if (await logoFile.exists()) {
            final logoBytes = await logoFile.readAsBytes();
            final logoCodec = await ui.instantiateImageCodec(
              logoBytes,
              targetWidth: 40,
            );
            final logoFrame = await logoCodec.getNextFrame();
            final logoImage = logoFrame.image;

            canvas.drawImage(
              logoImage,
              Offset(width - 60, height - 60),
              Paint(),
            );
          }
        } catch (e) {
          debugPrint('Error loading logo: $e');
        }
      }

      // ── LOCATION (jika ada) ──────────────────────────────────────────
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

        locPainter.paint(
          canvas,
          Offset(padding + 8, height - 35 - padding),
        );
      }

      // ── COORDINATES (jika ada) ──────────────────────────────────────
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

        coordPainter.paint(
          canvas,
          Offset(padding + 8, height - 15 - padding),
        );
      }

      // ── SAVE IMAGE ──────────────────────────────────────────────────
      final picture = recorder.endRecording();
      final outputImage = await picture.toImage(
        image.width,
        image.height,
      );
      final byteData = await outputImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      
      if (byteData == null) {
        debugPrint('Failed to encode image');
        return null;
      }

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(byteData.buffer.asUint8List());

      return outputPath;
    } catch (e, stack) {
      debugPrint('Error adding watermark: $e\n$stack');
      return null;
    }
  }

  /// ✅ TAMBAHAN: Cleanup method untuk membersihkan file watermark sementara
  Future<void> cleanupTempWatermarks(Directory tempDir) async {
    try {
      if (!await tempDir.exists()) return;
      
      final files = await tempDir.list().toList();
      for (var entity in files) {
        if (entity is File && entity.path.contains('wm_')) {
          await entity.delete();
          debugPrint('✅ Cleaned temp watermark: ${entity.path}');
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error cleaning watermarks: $e');
    }
  }
}
