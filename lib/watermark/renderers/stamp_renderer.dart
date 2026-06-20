import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/watermark_data.dart';
import 'base_renderer.dart';

/// Gaya STAMP — foto penuh tanpa strip terpisah, dengan elemen "cap"
/// bersudut sedikit dirotasi di pojok kanan-bawah foto (mirip stempel
/// verifikasi dokumen), dan baris info ringkas di bawah cap tersebut.
class StampRenderer implements WatermarkRenderer {
  @override
  String get name => 'stamp';

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
    final padding = baseSize * 0.04;

    // Foto penuh.
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    final stampColor = data.isManual
        ? const Color(0xFFE67E22)
        : const Color(0xFF2E8B57);
    final stampLabel = data.isManual ? 'MANUAL' : 'VERIFIED';

    final stampW = baseSize * 0.30;
    final stampH = baseSize * 0.11;
    final stampCenterX = photoWidth - padding - stampW / 2;
    final stampCenterY = photoHeight - padding - stampH / 2;

    canvas.save();
    canvas.translate(stampCenterX, stampCenterY);
    canvas.rotate(-0.08); // sedikit dirotasi, kesan "dicap manual"

    final stampRect = Rect.fromCenter(
      center: Offset.zero,
      width: stampW,
      height: stampH,
    );
    final strokeWidth = math.max(2.0, baseSize * 0.0045);

    canvas.drawRRect(
      RRect.fromRectAndRadius(stampRect, Radius.circular(stampH * 0.12)),
      Paint()
        ..color = stampColor.withOpacity(0.10)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(stampRect, Radius.circular(stampH * 0.12)),
      Paint()
        ..color = stampColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..isAntiAlias = true,
    );

    final labelTp = TextPainter(
      text: TextSpan(
        text: stampLabel,
        style: TextStyle(
          color: stampColor,
          fontSize: stampH * 0.34,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    labelTp.paint(
      canvas,
      Offset(-labelTp.width / 2, -stampH * 0.30),
    );

    final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(data.timestamp);
    final dateTp = TextPainter(
      text: TextSpan(
        text: dateStr,
        style: TextStyle(
          color: stampColor,
          fontSize: stampH * 0.18,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    dateTp.paint(
      canvas,
      Offset(-dateTp.width / 2, stampH * 0.06),
    );
    canvas.restore();

    // ── INFO PANEL ───────────────────────────────────────────────────
    // Baris info ringkas (barcode, operator, lokasi) di pojok kiri-bawah,
    // dengan latar gelap semi-transparan agar tetap terbaca di atas foto.
    final lines = <String>[];
    if (data.hasBarcode) lines.add(data.barcodeValue!);
    if (data.hasOperator) lines.add(data.operatorName);
    lines.add(data.displayLocation);

    final fontSize = baseSize * 0.024;
    final lineHeight = fontSize * 1.5;
    final panelHeight = lines.length * lineHeight + padding;
    final panelWidth = baseSize * 0.46;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          padding * 0.6,
          photoHeight - padding * 0.6 - panelHeight,
          panelWidth,
          panelHeight,
        ),
        Radius.circular(baseSize * 0.012),
      ),
      Paint()..color = Colors.black.withOpacity(0.45),
    );

    double textY = photoHeight - padding * 0.6 - panelHeight + padding * 0.4;
    final textX = padding * 0.6 + padding * 0.4;
    for (final line in lines) {
      final tp = TextPainter(
        text: TextSpan(
          text: line,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: panelWidth - padding * 0.8);
      tp.paint(canvas, Offset(textX, textY));
      textY += lineHeight;
    }

    // Logo kecil di pojok kiri-atas foto, jika ada.
    if (logoImage != null) {
      final logoSize = baseSize * 0.12;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoSize / logoW, logoSize / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;

      canvas.drawImageRect(
        logoImage,
        Rect.fromLTWH(0, 0, logoW, logoH),
        Rect.fromLTWH(padding, padding, drawW, drawH),
        Paint()
          ..filterQuality = FilterQuality.high
          ..isAntiAlias = true,
      );
    }
  }
}
