// ============================================================
// lib/watermark/layouts/minimal_layout.dart (FINAL – ELEGAN)
// ============================================================
import 'dart:io';                         // ← untuk File
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/watermark_data.dart';
import '../watermark_style.dart';
import '../watermark_settings.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../widgets/logo_widget.dart';
import 'base_layout.dart';
import 'layout_metrics.dart';

class MinimalLayout extends WatermarkLayout {
  @override
  String get displayName => '⚡ Minimal';

  @override
  WatermarkStyle get style => WatermarkStyle.minimal;

  static const Color _accentColor = Color(0xFFFFB74D);

  @override
  LayoutMetrics computeMetrics({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final padding = LayoutHelper.padding(baseSize);

    int lineCount = 0;
    if (data.hasBarcode) lineCount++;
    if (data.hasOperator) lineCount++;
    lineCount++; // timestamp
    if (data.hasLocation) lineCount++;

    final fontSz = data.fontSize;
    final lineH = fontSz * 1.25;
    final spacing = 6.0;

    final overlayHeight = (lineCount * lineH + (lineCount - 1) * spacing) + padding * 1.2;

    final logoMaxSize = baseSize * 0.18;
    final textW = photoWidth - padding * 2 - logoMaxSize - 12;

    return LayoutMetrics(
      baseSize: baseSize,
      padding: padding,
      fontSize: fontSz,
      lineHeight: lineH + spacing,
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
    final bool overlayAtBottom;

    switch (data.position) {
      case WatermarkPosition.bottomRight:
        overlayTop = photoHeight - overlayHeight;
        textAlign = TextAlign.right;
        overlayAtBottom = true;
        break;
      case WatermarkPosition.bottomLeft:
        overlayTop = photoHeight - overlayHeight;
        textAlign = TextAlign.left;
        overlayAtBottom = true;
        break;
      case WatermarkPosition.topRight:
        overlayTop = 0;
        textAlign = TextAlign.right;
        overlayAtBottom = false;
        break;
      case WatermarkPosition.topLeft:
        overlayTop = 0;
        textAlign = TextAlign.left;
        overlayAtBottom = false;
        break;
      default:
        overlayTop = photoHeight - overlayHeight;
        textAlign = TextAlign.right;
        overlayAtBottom = true;
    }

    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    final bgOpacity = data.backgroundOpacity.clamp(0.0, 1.0);
    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, overlayTop),
        Offset(0, overlayTop + overlayHeight),
        overlayAtBottom
            ? [
                Colors.black.withOpacity(0.0),
                Colors.black.withOpacity(bgOpacity),
              ]
            : [
                Colors.black.withOpacity(bgOpacity),
                Colors.black.withOpacity(0.0),
              ],
        [0.0, 1.0],
      );
    canvas.drawRect(
      Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight),
      gradientPaint,
    );

    final textContentWidth = metrics.textAvailableWidth;
    final double textX = textAlign == TextAlign.left
        ? padding
        : photoWidth - padding - textContentWidth;
    final double lineHeight = metrics.lineHeight;
    double textY = overlayTop + padding * 0.6;

    void drawIconLine(String icon, String text, Color color) {
      final iconOffset = textAlign == TextAlign.left ? textX : textX + textContentWidth - metrics.fontSize * 2;
      TextHelper.paintText(
        canvas: canvas,
        text: icon,
        x: iconOffset,
        y: textY,
        maxWidth: 30,
        color: color,
        fontSize: metrics.fontSize,
        fontWeight: FontWeight.normal,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      final textOffset = textAlign == TextAlign.left ? textX + 30 : textX;
      TextHelper.paintText(
        canvas: canvas,
        text: text,
        x: textOffset,
        y: textY,
        maxWidth: textContentWidth - 30,
        color: color,
        fontSize: metrics.fontSize,
        fontWeight: FontWeight.w500,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      textY += lineHeight;
    }

    if (data.hasBarcode) {
      drawIconLine('📦', data.barcodeValue ?? '', Colors.white);
    }
    if (data.hasOperator) {
      drawIconLine('👤', data.operatorName, Colors.white.withOpacity(0.92));
    }
    drawIconLine('🕒', data.formattedTimestamp, Colors.white.withOpacity(0.85));
    if (data.hasLocation) {
      drawIconLine('📍', data.displayLocation, Colors.white.withOpacity(0.85));
    }
    if (data.isManual) {
      drawIconLine('⚡', 'MANUAL ENTRY', _accentColor);
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
      double logoY = overlayAtBottom
          ? photoHeight - padding - drawH
          : padding;

      final cardPad = drawW * 0.25;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            logoX - cardPad,
            logoY - cardPad,
            drawW + cardPad * 2,
            drawH + cardPad * 2,
          ),
          Radius.circular(cardPad * 0.8),
        ),
        Paint()..color = Colors.black.withOpacity(0.35),
      );

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
    final overlayFractionHeight = metrics.stripHeight / previewHeight;
    final isBottom = previewData.position == WatermarkPosition.bottomRight ||
        previewData.position == WatermarkPosition.bottomLeft ||
        (previewData.position != WatermarkPosition.topLeft &&
            previewData.position != WatermarkPosition.topRight);
    final isLeftAligned = previewData.position == WatermarkPosition.bottomLeft ||
        previewData.position == WatermarkPosition.topLeft;

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: previewWidth / previewHeight,
        child: Stack(
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF33373D), Color(0xFF1B1E22)],
                ),
              ),
              child: const Center(
                child: Icon(Icons.image, color: Colors.white12, size: 28),
              ),
            ),
            Align(
              alignment: isBottom ? Alignment.bottomCenter : Alignment.topCenter,
              child: FractionallySizedBox(
                heightFactor: overlayFractionHeight.clamp(0.12, 0.8),
                widthFactor: 1.0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: isBottom ? Alignment.topCenter : Alignment.bottomCenter,
                      end: isBottom ? Alignment.bottomCenter : Alignment.topCenter,
                      colors: [
                        Colors.black.withOpacity(0.0),
                        Colors.black.withOpacity(
                          (previewData.backgroundOpacity).clamp(0.0, 1.0),
                        ),
                      ],
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: isLeftAligned ? MainAxisAlignment.start : MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: _buildPreviewText(previewData, isLeftAligned),
                      ),
                      if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
                        const SizedBox(width: 8),   // pengganti Gap(8)
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Image.file(
                            File(logoPath),
                            width: metrics.logoMaxSize * 0.55,
                            height: metrics.logoMaxSize * 0.55,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.business, color: Colors.white38, size: 14),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade800.withOpacity(0.85),
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewText(WatermarkData data, bool alignLeft) {
    final textStyle = TextStyle(
      color: Colors.white,
      fontSize: 9,
      fontWeight: FontWeight.w500,
    );
    final align = alignLeft ? TextAlign.left : TextAlign.right;

    final lines = <Widget>[];
    if (data.hasBarcode) {
      lines.add(Text('📦 ${data.barcodeValue}', style: textStyle, textAlign: align));
    }
    if (data.hasOperator) {
      lines.add(Text('👤 ${data.operatorName}', style: textStyle, textAlign: align));
    }
    lines.add(Text('🕒 ${data.formattedTimestamp}', style: textStyle, textAlign: align));
    if (data.hasLocation) {
      lines.add(Text('📍 ${data.displayLocation}', style: textStyle, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align));
    }
    if (data.isManual) {
      lines.add(Text('⚡ MANUAL ENTRY', style: TextStyle(color: _accentColor, fontSize: 8, fontWeight: FontWeight.w700), textAlign: align));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: lines,
    );
  }
}
