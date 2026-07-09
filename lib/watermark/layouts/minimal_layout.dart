// ============================================================
// lib/watermark/layouts/minimal_layout.dart (FINAL – PRODUKSI)
// ============================================================
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/watermark_data.dart';
import '../watermark_style.dart';
import '../watermark_settings.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../helpers/watermark_typography.dart';
import '../widgets/logo_widget.dart';
import 'base_layout.dart';
import 'layout_metrics.dart';

class MinimalLayout extends WatermarkLayout {
  @override
  String get displayName => '⚡ Minimal';

  @override
  WatermarkStyle get style => WatermarkStyle.minimal;

  // ─── KONSTANTA ──────────────────────────────────────────────────
  static const Color _accentColor = Color(0xFFFFB74D);

  static const double _lineSpacing = 6.0;
  static const double _overlayPaddingScale = 1.2;
  static const double _topPaddingFactor = 0.6;
  static const double _logoSpacing = 12.0;
  static const double _logoCardScale = 0.25;
  static const double _logoCardRadiusScale = 0.8;
  static const double _iconSpace = 30.0;

  static const double _opacityOperator = 0.92;
  static const double _opacityTimestamp = 0.85;
  static const double _opacityLocation = 0.85;
  static const double _logoCardOpacity = 0.35;

  static const double _previewLogoScale = 0.55;
  static const double _previewCardPadding = 4.0;
  static const double _previewGap = 8.0;
  static const double _previewIconGap = 4.0;

  // ─── COMPUTE METRICS ───────────────────────────────────────────
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
    if (data.isManual) lineCount++;

    final fontSz = data.fontSize;
    final lineH = WatermarkTypography.lineHeight(fontSz);

    final barcodeLineH =
        WatermarkTypography.lineHeight(WatermarkTypography.barcode(fontSz));
    final barcodeBonus = data.hasBarcode ? (barcodeLineH - lineH) : 0.0;

    final overlayHeight = (lineCount * lineH + (lineCount - 1) * _lineSpacing) +
        barcodeBonus +
        padding * _overlayPaddingScale;

    final logoMaxSize = WatermarkTypography.logo(baseSize);

    final hasLogo = data.logoPath != null && data.logoPath!.isNotEmpty;
    final logoReserve = hasLogo ? logoMaxSize + _logoSpacing : 0.0;
    final textW = photoWidth - padding * 2 - logoReserve;

    return LayoutMetrics(
      baseSize: baseSize,
      padding: padding,
      fontSize: fontSz,
      lineHeight: lineH + _lineSpacing,
      stripHeight: overlayHeight,
      logoMaxSize: logoMaxSize,
      textRowCount: lineCount,
      canvasWidth: photoWidth,
      canvasHeight: photoHeight,
      textAvailableWidth: textW,
    );
  }

  // ─── PAINT ON CANVAS ──────────────────────────────────────────
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
    canvas.drawImageRect(
      srcImage,
      ui.Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      ui.Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      ui.Paint()
        ..filterQuality = ui.FilterQuality.high
        ..isAntiAlias = true,
    );

    _paint(
      canvas: canvas,
      metrics: metrics,
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      logoImage: logoImage,
      data: data,
    );
  }

  @override
  void paintWatermarkOnly({
    required ui.Canvas canvas,
    required LayoutMetrics metrics,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    _paint(
      canvas: canvas,
      metrics: metrics,
      photoWidth: metrics.canvasWidth,
      photoHeight: metrics.canvasHeight,
      logoImage: logoImage,
      data: data,
    );
  }

  // ─── INTERNAL PAINT ───────────────────────────────────────────
  void _paint({
    required ui.Canvas canvas,
    required LayoutMetrics metrics,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    final padding = metrics.padding;
    final overlayHeight = metrics.stripHeight;

    final (overlayTop, textAlign, overlayAtBottom) = _getPosition(
      photoHeight: photoHeight,
      overlayHeight: overlayHeight,
      position: data.position,
    );

    // Background gradien
    final bgOpacity = data.backgroundOpacity.clamp(0.0, 1.0);
    final gradientPaint = ui.Paint()
      ..shader = ui.Gradient.linear(
        ui.Offset(0, overlayTop),
        ui.Offset(0, overlayTop + overlayHeight),
        overlayAtBottom
            ? [ui.Color(0x00000000), ui.Color.fromRGBO(0, 0, 0, bgOpacity)]
            : [ui.Color.fromRGBO(0, 0, 0, bgOpacity), ui.Color(0x00000000)],
        [0.0, 1.0],
      );
    canvas.drawRect(
      ui.Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight),
      gradientPaint,
    );

    // Icon lines
    final hasLogo = logoImage != null;
    final logoReserve = hasLogo ? metrics.logoMaxSize + _logoSpacing : 0.0;
    final textContentWidth = photoWidth - padding * 2 - logoReserve;

    _drawIconLines(
      canvas: canvas,
      data: data,
      metrics: metrics,
      padding: padding,
      overlayTop: overlayTop,
      textAlign: textAlign,
      textContentWidth: textContentWidth,
      photoWidth: photoWidth,
    );

    // Logo
    _drawLogo(
      canvas: canvas,
      logoImage: logoImage,
      metrics: metrics,
      padding: padding,
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      overlayAtBottom: overlayAtBottom,
      textAlign: textAlign,
    );
  }

  // ─── POSITION HELPER ─────────────────────────────────────────
  (double, TextAlign, bool) _getPosition({
    required double photoHeight,
    required double overlayHeight,
    required WatermarkPosition position,
  }) {
    double overlayTop;
    TextAlign textAlign;
    bool overlayAtBottom;

    switch (position) {
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

    return (overlayTop, textAlign, overlayAtBottom);
  }

  // ─── DRAW ICON LINES ─────────────────────────────────────────
  void _drawIconLines({
    required ui.Canvas canvas,
    required WatermarkData data,
    required LayoutMetrics metrics,
    required double padding,
    required double overlayTop,
    required TextAlign textAlign,
    required double textContentWidth,
    required double photoWidth,
  }) {
    final double textStart = textAlign == TextAlign.left
        ? padding
        : photoWidth - padding;
    double textY = overlayTop + padding * _topPaddingFactor;

    void drawIconLine(String icon, String text, ui.Color color, {bool emphasize = false}) {
      final valueFontSize = emphasize
          ? WatermarkTypography.barcode(metrics.fontSize)
          : WatermarkTypography.body(metrics.fontSize);
      final rowLineHeight = emphasize
          ? WatermarkTypography.lineHeight(valueFontSize)
          : metrics.lineHeight;

      final iconX = textAlign == TextAlign.left
          ? textStart
          : textStart - _iconSpace;
      TextHelper.paintText(
        canvas: canvas,
        text: icon,
        x: iconX,
        y: textY,
        maxWidth: _iconSpace,
        color: color,
        fontSize: valueFontSize,
        fontWeight: FontWeight.normal,
        maxLines: 1,
        textAlign: textAlign == TextAlign.left ? TextAlign.left : TextAlign.right,
        fontFamily: data.fontFamily,
      );

      final textX = textAlign == TextAlign.left
          ? textStart + _iconSpace
          : textStart - textContentWidth + _iconSpace;
      TextHelper.paintText(
        canvas: canvas,
        text: text,
        x: textX,
        y: textY,
        maxWidth: textContentWidth - _iconSpace,
        color: color,
        fontSize: valueFontSize,
        fontWeight: emphasize ? ui.FontWeight.w800 : ui.FontWeight.w500,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      textY += rowLineHeight;
    }

    if (data.hasBarcode) {
      drawIconLine('📦', data.barcodeValue ?? '', ui.Color(0xFFFFFFFF), emphasize: true);
    }
    if (data.hasOperator) {
      drawIconLine('👤', data.operatorName, ui.Color.fromRGBO(255, 255, 255, _opacityOperator));
    }
    drawIconLine('🕒', data.formattedTimestamp, ui.Color.fromRGBO(255, 255, 255, _opacityTimestamp));
    if (data.hasLocation) {
      drawIconLine('📍', data.displayLocation, ui.Color.fromRGBO(255, 255, 255, _opacityLocation));
    }
    if (data.isManual) {
      drawIconLine('⚡', 'MANUAL ENTRY', _accentColor.toColor());
    }
  }

  // ─── DRAW LOGO ────────────────────────────────────────────────
  void _drawLogo({
    required ui.Canvas canvas,
    required ui.Image? logoImage,
    required LayoutMetrics metrics,
    required double padding,
    required double photoWidth,
    required double photoHeight,
    required bool overlayAtBottom,
    required TextAlign textAlign,
  }) {
    if (logoImage == null) return;

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

    final cardPad = drawW * _logoCardScale;
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        ui.Rect.fromLTWH(
          logoX - cardPad,
          logoY - cardPad,
          drawW + cardPad * 2,
          drawH + cardPad * 2,
        ),
        ui.Radius.circular(cardPad * _logoCardRadiusScale),
      ),
      ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, _logoCardOpacity),
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
                    mainAxisAlignment: isLeftAligned ? MainAxisAlignment.start : MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: _buildPreviewText(
                          previewData,
                          isLeftAligned,
                          metrics,
                        ),
                      ),
                      if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
                        const SizedBox(width: _previewGap),
                        Container(
                          padding: const EdgeInsets.all(_previewCardPadding),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _buildPreviewLogo(logoPath, metrics),
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

  Widget _buildPreviewLogo(String logoPath, LayoutMetrics metrics) {
    final logoSize = metrics.logoMaxSize * _previewLogoScale;
    return ClipRect(
      child: Image.file(
        File(logoPath),
        width: logoSize,
        height: logoSize,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.business, color: Colors.white38, size: 14),
      ),
    );
  }

  Widget _buildPreviewText(
    WatermarkData data,
    bool alignLeft,
    LayoutMetrics metrics,
  ) {
    final textAlign = alignLeft ? TextAlign.left : TextAlign.right;
    final crossAlign = alignLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end;
    final lineHeight = metrics.lineHeight;
    // ✅ Gunakan data.fontSize, bukan WatermarkTypography.defaultFontSize
    final baseFontSize = data.fontSize;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAlign,
      children: [
        if (data.hasBarcode)
          _buildPreviewField('📦 ${data.barcodeValue}', textAlign, lineHeight, baseFontSize, bold: true),
        if (data.hasOperator)
          _buildPreviewField('👤 ${data.operatorName}', textAlign, lineHeight, baseFontSize),
        _buildPreviewField('🕒 ${data.formattedTimestamp}', textAlign, lineHeight, baseFontSize),
        if (data.hasLocation)
          _buildPreviewField('📍 ${data.displayLocation}', textAlign, lineHeight, baseFontSize),
        if (data.isManual)
          _buildPreviewField(
            '⚡ MANUAL ENTRY',
            textAlign,
            lineHeight,
            baseFontSize,
            color: _accentColor,
            bold: true,
            fontSizeFactor: 0.9,
          ),
      ],
    );
  }

  Widget _buildPreviewField(
    String text,
    TextAlign align,
    double lineHeight,
    double baseFontSize, {
    Color? color,
    bool bold = false,
    double fontSizeFactor = 1.0,
  }) {
    final fontSize = baseFontSize * fontSizeFactor;
    return SizedBox(
      height: lineHeight,
      child: Align(
        alignment: align == TextAlign.right ? Alignment.centerRight : Alignment.centerLeft,
        child: Text(
          text,
          style: TextStyle(
            color: color ?? Colors.white,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
          ),
          textAlign: align,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

// ─── EXTENSION ───────────────────────────────────────────────────
extension _ColorToUiColor on Color {
  ui.Color toColor() => ui.Color.fromRGBO(red, green, blue, opacity);
}
