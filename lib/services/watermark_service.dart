import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Render watermark gaya POLAROID FIELD OPS.
Future<String?> _renderWatermark({
  required String imagePath,
  required String outputPath,
  required String? barcodeValue,
  required String? barcodeFormat,
  required DateTime timestamp,
  required double? latitude,
  required double? longitude,
  required String? locationName,
  required String operatorName,
  required String? logoPath,
}) async {
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
    final srcImage = frame.image;

    final photoWidth = srcImage.width.toDouble();
    final photoHeight = srcImage.height.toDouble();

    debugPrint(
        '🖼️ Watermark: rendering polaroid for ${photoWidth.toInt()}x${photoHeight.toInt()}');

    final baseSize = math.min(photoWidth, photoHeight);
    final padding = baseSize * 0.06;

    final textLineCount = _countTextLines(
      hasBarcode: barcodeValue != null && barcodeValue.isNotEmpty,
      hasOperator: operatorName.isNotEmpty,
      hasLocation: latitude != null && longitude != null,
    );
    final bottomStripHeight = math.max(
      photoHeight * 0.22,
      textLineCount * (baseSize * 0.032 * 1.6) + padding * 2.5,
    );

    final canvasWidth = photoWidth + (padding * 2);
    final canvasHeight = photoHeight + padding + bottomStripHeight;

    // Load logo
    ui.Image? logoImage;
    double? logoDrawW, logoDrawH;
    if (logoPath != null && logoPath.isNotEmpty) {
      try {
        final logoFile = File(logoPath);
        if (await logoFile.exists()) {
          final logoBytes = await logoFile.readAsBytes();
          final logoCodec =
              await ui.instantiateImageCodec(logoBytes);
          final logoFrame = await logoCodec.getNextFrame();
          logoImage = logoFrame.image;

          final logoMaxH = bottomStripHeight * 0.45;
          final logoW = logoImage.width.toDouble();
          final logoH = logoImage.height.toDouble();
          final scale = logoMaxH / logoH;
          logoDrawW = logoW * scale;
          logoDrawH = logoH * scale;

          debugPrint(
              '🖼️ Watermark: logo loaded (${logoImage.width}x${logoImage.height})');
        }
      } catch (e) {
        debugPrint('⚠️ Watermark: logo load failed - $e');
      }
    }

    final recorder = ui.PictureRecorder();
    final canvas =
        Canvas(recorder, Rect.fromLTWH(0, 0, canvasWidth, canvasHeight));

    // Paper background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, canvasWidth, canvasHeight),
      Paint()..color = const Color(0xFFF5F5F0),
    );

    // Shadow
    final shadowPath = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, canvasWidth, canvasHeight),
        const Radius.circular(2),
      ));
    canvas.drawShadow(shadowPath, Colors.black.withOpacity(0.3), 14, true);

    // Photo area
    final photoRect = Rect.fromLTWH(padding, padding, photoWidth, photoHeight);
    canvas.drawRect(photoRect, Paint()..color = const Color(0xFF111111));
    canvas.drawRect(
      photoRect,
      Paint()
        ..color = const Color(0xFFDDDDDD)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, baseSize * 0.002)
        ..isAntiAlias = true,
    );

    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      photoRect,
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true
        ..color = const Color(0xDDFFFFFF),
    );

    // Scan line
    final scanLineY = padding + photoHeight * 0.35;
    canvas.drawLine(
      Offset(padding, scanLineY),
      Offset(padding + photoWidth, scanLineY),
      Paint()
        ..color = const Color(0x44FFAA00)
        ..strokeWidth = math.max(1.5, baseSize * 0.002)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
        ..isAntiAlias = true,
    );

    // ── TEXT ──────────────────────────────────────────────────────────
    final isManual = barcodeFormat == 'MANUAL';
    final dateStr =
        DateFormat('MMM dd, yyyy • HH:mm:ss').format(timestamp).toUpperCase();

    String gpsStr;
    if (locationName != null && locationName.isNotEmpty) {
      gpsStr = locationName;
    } else if (latitude != null && longitude != null) {
      final latDir = latitude >= 0 ? 'N' : 'S';
      final lonDir = longitude >= 0 ? 'E' : 'W';
      gpsStr =
          '${latitude.abs().toStringAsFixed(4)}° $latDir, '
          '${longitude.abs().toStringAsFixed(4)}° $lonDir';
    } else {
      gpsStr = 'No location data';
    }

    final hasBadgeOrLogo = isManual || logoImage != null;
    final rightReservedWidth = hasBadgeOrLogo
        ? math.max(
            isManual ? baseSize * 0.10 : 0,
            logoDrawW ?? 0,
          ) +
            padding * 0.5
        : 0.0;

    final textX = padding + 6;
    final textContentWidth =
        canvasWidth - (padding * 2) - 12 - rightReservedWidth;
    double textY = photoHeight + padding + (bottomStripHeight * 0.06);

    void drawText(String text, Color color, double fontSize,
        {FontWeight fontWeight = FontWeight.normal, int maxLines = 1}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: fontWeight,
            height: 1.3,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: maxLines,
        ellipsis: '…',
      )..layout(maxWidth: textContentWidth);
      tp.paint(canvas, Offset(textX, textY));
      textY += tp.height + fontSize * 0.3;
    }

    if (barcodeValue != null && barcodeValue.isNotEmpty) {
      drawText(barcodeValue, const Color(0xFF2C2C2C), baseSize * 0.045,
          fontWeight: FontWeight.w800);
    }

    if (operatorName.isNotEmpty) {
      drawText('OP: $operatorName', const Color(0xFF8B6914), baseSize * 0.032,
          fontWeight: FontWeight.w700);
    }

    drawText(dateStr, const Color(0xFF666666), baseSize * 0.024,
        fontWeight: FontWeight.w500);

    drawText(gpsStr, const Color(0xFF888888), baseSize * 0.024, maxLines: 2);

    // ── MANUAL BADGE ──────────────────────────────────────────────────
    if (isManual) {
      final badgeW = baseSize * 0.09;
      final badgeH = baseSize * 0.028;
      final badgeX = canvasWidth - padding - badgeW - 6;
      final badgeY = photoHeight + padding + (bottomStripHeight * 0.10);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(badgeX, badgeY, badgeW, badgeH),
          Radius.circular(badgeH * 0.2),
        ),
        Paint()
          ..color = const Color(0xFFE67E22)
          ..isAntiAlias = true,
      );

      final badgeFontSize = badgeH * 0.55;
      final badgeTp = TextPainter(
        // ✅ FIX: TextSpan, bukan TextStyle
        text: const TextSpan(
          text: 'MANUAL',
          style: TextStyle(
            color: Colors.white,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      badgeTp.paint(
        canvas,
        Offset(
          badgeX + (badgeW - badgeTp.width) / 2,
          badgeY + (badgeH - badgeTp.height) / 2,
        ),
      );
    }

    // ── LOGO ──────────────────────────────────────────────────────────
    if (logoImage != null && logoDrawW != null && logoDrawH != null) {
      final logoX = canvasWidth - padding - logoDrawW - 6;
      final logoY = isManual
          ? photoHeight +
              padding +
              (bottomStripHeight * 0.10) +
              (baseSize * 0.028) +
              4
          : photoHeight + padding + (bottomStripHeight - logoDrawH) / 2;

      final clampedLogoY = math.min(
        logoY,
        photoHeight + padding + bottomStripHeight - logoDrawH - 4,
      );

      canvas.drawImageRect(
        logoImage,
        Rect.fromLTWH(
            0, 0, logoImage.width.toDouble(), logoImage.height.toDouble()),
        Rect.fromLTWH(logoX, clampedLogoY, logoDrawW, logoDrawH),
        Paint()
          ..filterQuality = FilterQuality.high
          ..isAntiAlias = true
          ..colorFilter = ColorFilter.mode(
            Colors.white.withOpacity(0.25),
            BlendMode.modulate,
          ),
      );
      logoImage.dispose();
    }

    // ── FINALIZE ──────────────────────────────────────────────────────
    final picture = recorder.endRecording();
    final img =
        await picture.toImage(canvasWidth.toInt(), canvasHeight.toInt());
    srcImage.dispose();

    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();

    if (byteData == null) {
      debugPrint('⚠️ Watermark: byteData is null');
      return null;
    }

    final pngBytes = byteData.buffer.asUint8List();
    await File(outputPath).writeAsBytes(pngBytes);

    debugPrint(
        '✅ Watermark: saved polaroid ${canvasWidth.toInt()}x${canvasHeight.toInt()} to $outputPath');
    return outputPath;
  } catch (e, stack) {
    debugPrint('❌ Watermark render error: $e');
    debugPrint('   Stack: $stack');
    return null;
  }
}

int _countTextLines({
  required bool hasBarcode,
  required bool hasOperator,
  required bool hasLocation,
}) {
  int lines = 0;
  if (hasBarcode) lines++;
  if (hasOperator) lines++;
  lines++;
  if (hasLocation) lines++;
  return lines + 1;
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
    debugPrint('🖼️ WatermarkService.addWatermark called');
    debugPrint('   imagePath: $imagePath');
    debugPrint('   outputPath: $outputPath');

    return _renderWatermark(
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
    );
  }
}
