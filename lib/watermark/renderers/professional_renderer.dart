import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/watermark_data.dart';
import 'base_renderer.dart';

/// Gaya PROFESSIONAL — strip putih bersih di bawah foto, mirip kop
/// dokumen resmi. Setiap baris data ditampilkan sebagai pasangan
/// label:value dengan garis pembatas tegas. Ditujukan untuk laporan
/// formal / proof-of-delivery yang akan dicetak atau dilampirkan ke
/// dokumen resmi.
class ProfessionalRenderer implements WatermarkRenderer {
  @override
  String get name => 'professional';

  @override
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final baseSize = math.min(photoWidth, photoHeight);
    final rowHeight = baseSize * 0.052;

    int rowCount = 1; // tanggal & waktu selalu tampil
    if (data.hasBarcode) rowCount++;
    if (data.hasOperator) rowCount++;
    rowCount++; // lokasi selalu tampil

    final stripHeight = rowCount * rowHeight + baseSize * 0.04;
    return WatermarkCanvasSize(photoWidth, photoHeight + stripHeight);
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
    final stripHeight = canvasHeight - photoHeight;
    final stripTop = photoHeight;

    // Foto penuh di atas, tanpa border.
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    // Garis tegas pemisah foto dan strip data.
    canvas.drawRect(
      Rect.fromLTWH(0, stripTop, canvasWidth, stripHeight),
      Paint()..color = Colors.white,
    );
    canvas.drawLine(
      Offset(0, stripTop),
      Offset(canvasWidth, stripTop),
      Paint()
        ..color = const Color(0xFF1A2A3A)
        ..strokeWidth = math.max(2.0, baseSize * 0.003),
    );

    final padding = baseSize * 0.04;
    final rowHeight = baseSize * 0.052;
    final labelWidth = baseSize * 0.16;

    // Reservasi area logo di kanan strip, jika ada.
    final logoReserve = logoImage != null ? baseSize * 0.20 : 0.0;

    final dateStr =
        DateFormat('dd/MM/yyyy  •  HH:mm:ss').format(data.timestamp);
    final gpsStr = data.displayLocation;

    double rowY = stripTop + padding * 0.6;

    void drawRow(String label, String value, {bool emphasize = false}) {
      final fontSize = baseSize * 0.026;
      final labelTp = TextPainter(
        text: TextSpan(
          text: label.toUpperCase(),
          style: TextStyle(
            color: const Color(0xFF8A95A5),
            fontSize: fontSize * 0.85,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout(maxWidth: labelWidth);
      labelTp.paint(canvas, Offset(padding, rowY));

      final valueTp = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(
            color: const Color(0xFF1A2A3A),
            fontSize: fontSize,
            fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: canvasWidth - padding * 2 - labelWidth - logoReserve);
      valueTp.paint(canvas, Offset(padding + labelWidth, rowY));

      rowY += rowHeight;
    }

    if (data.hasBarcode) {
      drawRow('Kode', data.barcodeValue!, emphasize: true);
    }
    if (data.hasOperator) {
      drawRow('Operator', data.operatorName);
    }
    drawRow('Waktu', dateStr);
    drawRow('Lokasi', gpsStr);

    // Badge "MANUAL" — kotak bersudut tajam, gaya formal/resmi.
    if (data.isManual) {
      final badgeW = baseSize * 0.13;
      final badgeH = baseSize * 0.026;
      final badgeX = canvasWidth - padding - badgeW - logoReserve;
      final badgeY = stripTop + padding * 0.6;

      canvas.drawRect(
        Rect.fromLTWH(badgeX, badgeY, badgeW, badgeH),
        Paint()..color = const Color(0xFF1A2A3A),
      );
      final badgeTp = TextPainter(
        text: TextSpan(
          text: 'INPUT MANUAL',
          style: TextStyle(
            color: Colors.white,
            fontSize: badgeH * 0.48,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
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

    // Logo di pojok kanan strip, sejajar vertikal dengan tengah strip.
    if (logoImage != null) {
      final logoMaxH = stripHeight * 0.55;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = logoMaxH / logoH;
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      final logoX = canvasWidth - padding - drawW;
      final logoY = stripTop + (stripHeight - drawH) / 2;

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
