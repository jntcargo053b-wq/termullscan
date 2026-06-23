import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'base_layout.dart';
import 'layout_metrics.dart';
import '../models/watermark_data.dart';
import '../models/watermark_style.dart';
import '../watermark_settings.dart'; // ✅ import
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../widgets/logo_widget.dart';

class ProfessionalLayout extends WatermarkLayout {
  @override
  String get displayName => '🏢 Professional';

  @override
  WatermarkStyle get style => WatermarkStyle.professional;

  @override
  LayoutMetrics computeMetrics({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final padding = LayoutHelper.padding(baseSize);

    int rowCount = 1; // timestamp
    if (data.hasBarcode) rowCount++;
    if (data.hasOperator) rowCount++;
    rowCount++; // location

    final lineH = LayoutHelper.lineHeight(baseSize, ratio: 0.040);
    final fontSz = LayoutHelper.fontSize(baseSize, ratio: 0.026);
    final overlayHeight = math.max(
      photoHeight * 0.16,
      rowCount * lineH + padding * 1.8,
    );

    final logoMaxSize = baseSize * 0.12;
    final rightReserved = logoMaxSize + padding;
    final textW = photoWidth - padding * 2 - rightReserved;

    return LayoutMetrics(
      baseSize: baseSize,
      padding: padding,
      fontSize: fontSz,
      lineHeight: lineH,
      stripHeight: overlayHeight,
      logoMaxSize: logoMaxSize,
      textRowCount: rowCount,
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
        {FontWeight fontWeight = FontWeight.w500}) {
      TextHelper.paintText(
        canvas: canvas,
        text: text,
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        maxLines: 1,
        textAlign: textAlign,
      );
      textY += metrics.lineHeight;
    }

    if (data.hasBarcode) {
      drawText('🏷 ${data.barcodeValue}', Colors.white, data.fontSize + 2,
          fontWeight: FontWeight.w700);
    }
    if (data.hasOperator) {
      drawText('👤 ${data.operatorName}', Colors.white70, data.fontSize);
    }
    drawText('📅 ${data.formattedTimestamp}', Colors.white70, data.fontSize);
    drawText('📍 ${data.displayLocation}', Colors.white60, data.fontSize);

    if (logoImage != null) {
      final logoMaxH = metrics.logoMaxSize;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoMaxH / logoW, logoMaxH / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      double logoX = textAlign == TextAlign.left
          ? photoWidth - padding - drawW
          : padding;
      double logoY = overlayTop == 0
          ? photoHeight - padding - drawH
          : padding;

      LogoWidget.paint(
        canvas: canvas,
        logoImage: logoImage,
        x: logoX,
        y: logoY,
        maxWidth: drawW,
        maxHeight: drawH,
        opacity: 0.8,
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
                  if (previewData.hasOperator)
                    _PreviewRow(label: 'Operator', value: previewData.operatorName),
                  if (previewData.hasBarcode)
                    _PreviewRow(label: 'Barcode', value: previewData.barcodeValue!),
                  _PreviewRow(label: 'Tanggal', value: previewData.formattedTimestamp),
                  _PreviewRow(label: 'Lokasi', value: previewData.displayLocation),
                ],
              ),
            ),
            if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
              const Gap(8),
              Image.file(
                File(logoPath),
                width: metrics.logoMaxSize * 0.6,
                height: metrics.logoMaxSize * 0.6,
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

class _PreviewRow extends StatelessWidget {
  final String label;
  final String value;
  const _PreviewRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              '$label:',
              style: const TextStyle(
                color: Color(0xFF8A95A5),
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.right,
            ),
          ),
          const Gap(6),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Color(0xFF1A2A3A),
                fontSize: 9,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
