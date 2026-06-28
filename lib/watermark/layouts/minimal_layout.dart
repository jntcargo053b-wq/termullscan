// ============================================================
// lib/watermark/layouts/minimal_layout.dart (FINAL)
// ============================================================
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

  static const Color _accentColor = Color(0xFFFFB74D);

  @override
  LayoutMetrics computeMetrics({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final padding = LayoutHelper.padding(baseSize);

    int lineCount = 1;
    if (data.hasBarcode) lineCount++;
    if (data.hasOperator) lineCount++;
    lineCount++; // location

    final fontSz = data.fontSize;
    final lineH = fontSz * 1.7; // ✅ konsisten 1.7

    final overlayHeight = math.max(
      photoHeight * 0.10,
      lineCount * lineH + padding * 1.6,
    );

    final logoMaxSize = baseSize * 0.18;
    final rightReserved = logoMaxSize + padding * 1.4;
    final accentBarSpace = baseSize * 0.006 + padding * 0.5;
    final textW = photoWidth - padding * 2 - rightReserved - accentBarSpace;

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
    final baseSize = metrics.baseSize;
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

    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, overlayTop),
        Offset(0, overlayTop + overlayHeight),
        overlayAtBottom
            ? [
                Colors.black.withOpacity(0.0),
                Colors.black.withOpacity(data.backgroundOpacity * 0.60),
              ]
            : [
                Colors.black.withOpacity(data.backgroundOpacity * 0.60),
                Colors.black.withOpacity(0.0),
              ],
        overlayAtBottom ? [0.0, 1.0] : [0.0, 1.0],
      );
    canvas.drawRect(
      Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight),
      gradientPaint,
    );

    final textContentWidth = metrics.textAvailableWidth;
    final accentBarW = math.max(2.0, baseSize * 0.003);
    final accentBarSpace = accentBarW + padding * 0.5;

    final double textX = textAlign == TextAlign.left
        ? padding + accentBarSpace
        : photoWidth - padding - textContentWidth;
    double textY = overlayTop + padding * 0.8;

    final barX = textAlign == TextAlign.left
        ? padding
        : photoWidth - padding - accentBarW;
    final textBlockHeight = metrics.textRowCount * metrics.lineHeight;
    canvas.drawRect(
      Rect.fromLTWH(
        barX,
        overlayTop + padding * 0.75,
        accentBarW,
        textBlockHeight,
      ),
      Paint()..color = _accentColor.withOpacity(0.7),
    );

    void drawText(String text, Color color, double fontSize,
        {FontWeight fontWeight = FontWeight.w500, int maxLines = 1}) {
      TextHelper.paintText(
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
        fontFamily: data.fontFamily,
      );
      textY += metrics.lineHeight;
    }

    if (data.hasBarcode) {
      drawText(data.barcodeValue!, Colors.white, data.fontSize + 1,
          fontWeight: FontWeight.w700);
    }
    if (data.hasOperator) {
      drawText(data.operatorName, Colors.white.withOpacity(0.90), data.fontSize);
    }
    drawText(data.formattedTimestamp, Colors.white.withOpacity(0.80), data.fontSize - 1);
    drawText(data.displayLocation, Colors.white.withOpacity(0.70), data.fontSize - 1);

    if (data.isManual) {
      drawText('• MANUAL ENTRY', const Color(0xFFFFB74D), data.fontSize - 2,
          fontWeight: FontWeight.w700);
    }

    // ─── LOGO ────────────────────────────────────────────────────
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

      // ✅ cardPad diperbesar dari 0.15 → 0.25
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

  // ─── PREVIEW ──────────────────────────────────────────────────
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
                    mainAxisAlignment: isLeftAligned
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.end,
                    children: [
                      if (isLeftAligned) ...[
                        _buildAccentBar(),
                        const Gap(8),
                        Expanded(child: _buildTextColumn(previewData, isLeftAligned)),
                      ] else ...[
                        Expanded(child: _buildTextColumn(previewData, isLeftAligned)),
                        const Gap(8),
                        _buildAccentBar(),
                      ],
                      if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
                        const Gap(8),
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

  Widget _buildAccentBar() {
    return Container(
      width: 2.0,
      height: 28,
      decoration: BoxDecoration(
        color: _accentColor,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildTextColumn(WatermarkData previewData, bool isLeftAligned) {
    return Column(
      crossAxisAlignment:
          isLeftAligned ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (previewData.hasBarcode)
          Text(
            previewData.barcodeValue ?? '8991234567890',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
            textAlign: isLeftAligned ? TextAlign.left : TextAlign.right,
          ),
        if (previewData.hasOperator)
          Text(
            previewData.operatorName,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 9,
              fontWeight: FontWeight.w500,
            ),
            textAlign: isLeftAligned ? TextAlign.left : TextAlign.right,
          ),
        Text(
          previewData.formattedTimestamp,
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 8,
          ),
          textAlign: isLeftAligned ? TextAlign.left : TextAlign.right,
        ),
        Text(
          previewData.displayLocation,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 7.5,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: isLeftAligned ? TextAlign.left : TextAlign.right,
        ),
        if (previewData.isManual)
          Text(
            '• MANUAL ENTRY',
            style: const TextStyle(
              color: Color(0xFFFFB74D),
              fontSize: 7,
              fontWeight: FontWeight.w700,
            ),
            textAlign: isLeftAligned ? TextAlign.left : TextAlign.right,
          ),
      ],
    );
  }
}
