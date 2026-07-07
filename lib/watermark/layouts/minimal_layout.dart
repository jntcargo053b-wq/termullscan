// lib/watermark/layouts/minimal_layout.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/watermark_data.dart';
import '../watermark_style.dart';
import '../watermark_settings.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../theme/watermark_theme.dart';
import '../widgets/logo_widget.dart';
import 'base_layout.dart';
import 'layout_metrics.dart';

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
    required WatermarkTheme theme,
  }) {
    final isPortrait = photoHeight > photoWidth;
    double effectiveBaseSize = theme.typography.baseSize;
    double effectivePadding = theme.typography.padding;
    if (theme.usePortraitScaling && isPortrait) {
      effectiveBaseSize *= theme.portraitScaleFactor;
      effectivePadding *= theme.portraitScaleFactor;
    }

    int lineCount = 0;
    if (data.hasBarcode) lineCount++;
    if (data.hasOperator) lineCount++;
    lineCount++; // timestamp
    if (data.hasLocation) lineCount++;

    final lineH = effectiveBaseSize * theme.typography.lineHeight;
    final barcodeBonus = data.hasBarcode ? theme.typography.barcodeRowBonus : 0.0;

    final minHeight = photoHeight * theme.minPanelHeightFraction;
    final contentHeight = lineCount * lineH + barcodeBonus + effectivePadding * 1.2;
    final overlayHeight = math.max(minHeight, contentHeight);

    // logo.maxSize sekarang rasio kecil (mis. 0.20), langsung dikalikan baseSize * scaleFactor
    final logoMaxSize = effectiveBaseSize * theme.logo.maxSize * theme.logo.scaleFactor;
    final textW = photoWidth - effectivePadding * 2 - logoMaxSize - 12;

    return LayoutMetrics(
      baseSize: effectiveBaseSize,
      padding: effectivePadding,
      fontSize: theme.typography.fontSize,
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
    required WatermarkTheme theme,
  }) {
    final padding = metrics.padding;
    final overlayHeight = metrics.stripHeight;

    final placement = _resolveWatermarkPosition(data.position, photoHeight, overlayHeight);
    final overlayTop = placement.top;
    final textAlign = placement.textAlign;
    final overlayAtBottom = placement.atBottom;

    canvas.drawImageRect(
      srcImage,
      ui.Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      ui.Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      ui.Paint()
        ..filterQuality = ui.FilterQuality.high
        ..isAntiAlias = true,
    );

    // Panel background (solid + border)
    final panelRect = ui.Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight);
    canvas.drawRect(
      panelRect,
      ui.Paint()..color = theme.panel.backgroundColor.withOpacity(theme.panel.backgroundOpacity),
    );

    // Border
    if (theme.panel.showBorder) {
      final borderPaint = ui.Paint()
        ..color = theme.panel.borderColor.withOpacity(theme.panel.borderOpacity)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = theme.panel.borderWidth;
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(
            theme.panel.borderWidth / 2,
            overlayTop + theme.panel.borderWidth / 2,
            photoWidth - theme.panel.borderWidth,
            overlayHeight - theme.panel.borderWidth,
          ),
          ui.Radius.circular(theme.panel.borderRadius),
        ),
        borderPaint,
      );
    }

    final c = theme.accent.color;
    final textContentWidth = metrics.textAvailableWidth;
    final double textX = textAlign == ui.TextAlign.left
        ? padding
        : photoWidth - padding - textContentWidth;
    double textY = overlayTop + padding * 0.6;

    void drawIconLine(String icon, String text, Color color, {bool emphasize = false}) {
      final valueFontSize =
          emphasize ? theme.typography.barcodeFontSize : theme.typography.bodyFontSize;
      final rowLineHeight =
          emphasize ? theme.typography.barcodeLineHeight : metrics.lineHeight;
      final iconOffset = textAlign == ui.TextAlign.left ? textX : textX + textContentWidth - valueFontSize * 2;
      TextHelper.paintText(
        canvas: canvas,
        text: icon,
        x: iconOffset,
        y: textY,
        maxWidth: 30,
        color: color,
        fontSize: valueFontSize,
        fontWeight: FontWeight.normal,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      final textOffset = textAlign == ui.TextAlign.left ? textX + 30 : textX;
      TextHelper.paintText(
        canvas: canvas,
        text: text,
        x: textOffset,
        y: textY,
        maxWidth: textContentWidth - 30,
        color: color,
        fontSize: valueFontSize,
        fontWeight: emphasize ? FontWeight.w800 : FontWeight.w500,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      textY += rowLineHeight;
    }

    // Timestamp (paling besar)
    drawIconLine('🕒', data.formattedTimestamp, Colors.white.withOpacity(0.85), emphasize: true);

    textY += theme.typography.groupSpacing;

    if (data.hasBarcode) {
      drawIconLine('📦', data.barcodeValue ?? '', Colors.white, emphasize: false);
    }
    if (data.hasOperator) {
      drawIconLine('👤', data.operatorName, Colors.white.withOpacity(0.92));
    }

    if (data.hasLocation) {
      textY += theme.typography.groupSpacing * 0.5;
      drawIconLine('📍', data.displayLocation, Colors.white.withOpacity(0.75));
    }

    if (data.isManual) {
      drawIconLine('⚡', 'MANUAL ENTRY', c);
    }

    // Logo
    if (logoImage != null) {
      final logoSize = metrics.logoMaxSize;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoSize / logoW, logoSize / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      double logoX = textAlign == ui.TextAlign.left
          ? photoWidth - padding - drawW
          : padding;
      double logoY = overlayAtBottom
          ? photoHeight - padding - drawH
          : padding;

      // Center vertically if enabled
      if (theme.logo.centerVertically) {
        logoY = overlayTop + (overlayHeight - drawH) / 2;
      }

      final cardPad = theme.logoCardPadding(drawW);
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(
            logoX - cardPad,
            logoY - cardPad,
            drawW + cardPad * 2,
            drawH + cardPad * 2,
          ),
          ui.Radius.circular(theme.logoCardRadius(cardPad)),
        ),
        ui.Paint()..color = Colors.black.withOpacity(theme.logo.cardOpacity),
      );

      LogoWidget.paint(
        canvas: canvas,
        logoImage: logoImage,
        x: logoX,
        y: logoY,
        maxWidth: drawW,
        maxHeight: drawH,
        opacity: theme.logo.opacity,
      );
    }
  }

  // Helper untuk resolve posisi (menggantikan WatermarkAlignment)
  _Position _resolveWatermarkPosition(WatermarkPosition position, double photoHeight, double overlayHeight) {
    final atBottom = position == WatermarkPosition.bottomRight ||
                     position == WatermarkPosition.bottomLeft ||
                     (position != WatermarkPosition.topLeft &&
                      position != WatermarkPosition.topRight);
    final top = atBottom ? photoHeight - overlayHeight : 0.0;
    final textAlign = (position == WatermarkPosition.bottomLeft || position == WatermarkPosition.topLeft)
        ? ui.TextAlign.left
        : ui.TextAlign.right;
    return _Position(top: top, textAlign: textAlign, atBottom: atBottom);
  }

  @override
  Widget buildPreview({
    required WatermarkData previewData,
    required bool hasLogo,
    required String? logoPath,
    double previewWidth = 300,
    double previewHeight = 400,
  }) {
    final baseSize = LayoutHelper.getBaseSize(previewWidth, previewHeight);
    final theme = WatermarkTheme.of(style: style, data: previewData, baseSize: baseSize);
    final metrics = computeMetrics(
      photoWidth: previewWidth,
      photoHeight: previewHeight,
      data: previewData,
      theme: theme,
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
                heightFactor: overlayFractionHeight.clamp(0.08, 0.8),
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
                        child: _buildPreviewText(previewData, isLeftAligned, theme),
                      ),
                      if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
                        const SizedBox(width: 8),
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

  Widget _buildPreviewText(WatermarkData data, bool alignLeft, WatermarkTheme theme) {
    const textStyle = TextStyle(
      color: Colors.white,
      fontSize: 9,
      fontWeight: FontWeight.w500,
    );
    final align = alignLeft ? TextAlign.left : TextAlign.right;

    final lines = <Widget>[];
    lines.add(Text(
      '🕒 ${data.formattedTimestamp}',
      style: textStyle.copyWith(fontWeight: FontWeight.w800, fontSize: 10),
      textAlign: align,
    ));
    if (data.hasBarcode) {
      lines.add(Text(
        '📦 ${data.barcodeValue}',
        style: textStyle,
        textAlign: align,
      ));
    }
    if (data.hasOperator) {
      lines.add(Text('👤 ${data.operatorName}', style: textStyle, textAlign: align));
    }
    if (data.hasLocation) {
      lines.add(Text('📍 ${data.displayLocation}', style: textStyle, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align));
    }
    if (data.isManual) {
      lines.add(Text('⚡ MANUAL ENTRY', style: TextStyle(color: theme.accent.color, fontSize: 8, fontWeight: FontWeight.w700), textAlign: align));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: lines,
    );
  }
}

class _Position {
  final double top;
  final ui.TextAlign textAlign;
  final bool atBottom;
  _Position({required this.top, required this.textAlign, required this.atBottom});
}
