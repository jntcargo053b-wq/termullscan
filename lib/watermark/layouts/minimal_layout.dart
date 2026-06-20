import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'base_layout.dart';
import '../models/watermark_data.dart';
import '../models/watermark_style.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../widgets/logo_widget.dart';

class MinimalLayout implements WatermarkLayout {
  @override
  String get displayName => '⚡ Minimal';

  @override
  WatermarkStyle get style => WatermarkStyle.minimal;

  @override
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    // Kanvas sama dengan ukuran foto
    return WatermarkCanvasSize(photoWidth, photoHeight);
  }

  @override
  void paintOnCanvas({
    required Canvas canvas,
    required WatermarkCanvasSize canvasSize,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final padding = LayoutHelper.padding(baseSize);

    // Gambar foto full
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    // Hitung jumlah baris
    int lineCount = 1; // tanggal
    if (data.hasBarcode) lineCount++;
    if (data.hasOperator) lineCount++;
    lineCount++; // lokasi

    final lineHeight = LayoutHelper.lineHeight(baseSize, ratio: 0.035);
    final overlayHeight = math.max(
      photoHeight * 0.14,
      lineCount * lineHeight + padding * 2,
    );
    final overlayTop = photoHeight - overlayHeight;

    // Gradient overlay
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

    // Teks
    final logoReserve = logoImage != null ? baseSize * 0.16 : 0.0;
    final textX = padding;
    final textContentWidth = photoWidth - padding * 2 - logoReserve;
    double textY = photoHeight - padding - lineCount * lineHeight;

    void drawText(String text, Color color, double fontSize,
        {FontWeight fontWeight = FontWeight.w500, int maxLines = 1}) {
      final tp = TextHelper.paintText(
        canvas,
        text: text,
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        maxLines: maxLines,
      );
      textY += tp + fontSize * 0.25;
    }

    if (data.hasBarcode) {
      drawText(data.barcodeValue!, Colors.white, baseSize * 0.030,
          fontWeight: FontWeight.w700);
    }
    if (data.hasOperator) {
      drawText(data.operatorName, Colors.white70, baseSize * 0.024);
    }
    drawText(data.formattedTimestamp, Colors.white70, baseSize * 0.022);
    drawText(data.displayLocation, Colors.white60, baseSize * 0.022, maxLines: 1);

    // Badge MANUAL (mini)
    if (data.isManual) {
      drawText('• MANUAL ENTRY', const Color(0xFFFFB74D), baseSize * 0.020,
          fontWeight: FontWeight.w700);
    }

    // Logo (pojok kanan bawah)
    if (logoImage != null) {
      final logoSize = baseSize * 0.13;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoSize / logoW, logoSize / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      final logoX = photoWidth - padding - drawW;
      final logoY = photoHeight - padding - drawH;

      LogoWidget.paint(
        canvas: canvas,
        logoImage: logoImage,
        x: logoX,
        y: logoY,
        maxWidth: drawW,
        maxHeight: drawH,
        opacity: 1.0,
      );
    }
  }

  @override
  Widget buildPreview({
    required WatermarkData previewData,
    required bool hasLogo,
    required String? logoPath,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (previewData.operatorName.isNotEmpty) ...[
                    Text(
                      previewData.operatorName,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Gap(2),
                  ],
                  Text(
                    previewData.barcodeValue ?? '8991234567890',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Gap(2),
                  Text(
                    previewData.formattedTimestamp,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                    ),
                  ),
                  const Gap(2),
                  Text(
                    previewData.displayLocation,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 9,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
              const Gap(8),
              Image.file(
                File(logoPath),
                width: 28,
                height: 28,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.business, color: Colors.white24),
              ),
            ],
          ],
        ),
        const Gap(6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.grey.shade800,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            displayName,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 8,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }
}
