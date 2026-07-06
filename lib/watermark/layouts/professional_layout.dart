// lib/watermark/layouts/professional_layout.dart
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
import '../theme/watermark_theme.dart';
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
    required WatermarkTheme theme,
  }) {
    final isPortrait = photoHeight > photoWidth;
    double effectiveBaseSize = theme.typography.baseSize;
    double effectivePadding = theme.typography.padding;
    if (theme.usePortraitScaling && isPortrait) {
      effectiveBaseSize *= theme.portraitScaleFactor;
      effectivePadding *= theme.portraitScaleFactor;
    }

    int rowCount = 2;
    if (data.hasBarcode) rowCount++;
    if (data.hasOperator) rowCount++;
    if (data.hasLocation) rowCount++;
    if (data.hasCoordinates) rowCount += 2;

    final lineH = effectiveBaseSize * theme.typography.lineHeight;
    final barcodeBonus = data.hasBarcode ? theme.typography.barcodeRowBonus : 0.0;
    final titleBonus = data.hasLocation ? theme.typography.titleRowBonus : 0.0;

    final minHeight = photoHeight * theme.minPanelHeightFraction;
    final contentHeight = rowCount * lineH + barcodeBonus + titleBonus + effectivePadding * 2.0;
    final overlayHeight = math.max(minHeight, contentHeight);

    final logoMaxSize = effectiveBaseSize * (theme.logo.maxSize / 10.0) * theme.logo.scaleFactor;
    final rightReserved = logoMaxSize + effectivePadding * 1.4;
    final accentBarSpace = (theme.accent.showBar ? theme.accent.barWidth : 0.0) + effectivePadding * 0.5;
    final textW = photoWidth - effectivePadding * 2 - rightReserved - accentBarSpace;

    return LayoutMetrics(
      baseSize: effectiveBaseSize,
      padding: effectivePadding,
      fontSize: effectiveBaseSize * 0.12,
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
    required WatermarkTheme theme,
  }) {
    final padding = metrics.padding;
    final overlayHeight = metrics.stripHeight;
    final c = theme.accent.color;

    final placement = WatermarkAlignment.resolve(
      position: data.position,
      photoHeight: photoHeight,
      overlayHeight: overlayHeight,
    );
    final overlayTop = placement.top;
    final textAlign = placement.textAlign;
    final overlayAtBottom = placement.atBottom;

    // Gambar background foto
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    // ─── PANEL BACKGROUND ─────────────────────────────────────
    final panelRect = Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight);

    // Layer 1: solid
    canvas.drawRect(
      panelRect,
      Paint()..color = theme.panel.backgroundColor.withOpacity(theme.panel.backgroundOpacity),
    );

    // Layer 2: gradien
    final gradientColors = overlayAtBottom
        ? [
            theme.panel.backgroundColor.withOpacity(theme.panel.gradientStartOpacity),
            theme.panel.backgroundColor.withOpacity(theme.panel.gradientEndOpacity),
          ]
        : [
            theme.panel.backgroundColor.withOpacity(theme.panel.gradientEndOpacity),
            theme.panel.backgroundColor.withOpacity(theme.panel.gradientStartOpacity),
          ];
    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, overlayTop),
        Offset(0, overlayTop + overlayHeight),
        gradientColors,
      );
    canvas.drawRect(panelRect, gradientPaint);

    // Layer 3: border (jika aktif)
    if (theme.panel.showBorder) {
      final borderPaint = Paint()
        ..color = theme.panel.borderColor.withOpacity(theme.panel.borderOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = theme.panel.borderWidth;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            theme.panel.borderWidth / 2,
            overlayTop + theme.panel.borderWidth / 2,
            photoWidth - theme.panel.borderWidth,
            overlayHeight - theme.panel.borderWidth,
          ),
          Radius.circular(theme.panel.borderRadius),
        ),
        borderPaint,
      );
    }

    // Layer 4: highlight (jika aktif)
    if (theme.panel.showHighlight && theme.panel.highlightOpacity > 0) {
      final highlightPaint = Paint()
        ..color = theme.panel.highlightColor.withOpacity(theme.panel.highlightOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawRect(
        Rect.fromLTWH(
          theme.panel.borderWidth + 2,
          overlayTop + theme.panel.borderWidth + 2,
          photoWidth - (theme.panel.borderWidth + 2) * 2,
          1.0,
        ),
        highlightPaint,
      );
    }

    // ─── ACCENT BAR ────────────────────────────────────────────
    final accentBarW = theme.accent.showBar ? theme.accent.barWidth : 0.0;
    final accentBarSpace = accentBarW + padding * 0.5;
    final logoMaxSize = metrics.logoMaxSize;
    final logoReserve = (logoImage != null) ? logoMaxSize + padding * 1.4 : 0.0;
    final textContentWidth = photoWidth - padding * 2 - logoReserve - accentBarSpace;

    final double textX = textAlign == TextAlign.left
        ? padding + accentBarSpace
        : photoWidth - padding - textContentWidth;
    double textY = overlayTop + padding * 0.95;

    if (theme.accent.showBar && accentBarW > 0) {
      final barX = textAlign == TextAlign.left ? padding : photoWidth - padding - accentBarW;
      final barcodeBonus = data.hasBarcode ? theme.typography.barcodeRowBonus : 0.0;
      final titleBonus = data.hasLocation ? theme.typography.titleRowBonus : 0.0;
      final textBlockHeight =
          metrics.textRowCount * metrics.lineHeight + barcodeBonus + titleBonus;
      canvas.drawRect(
        Rect.fromLTWH(
          barX,
          overlayTop + padding * 0.85,
          accentBarW,
          textBlockHeight,
        ),
        Paint()..color = c.withOpacity(theme.accent.barOpacity),
      );
    }

    // ─── FUNGSI MENGGAMBAR TEKS ──────────────────────────────
    void drawLabelValue(
      String label,
      String value,
      Color valueColor, {
      bool emphasize = false,
      double? customFontSize,
    }) {
      final valueFontSize = customFontSize ??
          (emphasize ? theme.typography.barcodeFontSize : theme.typography.bodyFontSize);
      final rowLineHeight = emphasize
          ? theme.typography.barcodeLineHeight
          : metrics.lineHeight;

      String displayLabel = label;
      if (theme.typography.useSpacedLabels &&
          theme.typography.spacedLabelKeys.contains(label)) {
        displayLabel = _spaceOutLabel(label);
      }

      TextHelper.paintText(
        canvas: canvas,
        text: displayLabel,
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: Colors.white.withOpacity(0.45),
        fontSize: theme.typography.captionFontSize,
        fontWeight: FontWeight.w700,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      TextHelper.paintText(
        canvas: canvas,
        text: value,
        x: textX,
        y: textY + valueFontSize * 0.78,
        maxWidth: textContentWidth,
        color: valueColor,
        fontSize: valueFontSize,
        fontWeight: emphasize ? FontWeight.w600 : FontWeight.w500,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      textY += rowLineHeight;
    }

    void drawTitleRow(String text) {
      TextHelper.paintText(
        canvas: canvas,
        text: text,
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: c,
        fontSize: theme.typography.titleFontSize,
        fontWeight: FontWeight.w800,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      textY += metrics.lineHeight + theme.typography.titleRowBonus;
    }

    void drawCoordLine(String text) {
      if (text.isEmpty) return;
      TextHelper.paintText(
        canvas: canvas,
        text: text,
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: Colors.white.withOpacity(0.65),
        fontSize: theme.typography.captionFontSize,
        fontWeight: FontWeight.w600,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      textY += metrics.lineHeight;
    }

    // ─── URUTAN INFORMASI ──────────────────────────────────────
    if (data.hasLocation) {
      drawTitleRow(data.locationName!);
    }

    drawLabelValue(
      'TANGGAL',
      data.formattedDate,
      Colors.white.withOpacity(0.85),
      customFontSize: theme.typography.barcodeFontSize,
    );
    drawLabelValue(
      'JAM',
      data.formattedTime,
      Colors.white.withOpacity(0.80),
      customFontSize: theme.typography.barcodeFontSize,
    );

    textY += theme.typography.groupSpacing;

    if (data.hasOperator) {
      drawLabelValue(
        'OPERATOR',
        data.operatorName,
        Colors.white.withOpacity(0.92),
      );
    }
    if (data.hasBarcode) {
      drawLabelValue(
        'KODE BARANG',
        data.barcodeValue ?? '',
        Colors.white,
        emphasize: true,
      );
    }

    if (data.hasCoordinates) {
      textY += theme.typography.coordSpacing;
      drawCoordLine(data.latText);
      drawCoordLine(data.lonText);
    }

    // ─── LOGO ──────────────────────────────────────────────────
    if (logoImage != null) {
      final logoMaxH = metrics.logoMaxSize; // sudah termasuk scaleFactor
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoMaxH / logoW, logoMaxH / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;

      double logoX = textAlign == TextAlign.left
          ? photoWidth - padding - drawW
          : padding;
      double logoY;
      if (theme.logo.centerVertically) {
        logoY = overlayTop + (overlayHeight - drawH) / 2;
      } else {
        logoY = overlayAtBottom ? photoHeight - padding - drawH : padding;
      }

      final cardPad = theme.logoCardPadding(drawW);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            logoX - cardPad,
            logoY - cardPad,
            drawW + cardPad * 2,
            drawH + cardPad * 2,
          ),
          Radius.circular(theme.logoCardRadius(cardPad)),
        ),
        Paint()..color = Colors.black.withOpacity(theme.logo.cardOpacity),
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

  String _spaceOutLabel(String label) {
    return label.split('').join('\u200a ');
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
    final baseSize = LayoutHelper.getBaseSize(previewWidth, previewHeight);
    final theme = WatermarkTheme.of(style: style, data: previewData, baseSize: baseSize);
    final metrics = computeMetrics(
      photoWidth: previewWidth,
      photoHeight: previewHeight,
      data: previewData,
      theme: theme,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: previewWidth / previewHeight,
        child: CustomPaint(
          painter: _ProfessionalPreviewPainter(
            previewData: previewData,
            hasLogo: hasLogo,
            logoPath: logoPath,
            metrics: metrics,
            theme: theme,
            isBottom: previewData.position == WatermarkPosition.bottomRight ||
                previewData.position == WatermarkPosition.bottomLeft ||
                (previewData.position != WatermarkPosition.topLeft &&
                    previewData.position != WatermarkPosition.topRight),
            isLeftAligned: WatermarkAlignment.isLeftAligned(previewData.position),
          ),
          child: Container(),
        ),
      ),
    );
  }
}

// ─── PREVIEW PAINTER ────────────────────────────────────────────
class _ProfessionalPreviewPainter extends CustomPainter {
  final WatermarkData previewData;
  final bool hasLogo;
  final String? logoPath;
  final LayoutMetrics metrics;
  final WatermarkTheme theme;
  final bool isBottom;
  final bool isLeftAligned;

  _ProfessionalPreviewPainter({
    required this.previewData,
    required this.hasLogo,
    required this.logoPath,
    required this.metrics,
    required this.theme,
    required this.isBottom,
    required this.isLeftAligned,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    final photoWidth = size.width;
    final photoHeight = size.height;
    final overlayHeight = metrics.stripHeight;
    final overlayTop = isBottom ? photoHeight - overlayHeight : 0.0;
    final padding = metrics.padding;
    final textAlign = isLeftAligned ? TextAlign.left : TextAlign.right;
    final c = theme.accent.color;

    // Background placeholder
    final bgPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, 0),
        Offset(photoWidth, photoHeight),
        [const Color(0xFF33373D), const Color(0xFF1B1E22)],
      );
    canvas.drawRect(Rect.fromLTWH(0, 0, photoWidth, photoHeight), bgPaint);
    final iconPaint = Paint()..color = Colors.white12;
    canvas.drawCircle(Offset(photoWidth / 2, photoHeight / 2), 14, iconPaint);

    // Panel (sama seperti paintOnCanvas)
    final panelRect = Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight);
    canvas.drawRect(
      panelRect,
      Paint()..color = theme.panel.backgroundColor.withOpacity(theme.panel.backgroundOpacity),
    );
    final gradientColors = isBottom
        ? [
            theme.panel.backgroundColor.withOpacity(theme.panel.gradientStartOpacity),
            theme.panel.backgroundColor.withOpacity(theme.panel.gradientEndOpacity),
          ]
        : [
            theme.panel.backgroundColor.withOpacity(theme.panel.gradientEndOpacity),
            theme.panel.backgroundColor.withOpacity(theme.panel.gradientStartOpacity),
          ];
    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, overlayTop),
        Offset(0, overlayTop + overlayHeight),
        gradientColors,
      );
    canvas.drawRect(panelRect, gradientPaint);

    if (theme.panel.showBorder) {
      final borderPaint = Paint()
        ..color = theme.panel.borderColor.withOpacity(theme.panel.borderOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = theme.panel.borderWidth;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            theme.panel.borderWidth / 2,
            overlayTop + theme.panel.borderWidth / 2,
            photoWidth - theme.panel.borderWidth,
            overlayHeight - theme.panel.borderWidth,
          ),
          Radius.circular(theme.panel.borderRadius),
        ),
        borderPaint,
      );
    }

    if (theme.panel.showHighlight && theme.panel.highlightOpacity > 0) {
      final highlightPaint = Paint()
        ..color = theme.panel.highlightColor.withOpacity(theme.panel.highlightOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawRect(
        Rect.fromLTWH(
          theme.panel.borderWidth + 2,
          overlayTop + theme.panel.borderWidth + 2,
          photoWidth - (theme.panel.borderWidth + 2) * 2,
          1.0,
        ),
        highlightPaint,
      );
    }

    // Accent bar
    final accentBarW = theme.accent.showBar ? theme.accent.barWidth : 0.0;
    final accentBarSpace = accentBarW + padding * 0.5;
    final logoMaxSize = metrics.logoMaxSize;
    final logoReserve = (hasLogo && logoPath != null) ? logoMaxSize + padding * 1.4 : 0.0;
    final textContentWidth = photoWidth - padding * 2 - logoReserve - accentBarSpace;
    final double textX = isLeftAligned
        ? padding + accentBarSpace
        : photoWidth - padding - textContentWidth;
    double textY = overlayTop + padding * 0.95;

    if (theme.accent.showBar && accentBarW > 0) {
      final barX = isLeftAligned ? padding : photoWidth - padding - accentBarW;
      final barcodeBonus = previewData.hasBarcode ? theme.typography.barcodeRowBonus : 0.0;
      final titleBonus = previewData.hasLocation ? theme.typography.titleRowBonus : 0.0;
      final textBlockHeight =
          metrics.textRowCount * metrics.lineHeight + barcodeBonus + titleBonus;
      canvas.drawRect(
        Rect.fromLTWH(
          barX,
          overlayTop + padding * 0.85,
          accentBarW,
          textBlockHeight,
        ),
        Paint()..color = c.withOpacity(theme.accent.barOpacity),
      );
    }

    // Fungsi teks (sama)
    void drawLabelValue(String label, String value, Color valueColor,
        {bool emphasize = false, double? customFontSize}) {
      final valueFontSize = customFontSize ??
          (emphasize ? theme.typography.barcodeFontSize : theme.typography.bodyFontSize);
      final rowLineHeight = emphasize
          ? theme.typography.barcodeLineHeight
          : metrics.lineHeight;

      String displayLabel = label;
      if (theme.typography.useSpacedLabels &&
          theme.typography.spacedLabelKeys.contains(label)) {
        displayLabel = label.split('').join('\u200a ');
      }

      TextHelper.paintText(
        canvas: canvas,
        text: displayLabel,
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: Colors.white.withOpacity(0.45),
        fontSize: theme.typography.captionFontSize,
        fontWeight: FontWeight.w700,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: previewData.fontFamily,
      );
      TextHelper.paintText(
        canvas: canvas,
        text: value,
        x: textX,
        y: textY + valueFontSize * 0.78,
        maxWidth: textContentWidth,
        color: valueColor,
        fontSize: valueFontSize,
        fontWeight: emphasize ? FontWeight.w600 : FontWeight.w500,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: previewData.fontFamily,
      );
      textY += rowLineHeight;
    }

    void drawTitleRow(String text) {
      TextHelper.paintText(
        canvas: canvas,
        text: text,
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: c,
        fontSize: theme.typography.titleFontSize,
        fontWeight: FontWeight.w800,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: previewData.fontFamily,
      );
      textY += metrics.lineHeight + theme.typography.titleRowBonus;
    }

    void drawCoordLine(String text) {
      if (text.isEmpty) return;
      TextHelper.paintText(
        canvas: canvas,
        text: text,
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: Colors.white.withOpacity(0.65),
        fontSize: theme.typography.captionFontSize,
        fontWeight: FontWeight.w600,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: previewData.fontFamily,
      );
      textY += metrics.lineHeight;
    }

    // Informasi
    if (previewData.hasLocation) {
      drawTitleRow(previewData.locationName!);
    }
    drawLabelValue(
      'TANGGAL',
      previewData.formattedDate,
      Colors.white.withOpacity(0.85),
      customFontSize: theme.typography.barcodeFontSize,
    );
    drawLabelValue(
      'JAM',
      previewData.formattedTime,
      Colors.white.withOpacity(0.80),
      customFontSize: theme.typography.barcodeFontSize,
    );
    textY += theme.typography.groupSpacing;

    if (previewData.hasOperator) {
      drawLabelValue(
        'OPERATOR',
        previewData.operatorName,
        Colors.white.withOpacity(0.92),
      );
    }
    if (previewData.hasBarcode) {
      drawLabelValue(
        'KODE BARANG',
        previewData.barcodeValue ?? '',
        Colors.white,
        emphasize: true,
      );
    }
    if (previewData.hasCoordinates) {
      textY += theme.typography.coordSpacing;
      drawCoordLine(previewData.latText);
      drawCoordLine(previewData.lonText);
    }

    // Logo (placeholder)
    if (hasLogo && logoPath != null) {
      final logoSize = metrics.logoMaxSize;
      final drawW = logoSize * 0.8;
      final drawH = logoSize * 0.8;
      double logoX = isLeftAligned ? photoWidth - padding - drawW : padding;
      double logoY;
      if (theme.logo.centerVertically) {
        logoY = overlayTop + (overlayHeight - drawH) / 2;
      } else {
        logoY = isBottom ? photoHeight - padding - drawH : padding;
      }

      final cardPad = theme.logoCardPadding(drawW);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            logoX - cardPad,
            logoY - cardPad,
            drawW + cardPad * 2,
            drawH + cardPad * 2,
          ),
          Radius.circular(theme.logoCardRadius(cardPad)),
        ),
        Paint()..color = Colors.black.withOpacity(theme.logo.cardOpacity),
      );

      final iconPaint2 = Paint()..color = Colors.white38;
      canvas.drawRect(Rect.fromLTWH(logoX, logoY, drawW, drawH), iconPaint2);
      final textStyle = ui.TextStyle(
        color: Colors.white54,
        fontSize: 10,
        fontWeight: FontWeight.w500,
      );
      final para = ui.ParagraphBuilder(textStyle)
        ..addText('LOGO')
        ..build()
        ..layout(ui.ParagraphConstraints(width: drawW));
      canvas.drawParagraph(
        para,
        Offset(logoX + (drawW - para.width) / 2, logoY + (drawH - para.height) / 2),
      );
    }

    // Label layout
    final labelPaint = Paint()..color = Colors.grey.withOpacity(0.85);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(6, 6, 70, 16), Radius.circular(4)),
      labelPaint,
    );
    final labelStyle = ui.TextStyle(
      color: Colors.grey,
      fontSize: 8,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    );
    final labelPara = ui.ParagraphBuilder(labelStyle)
      ..addText('🏢 Professional')
      ..build()
      ..layout(ui.ParagraphConstraints(width: 70));
    canvas.drawParagraph(labelPara, const Offset(8, 7));
  }

  @override
  bool shouldRepaint(covariant _ProfessionalPreviewPainter oldDelegate) => false;
}
