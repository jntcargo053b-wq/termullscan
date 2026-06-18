import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ── Isolate payload ─────────────────────────────────────────────────────
class _WatermarkTask {
  final String imagePath;
  final String outputPath;
  final String? barcodeValue;
  final String? barcodeFormat;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String operatorName;
  final String? logoPath;
  final SendPort replyTo;

  const _WatermarkTask({
    required this.imagePath,
    required this.outputPath,
    required this.barcodeValue,
    required this.barcodeFormat,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.locationName,
    required this.operatorName,
    required this.logoPath,
    required this.replyTo,
  });
}

/// Entry-point isolate — top-level function.
void _watermarkIsolate(_WatermarkTask task) async {
  try {
    final result = await _renderWatermark(task);
    task.replyTo.send(result);
  } catch (e) {
    task.replyTo.send(null);
  }
}

/// Render watermark gaya POLAROID FIELD OPS (match design spec).
Future<String?> _renderWatermark(_WatermarkTask task) async {
  final imageBytes = await File(task.imagePath).readAsBytes();
  final codec = await ui.instantiateImageCodec(imageBytes);
  final frame = await codec.getNextFrame();
  final srcImage = frame.image;

  final photoWidth = srcImage.width.toDouble();
  final photoHeight = srcImage.height.toDouble();

  // ── POLAROID LAYOUT (matching HTML design) ───────────────────────────
  final padding = photoWidth * 0.06; // 6% white border (left/right/top)
  final bottomStripHeight = photoHeight * 0.22; // bottom white area
  final canvasWidth = photoWidth + (padding * 2);
  final canvasHeight = photoHeight + padding + bottomStripHeight;

  // Load logo
  ui.Image? logoImage;
  if (task.logoPath != null) {
    try {
      final logoFile = File(task.logoPath!);
      if (await logoFile.exists()) {
        final logoBytes = await logoFile.readAsBytes();
        final logoCodec =
            await ui.instantiateImageCodec(logoBytes, targetWidth: 120);
        final logoFrame = await logoCodec.getNextFrame();
        logoImage = logoFrame.image;
      }
    } catch (_) {}
  }

  final recorder = ui.PictureRecorder();
  final canvas =
      Canvas(recorder, Rect.fromLTWH(0, 0, canvasWidth, canvasHeight));

  // ── PAPER BACKGROUND (krem polaroid #F5F5F0) ─────────────────────────
  final paperBg = Paint()..color = const Color(0xFFF5F5F0);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, canvasWidth, canvasHeight),
    paperBg,
  );

  // ── DROP SHADOW ──────────────────────────────────────────────────────
  final shadowPaint = Paint()
    ..color = const Color(0x33000000)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
  canvas.drawRect(
    Rect.fromLTWH(4, 6, canvasWidth - 4, canvasHeight - 4),
    shadowPaint,
  );

  // ── PHOTO IN "VIEWFINDER" (black bg + image) ─────────────────────────
  final photoRect = Rect.fromLTWH(padding, padding, photoWidth, photoHeight);

  // Black background behind photo
  canvas.drawRect(photoRect, Paint()..color = const Color(0xFF000000));

  // Inner shadow/border effect
  canvas.drawRect(
    photoRect,
    Paint()
      ..color = const Color(0xFFE0E0E0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5,
  );

  // Draw image with slight opacity like the HTML (opacity-80 mix-blend-screen)
  canvas.drawImageRect(
    srcImage,
    Rect.fromLTWH(0, 0, photoWidth, photoHeight),
    photoRect,
    Paint()
      ..filterQuality = FilterQuality.high
      ..color = const Color(0xCCFFFFFF), // ~80% opacity
  );

  // ── SCAN LINE (optional subtle orange line) ──────────────────────────
  final scanLinePaint = Paint()
    ..color = const Color(0x66FFAA00)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
  canvas.drawLine(
    Offset(padding, padding + photoHeight * 0.3),
    Offset(padding + photoWidth, padding + photoHeight * 0.3),
    scanLinePaint..strokeWidth = 2,
  );

  // ── BOTTOM WHITE AREA - TEKS ─────────────────────────────────────────
  final isManual = task.barcodeFormat == 'MANUAL';
  final dateStr = DateFormat('MMM dd, yyyy • HH:mm:ss')
      .format(task.timestamp)
      .toUpperCase();
  final gpsStr = task.locationName ??
      (task.latitude != null
          ? '${task.latitude!.toStringAsFixed(4)}° N, ${task.longitude!.toStringAsFixed(4)}° W'
          : '-- • --');

  final textX = padding + 4; // px kecil dari padding
  final contentWidth = canvasWidth - (padding * 2) - 8;
  double textY = photoHeight + padding + (bottomStripHeight * 0.08);

  // Helper: draw text
  void drawText(
    String text, {
    required Color color,
    required double fontSize,
    FontWeight fontWeight = FontWeight.normal,
    double? letterSpacing,
    double? extraSpacing,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
          letterSpacing: letterSpacing,
          fontFamily: 'Geist',
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: contentWidth);
    tp.paint(canvas, Offset(textX, textY));
    textY += (fontSize * 1.55) + (extraSpacing ?? 0);
  }

  // 1. Barcode value - large bold dark
  if (task.barcodeValue != null && task.barcodeValue!.isNotEmpty) {
    drawText(
      task.barcodeValue!,
      color: const Color(0xFF2C2C2C),
      fontSize: photoWidth * 0.045,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
    );
  }

  // Spasi kecil
  textY += 2;

  // 2. Operator name - gold/brown
  if (task.operatorName.isNotEmpty) {
    drawText(
      'OP: ${task.operatorName}',
      color: const Color(0xFF8B6914),
      fontSize: photoWidth * 0.032,
      fontWeight: FontWeight.w700,
    );
  }

  // 3. Date & Time
  drawText(
    dateStr,
    color: const Color(0xFF666666),
    fontSize: photoWidth * 0.025,
    fontWeight: FontWeight.w500,
  );

  // 4. GPS coordinates (dengan icon text)
  drawText(
    gpsStr,
    color: const Color(0xFF888888),
    fontSize: photoWidth * 0.025,
    fontWeight: FontWeight.w400,
  );

  // ── BADGE & LOGO (kanan bawah) ───────────────────────────────────────
  final rightX = canvasWidth - padding - 4;

  // Manual badge
  if (isManual) {
    const badgeW = 52.0;
    const badgeH = 16.0;
    final badgeRect = Rect.fromLTWH(
      rightX - badgeW,
      photoHeight + padding + (bottomStripHeight * 0.15),
      badgeW,
      badgeH,
    );

    // Badge background
    canvas.drawRRect(
      RRect.fromRectAndRadius(badgeRect, const Radius.circular(3)),
      Paint()..color = const Color(0xFFE67E22),
    );

    // Badge text "MANUAL"
    final badgeTp = TextPainter(
      text: const TextSpan(
        text: 'MANUAL',
        style: TextStyle(
          color: Colors.white,
          fontSize: 8,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    badgeTp.paint(
      canvas,
      Offset(
        badgeRect.center.dx - badgeTp.width / 2,
        badgeRect.center.dy - badgeTp.height / 2,
      ),
    );
  }

  // Logo (kanan bawah, kecil, opacity rendah)
  if (logoImage != null) {
    final logoSize = bottomStripHeight * 0.42;
    final logoW = logoImage.width.toDouble();
    final logoH = logoImage.height.toDouble();
    final scale = logoSize / (logoW > logoH ? logoW : logoH);
    final drawW = logoW * scale;
    final drawH = logoH * scale;

    final logoX = rightX - drawW;
    final logoY = photoHeight + padding + (bottomStripHeight - drawH) / 2;

    canvas.drawImageRect(
      logoImage,
      Rect.fromLTWH(0, 0, logoW, logoH),
      Rect.fromLTWH(logoX, logoY, drawW, drawH),
      Paint()
        ..filterQuality = FilterQuality.high
        ..color = const Color(0x33000000), // opacity ~20% grayscale effect
    );
    logoImage.dispose();
  }

  // ── GRAIN TEXTURE OVERLAY ────────────────────────────────────────────
  // (subtle noise pattern via random dots)
  final grainPaint = Paint()
    ..color = const Color(0x08000000)
    ..style = PaintingStyle.fill;
  final rng = DateTime.now().millisecondsSinceEpoch;
  for (int i = 0; i < 200; i++) {
    final x = ((rng + i * 7) % canvasWidth.toInt()).toDouble();
    final y = ((rng + i * 13) % canvasHeight.toInt()).toDouble();
    canvas.drawCircle(Offset(x, y), 0.5, grainPaint);
  }

  // ── FINALIZE ─────────────────────────────────────────────────────────
  final picture = recorder.endRecording();
  final img =
      await picture.toImage(canvasWidth.toInt(), canvasHeight.toInt());
  srcImage.dispose();

  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();

  final pngBytes = byteData!.buffer.asUint8List();
  await File(task.outputPath).writeAsBytes(pngBytes);
  return task.outputPath;
}

// ═══════════════════════════════════════════════════════════════════════════
class WatermarkService {
  static final WatermarkService _instance = WatermarkService._();
  factory WatermarkService() => _instance;
  WatermarkService._();

  Future<String?> addWatermark({
    required String imagePath,
    required String outputPath,
    required String operatorName,
    String? barcodeValue,
    String? barcodeFormat,
    required DateTime timestamp,
    double? latitude,
    double? longitude,
    String? locationName,
    String? logoPath,
  }) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return null;

      final receivePort = ReceivePort();

      final task = _WatermarkTask(
        imagePath: imagePath,
        outputPath: outputPath,
        barcodeValue: barcodeValue,
        barcodeFormat: barcodeFormat,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        locationName: locationName,
        operatorName: operatorName,
        logoPath: logoPath,
        replyTo: receivePort.sendPort,
      );

      await Isolate.spawn(_watermarkIsolate, task);
      final result = await receivePort.first as String?;
      receivePort.close();

      return result;
    } catch (e) {
      debugPrint('WatermarkService.addWatermark error: $e');
      return null;
    }
  }
}
