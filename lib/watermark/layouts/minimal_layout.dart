import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'base_layout.dart';
import 'layout_metrics.dart';
import '../models/watermark_data.dart';
import '../watermark_style.dart';
import '../watermark_settings.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../widgets/logo_widget.dart';

class MinimalLayout extends WatermarkLayout {
  @override
  String get displayName => '⚡ Minimal';

  @override
  WatermarkStyle get style => WatermarkStyle.minimal;

  @override
  LayoutMetrics computeMetrics({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final padding = LayoutHelper.padding(baseSize);

    int lineCount = 1; // timestamp
    if (data.hasBarcode) lineCount++;
    if (data.hasOperator) lineCount++;
    lineCount++; // location

    final lineH = LayoutHelper.lineHeight(baseSize, ratio: 0.035);
    final fontSz = LayoutHelper.fontSize(baseSize, ratio: 0.024);
    final overlayHeight = math.max(
      photoHeight * 0.14,
      lineCount * lineH + padding * 2,
    );

    final logoMaxSize = baseSize * 0.13;
    final rightReserved = logoMaxSize + padding;
    final textW = photoWidth - padding * 2 - rightReserved;

    return LayoutMetrics(
      baseSize: baseSize,
      padding: padding,
      fontSize: fontSz,
      lineHeight: lineH,
      stripHeight: overlayHeight,
      logoMaxSize: logoMaxSize,
      textRowCount: lineCount,
      canvasWidth: photoWidth,
      canvasHeight: photoHeight,
      textAvailableWidth: textW,
    );
  }

  @override
  void paintOnCanvas({
    required ui.Canvas canvas,
    required LayoutMetrics metrics,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    final padding = metrics.padding;
    final overlayHeight = metrics.stripHeight;
    double overlayTop;
    TextAlign textAlign;

    switch (data.position) {
      case WatermarkPosition.bottomRight:
        overlayTop = photoHeight - overlayHeight;
        textAlign = TextAlign.right;
        break;
      case WatermarkPosition.bottomLeft:
        overlayTop = photoHeight - overlayHeight;
        textAlign = TextAlign.left;
        break;
      case WatermarkPosition.topRight:
        overlayTop = 0;
        textAlign = TextAlign.right;
        break;
      case WatermarkPosition.topLeft:
        overlayTop = 0;
        textAlign = TextAlign.left;
        break;
      default:
        overlayTop = photoHeight - overlayHeight;
        textAlign = TextAlign.right;
    }

    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, overlayTop),
        Offset(0, overlayTop + overlayHeight),
        [
          Colors.black.withOpacity(0.0),
          Colors.black.withOpacity(data.backgroundOpacity),
        ],
      );
    canvas.drawRect(
      Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight),
      gradientPaint,
    );

    final textContentWidth = metrics.textAvailableWidth;
    final double textX = textAlign == TextAlign.left
        ? padding
        : photoWidth - padding - textContentWidth;
    double textY = overlayTop + padding;

    void drawText(String text, Color color, double fontSize,
        {FontWeight fontWeight = FontWeight.w500, int maxLines = 1}) {
      final tp = TextHelper.paintText(
        canvas: canvas,
        text: text,
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        maxLines: maxLines,
        textAlign: textAlign,
        fontFamily: data.fontFamily, // ✅ TAMBAHKAN INI
      );
      textY += tp + fontSize * 0.25;
    }

    if (data.hasBarcode) {
      drawText(data.barcodeValue!, Colors.white, data.fontSize + 2,
          fontWeight: FontWeight.w700);
    }
    if (data.hasOperator) {
      drawText(data.operatorName, Colors.white70, data.fontSize);
    }
    drawText(data.formattedTimestamp, Colors.white70, data.fontSize - 1);
    drawText(data.displayLocation, Colors.white60, data.fontSize - 1, maxLines: 1);

    if (data.isManual) {
      drawText('• MANUAL ENTRY', const Color(0xFFFFB74D), data.fontSize - 2,
          fontWeight: FontWeight.w700);
    }

    if (logoImage != null) {
      final logoSize = metrics.logoMaxSize;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoSize / logoW, logoSize / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      double logoX = textAlign == TextAlign.left
          ? photoWidth - padding - drawW
          : padding;
      double logoY = textAlign == TextAlign.left
          ? photoHeight - padding - drawH
          : padding;

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
    double previewWidth = 300,
    double previewHeight = 400,
  }) {
    final metrics = computeMetrics(
      photoWidth: previewWidth,
      photoHeight: previewHeight,
      data: previewData,
    );

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
                width: metrics.logoMaxSize,
                height: metrics.logoMaxSize,
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
