import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/watermark_data.dart';
import 'base_renderer.dart';

/// Gaya MINIMAL — tidak ada bingkai/strip terpisah. Foto tetap penuh,
/// watermark berupa overlay gradient tipis di pojok kiri-bawah dengan
/// teks kecil dan rapi. Cocok untuk yang tidak ingin watermark
/// "mendominasi" foto.
class MinimalRenderer implements WatermarkRenderer {
  @override
  String get name => 'minimal';

  @override
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    // Tidak ada strip tambahan — kanvas = ukuran foto asli persis.
    return WatermarkCanvasSize(photoWidth, photoHeight);
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
    final baseSize = math.min(photoWidth, photoHeight);
    final padding = baseSize * 0.035;

    // Gambar foto penuh, tanpa border/bingkai.
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    // Hitung tinggi area overlay berdasarkan jumlah baris teks.
    final lineHeight = baseSize * 0.026 * 1.5;
    int lineCount = 1; // tanggal selalu tampil
    if (data.hasBarcode) lineCount++;
    if (data.hasOperator) lineCount++;
    lineCount++; // lokasi selalu tampil (fallback "No location data")

    final overlayHeight =
        math.max(photoHeight * 0.14, lineCount * lineHeight + padding * 2);
    final overlayTop = photoHeight - overlayHeight;

    // Gradient gelap dari transparan ke hitam, hanya di bagian bawah foto.
    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, overlayTop),
        Offset(0, photoHeight),
        [Colors.black.withOpacity(0.0), Colors.black.withOpacity(0.55)],
      );
    canvas.drawRect(
      Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight),
      gradientPaint,
    );

    // ── TEXT ──────────────────────────────────────────────────────────
    final dateStr =
        DateFormat('dd MMM yyyy, HH:mm').format(data.timestamp);
    final gpsStr = data.displayLocation;

    final logoReserve = logoImage != null ? baseSize * 0.16 : 0.0;
    final textX = padding;
    final textContentWidth = photoWidth - (padding * 2) - logoReserve;
    double textY = photoHeight - padding - lineCount * lineHeight;

    void drawText(String text, Color color, double fontSize,
        {FontWeight fontWeight = FontWeight.w500, int maxLines = 1}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: fontWeight,
            height: 1.2,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: maxLines,
        ellipsis: '…',
      )..layout(maxWidth: textContentWidth);
      tp.paint(canvas, Offset(textX, textY));
      textY += tp.height + fontSize * 0.25;
    }

    if (data.hasBarcode) {
      drawText(data.barcodeValue!, Colors.white, baseSize * 0.030,
          fontWeight: FontWeight.w700);
    }
    if (data.hasOperator) {
      drawText(data.operatorName, Colors.white70, baseSize * 0.024);
    }
    drawText(dateStr, Colors.white70, baseSize * 0.022);
    drawText(gpsStr, Colors.white60, baseSize * 0.022, maxLines: 1);

    // Badge "MANUAL" — versi minimal: teks kecil bertitik, bukan kotak besar.
    if (data.isManual) {
      final tp = TextPainter(
        text: TextSpan(
          text: '• MANUAL ENTRY',
          style: TextStyle(
            color: const Color(0xFFFFB74D),
            fontSize: baseSize * 0.020,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(textX, padding * 0.4 + overlayTop));
    }

    // Logo kecil di pojok kanan-bawah, ukuran proporsional ke baseSize.
    if (logoImage != null) {
      final logoSize = baseSize * 0.13;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoSize / logoW, logoSize / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      final logoX = photoWidth - padding - drawW;
      final logoY = photoHeight - padding - drawH;

      canvas.drawImageRect(
        logoImage,
        Rect.fromLTWH(0, 0, logoW, logoH),
        Rect.fromLTWH(logoX, logoY, drawW, drawH),
        Paint()
          ..filterQuality = FilterQuality.high
          ..isAntiAlias = true,
      );
    }
  }
}
