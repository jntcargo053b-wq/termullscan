import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'base_layout.dart';
import 'layout_metrics.dart';
import '../models/watermark_data.dart';
import '../models/watermark_style.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../widgets/logo_widget.dart';
import '../watermark_settings.dart'; // untuk WatermarkPosition

class StampLayout extends WatermarkLayout {
  @override
  String get displayName => '✔ Verified Stamp';

  @override
  WatermarkStyle get style => WatermarkStyle.stamp;

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

    final logoMaxSize = baseSize * 0.12;
    final panelWidth = baseSize * 0.46;
    final panelHeight = lineCount * lineH + padding;
    final textW = panelWidth - padding * 0.8;

    return LayoutMetrics(
      baseSize: baseSize,
      padding: padding,
      fontSize: fontSz,
      lineHeight: lineH,
      stripHeight: panelHeight,
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
    final baseSize = metrics.baseSize;

    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    final stampColor = data.isManual ? const Color(0xFFE67E22) : const Color(0xFF2E8B57);
    final stampLabel = data.isManual ? 'MANUAL' : 'VERIFIED';

    final stampW = baseSize * 0.30;
    final stampH = baseSize * 0.14;
    double stampCenterX, stampCenterY;

    switch (data.position) {
      case WatermarkPosition.bottomRight:
        stampCenterX = photoWidth - padding - stampW / 2;
        stampCenterY = photoHeight - padding - stampH / 2;
        break;
      case WatermarkPosition.bottomLeft:
        stampCenterX = padding + stampW / 2;
        stampCenterY = photoHeight - padding - stampH / 2;
        break;
      case WatermarkPosition.topRight:
        stampCenterX = photoWidth - padding - stampW / 2;
        stampCenterY = padding + stampH / 2;
        break;
      case WatermarkPosition.topLeft:
        stampCenterX = padding + stampW / 2;
        stampCenterY = padding + stampH / 2;
        break;
    }

    canvas.save();
    canvas.translate(stampCenterX, stampCenterY);
    canvas.rotate(-0.08);

    final stampRect = Rect.fromCenter(center: Offset.zero, width: stampW, height: stampH);
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
        ..strokeWidth = strokeWidth,
    );

    double textY = -stampH * 0.35;
    TextHelper.paintText(
      canvas: canvas,
      text: stampLabel,
      x: -stampW / 2 + 8,
      y: textY,
      maxWidth: stampW - 16,
      color: stampColor,
      fontSize: stampH * 0.28,
      fontWeight: FontWeight.w900,
      textAlign: TextAlign.center,
    );

    textY += stampH * 0.22;
    if (data.hasOperator) {
      TextHelper.paintText(
        canvas: canvas,
        text: data.operatorName,
        x: -stampW / 2 + 8,
        y: textY,
        maxWidth: stampW - 16,
        color: stampColor,
        fontSize: stampH * 0.16,
        fontWeight: FontWeight.w600,
        textAlign: TextAlign.center,
      );
      textY += stampH * 0.20;
    }

    final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(data.timestamp);
    TextHelper.paintText(
      canvas: canvas,
      text: dateStr,
      x: -stampW / 2 + 8,
      y: textY,
      maxWidth: stampW - 16,
      color: stampColor,
      fontSize: stampH * 0.14,
      fontWeight: FontWeight.w600,
      textAlign: TextAlign.center,
    );

    canvas.restore();

    final infoLines = <String>[];
    if (data.hasBarcode) infoLines.add(data.barcodeValue!);
    if (data.hasOperator) infoLines.add('OP: ${data.operatorName}');
    infoLines.add(data.displayLocation);

    final fontSize = data.fontSize;
    final lineHeight = fontSize * 1.4;
    final panelPadding = 8.0;
    final panelHeight = infoLines.length * lineHeight + panelPadding * 2;
    final panelWidth = metrics.textAvailableWidth + panelPadding * 2;

    double panelX = 0, panelY = 0;
    switch (data.position) {
      case WatermarkPosition.bottomRight:
        panelX = photoWidth - padding - panelWidth;
        panelY = photoHeight - padding - panelHeight - stampH - padding;
        break;
      case WatermarkPosition.bottomLeft:
        panelX = padding;
        panelY = photoHeight - padding - panelHeight - stampH - padding;
        break;
      case WatermarkPosition.topRight:
        panelX = photoWidth - padding - panelWidth;
        panelY = padding + stampH + padding;
        break;
      case WatermarkPosition.topLeft:
        panelX = padding;
        panelY = padding + stampH + padding;
        break;
    }

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(panelX, panelY, panelWidth, panelHeight),
        Radius.circular(8),
      ),
      Paint()
        ..color = Colors.black.withOpacity(data.backgroundOpacity * 1.2)
        ..style = PaintingStyle.fill,
    );

    double textY2 = panelY + panelPadding;
    final textX2 = panelX + panelPadding;
    for (final line in infoLines) {
      TextHelper.paintText(
        canvas: canvas,
        text: line,
        x: textX2,
        y: textY2,
        maxWidth: panelWidth - panelPadding * 2,
        color: Colors.white,
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        maxLines: 1,
      );
      textY2 += lineHeight;
    }

    if (logoImage != null) {
      final logoSize = metrics.logoMaxSize;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoSize / logoW, logoSize / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      double logoX = 0, logoY = 0;
      switch (data.position) {
        case WatermarkPosition.bottomRight:
          logoX = padding;
          logoY = padding;
          break;
        case WatermarkPosition.bottomLeft:
          logoX = photoWidth - padding - drawW;
          logoY = padding;
          break;
        case WatermarkPosition.topRight:
          logoX = padding;
          logoY = photoHeight - padding - drawH;
          break;
        case WatermarkPosition.topLeft:
          logoX = photoWidth - padding - drawW;
          logoY = photoHeight - padding - drawH;
          break;
      }
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

    final stampColor = previewData.isManual ? const Color(0xFFE67E22) : const Color(0xFF2E8B57);
    final stampLabel = previewData.isManual ? 'MANUAL' : 'VERIFIED';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: stampColor, width: 1.5),
                borderRadius: BorderRadius.circular(4),
                color: stampColor.withOpacity(0.1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    stampLabel,
                    style: TextStyle(
                      color: stampColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                  const Gap(2),
                  if (previewData.hasOperator)
                    Text(
                      previewData.operatorName,
                      style: TextStyle(
                        color: stampColor,
                        fontSize: 8,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(
                    previewData.formattedTimestamp,
                    style: TextStyle(
                      color: stampColor,
                      fontSize: 8,
                      fontWeight: FontWeight.w600,
                    ),
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
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
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
        ),
      ],
    );
  }
}
