import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/watermark_data.dart';
import 'base_renderer.dart';

/// Gaya POLAROID FIELD OPS — bingkai kertas krem dengan strip info di
/// bawah foto, mirip cetakan polaroid lapangan.
class PolaroidRenderer implements WatermarkRenderer {
  @override
  String get name => 'polaroid';

  @override
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final baseSize = math.min(photoWidth, photoHeight);
    final padding = baseSize * 0.06;

    final textLineCount = _countTextLines(
      hasBarcode: data.hasBarcode,
      hasOperator: data.hasOperator,
    );
    final bottomStripHeight = math.max(
      photoHeight * 0.22,
      textLineCount * (baseSize * 0.032 * 1.6) + padding * 2.5,
    );

    final canvasWidth = photoWidth + (padding * 2);
    final canvasHeight = photoHeight + padding + bottomStripHeight;
    return WatermarkCanvasSize(canvasWidth, canvasHeight);
  }

  @override
  void paint({
    required Canvas canvas,
    required WatermarkCanvasSize canvasSize,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    final canvasWidth = canvasSize.width;
    final canvasHeight = canvasSize.height;
    final baseSize = math.min(photoWidth, photoHeight);
    final padding = baseSize * 0.06;
    final bottomStripHeight = canvasHeight - photoHeight - padding;

    // Logo sizing (dihitung di sini karena tergantung bottomStripHeight
    // yang baru diketahui setelah computeCanvasSize dipanggil).
    double? logoDrawW, logoDrawH;
    if (logoImage != null) {
      final logoMaxH = bottomStripHeight * 0.45;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = logoMaxH / logoH;
      logoDrawW = logoW * scale;
      logoDrawH = logoH * scale;
    }

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
    final isManual = data.isManual;
    final dateStr =
        DateFormat('MMM dd, yyyy • HH:mm:ss').format(data.timestamp).toUpperCase();
    final gpsStr = data.displayLocation;

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

    if (data.hasBarcode) {
      drawText(data.barcodeValue!, const Color(0xFF2C2C2C), baseSize * 0.045,
          fontWeight: FontWeight.w800);
    }

    if (data.hasOperator) {
      drawText('OP: ${data.operatorName}', const Color(0xFF8B6914),
          baseSize * 0.032,
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
        text: TextSpan(
          text: 'MANUAL',
          style: TextStyle(
            color: Colors.white,
            fontSize: badgeFontSize,
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
    }
  }

  int _countTextLines({
    required bool hasBarcode,
    required bool hasOperator,
  }) {
    int lines = 0;
    if (hasBarcode) lines++;
    if (hasOperator) lines++;
    lines++; // tanggal selalu tampil
    lines++; // baris lokasi selalu tampil (fallback "No location data")
    return lines + 1; // +1 padding ekstra, sama seperti versi asli
  }
}
