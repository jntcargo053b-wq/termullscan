// ============================================================
// lib/watermark/layouts/stamp_layout.dart (FINAL – WatermarkTheme)
// ============================================================
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'base_layout.dart';
import 'layout_metrics.dart';
import '../models/watermark_data.dart';
import '../watermark_style.dart';
import '../watermark_settings.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../theme/watermark_theme.dart';
import '../widgets/logo_widget.dart';

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
    required WatermarkTheme theme,
  }) {
    final baseSize = theme.baseSize;
    final padding = theme.padding;

    int lineCount = 1;
    if (data.hasBarcode) lineCount++;
    if (data.hasOperator) lineCount++;
    lineCount++; // location

    final lineH = theme.lineHeight; // ✅ konsisten di semua layout
    final barcodeBonus = data.hasBarcode ? theme.barcodeRowBonus : 0.0;

    final panelHeight = lineCount * lineH + barcodeBonus + padding * 1.4;

    final logoMaxSize = theme.logoSize;
    final panelWidth = baseSize * 0.50;
    final textW = panelWidth - padding * 0.8;

    return LayoutMetrics(
      baseSize: baseSize,
      padding: padding,
      fontSize: theme.fontSize,
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
    required WatermarkTheme theme,
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

    final stampW = baseSize * 0.35;
    final stampH = baseSize * 0.18;
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
      default:
        stampCenterX = photoWidth - padding - stampW / 2;
        stampCenterY = photoHeight - padding - stampH / 2;
    }

    canvas.save();
    canvas.translate(stampCenterX, stampCenterY);
    canvas.rotate(-0.06);

    final stampRect = Rect.fromCenter(center: Offset.zero, width: stampW, height: stampH);
    final strokeWidth = theme.stampStroke;

    canvas.drawRRect(
      RRect.fromRectAndRadius(stampRect, Radius.circular(stampH * 0.14)),
      Paint()
        ..color = stampColor.withOpacity(0.12)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(stampRect, Radius.circular(stampH * 0.14)),
      Paint()
        ..color = stampColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    // "VERIFIED"/"MANUAL" adalah elemen Judul stempel → idealnya mengikuti
    // theme.titleFontSize (berbasis data.fontSize) supaya konsisten dengan
    // layout lain saat fontSize diubah. TAPI kotak stempel (stampW x stampH)
    // ukurannya tetap (berbasis baseSize foto, bukan fontSize), jadi di foto
    // kecil + fontSize besar, teks bisa lebih besar dari kotaknya. Maka
    // di-clamp ke rasio lama (stampH * 0.32 / 0.18) sebagai batas aman —
    // dipakai rasio mana pun yang LEBIH KECIL.
    final titleFontSize = theme.clampedFontSize(theme.titleFontSize, stampH * 0.32);
    final captionFontSize = theme.clampedFontSize(theme.captionFontSize, stampH * 0.18);
    final titleLineH = math.max(titleFontSize * 1.7, stampH * 0.30);
    final captionLineH = math.max(captionFontSize * 1.7, stampH * 0.24);

    double textY = -stampH * 0.20;
    TextHelper.paintText(
      canvas: canvas,
      text: stampLabel,
      x: -stampW / 2 + 12,
      y: textY,
      maxWidth: stampW - 24,
      color: stampColor,
      fontSize: titleFontSize,
      fontWeight: FontWeight.w900,
      textAlign: TextAlign.center,
      fontFamily: data.fontFamily,
    );

    textY += stampH * 0.30;
    if (data.hasOperator) {
      TextHelper.paintText(
        canvas: canvas,
        text: data.operatorName.toUpperCase(),
        x: -stampW / 2 + 12,
        y: textY,
        maxWidth: stampW - 24,
        color: stampColor,
        fontSize: captionFontSize,
        fontWeight: FontWeight.w600,
        textAlign: TextAlign.center,
        fontFamily: data.fontFamily,
      );
      textY += stampH * 0.24;
    }

    final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(data.timestamp);
    TextHelper.paintText(
      canvas: canvas,
      text: dateStr,
      x: -stampW / 2 + 12,
      y: textY,
      maxWidth: stampW - 24,
      color: stampColor,
      fontSize: captionFontSize * 0.9,
      fontWeight: FontWeight.w600,
      textAlign: TextAlign.center,
      fontFamily: data.fontFamily,
    );

    canvas.restore();

    // ─── INFO PANEL ────────────────────────────────────────────
    // (text, isBarcode) supaya baris kode bisa ditekankan seperti layout lain.
    final infoLines = <(String, bool)>[];
    if (data.hasBarcode) infoLines.add((data.barcodeValue!, true));
    if (data.hasOperator) infoLines.add(('OP: ${data.operatorName}', false));
    infoLines.add((data.displayLocation, false));

    final fontSize = theme.fontSize;
    final lineHeight = theme.lineHeight; // ✅ konsisten
    final barcodeRowH = theme.barcodeLineHeight;
    final panelPadding = 12.0;
    final panelHeight = infoLines.fold<double>(
          0.0,
          (sum, line) => sum + (line.$2 ? barcodeRowH : lineHeight),
        ) +
        panelPadding * 2;
    final panelWidth = metrics.textAvailableWidth + panelPadding * 2;

    double panelX, panelY;
    switch (data.position) {
      case WatermarkPosition.bottomRight:
        panelX = photoWidth - padding - panelWidth;
        panelY = photoHeight - padding - panelHeight - stampH - padding * 1.2;
        break;
      case WatermarkPosition.bottomLeft:
        panelX = padding;
        panelY = photoHeight - padding - panelHeight - stampH - padding * 1.2;
        break;
      case WatermarkPosition.topRight:
        panelX = photoWidth - padding - panelWidth;
        panelY = padding + stampH + padding * 1.2;
        break;
      case WatermarkPosition.topLeft:
        panelX = padding;
        panelY = padding + stampH + padding * 1.2;
        break;
      default:
        panelX = photoWidth - padding - panelWidth;
        panelY = photoHeight - padding - panelHeight - stampH - padding * 1.2;
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

    final accentBarW = theme.accentBarWidth;
    canvas.drawRect(
      Rect.fromLTWH(
        panelX + 3,
        panelY + 6,
        accentBarW,
        panelHeight - 12,
      ),
      Paint()..color = stampColor.withOpacity(0.7),
    );

    double textY2 = panelY + panelPadding;
    final textX2 = panelX + panelPadding + 8;
    for (final (text, isBarcode) in infoLines) {
      TextHelper.paintText(
        canvas: canvas,
        text: text,
        x: textX2,
        y: textY2,
        maxWidth: panelWidth - panelPadding * 2 - 12,
        color: Colors.white,
        fontSize: isBarcode ? theme.barcodeFontSize : theme.bodyFontSize,
        fontWeight: isBarcode ? FontWeight.w800 : FontWeight.w600,
        maxLines: 1,
        fontFamily: data.fontFamily,
      );
      textY2 += isBarcode ? barcodeRowH : lineHeight;
    }

    // ─── LOGO ────────────────────────────────────────────────────
    if (logoImage != null) {
      final logoSize = metrics.logoMaxSize;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoSize / logoW, logoSize / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      double logoX, logoY;
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
        default:
          logoX = padding;
          logoY = padding;
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
    final baseSize = LayoutHelper.getBaseSize(previewWidth, previewHeight);
    final theme = WatermarkTheme.of(style: style, data: previewData, baseSize: baseSize);
    final metrics = computeMetrics(
      photoWidth: previewWidth,
      photoHeight: previewHeight,
      data: previewData,
      theme: theme,
    );

    final stampColor = previewData.isManual ? const Color(0xFFE67E22) : const Color(0xFF2E8B57);
    final stampLabel = previewData.isManual ? 'MANUAL' : 'VERIFIED';

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade700.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: stampColor, width: 2),
                  borderRadius: BorderRadius.circular(6),
                  color: stampColor.withOpacity(0.1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      stampLabel,
                      style: TextStyle(
                        color: stampColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const Gap(4),
                    if (previewData.hasOperator)
                      Text(
                        previewData.operatorName.toUpperCase(),
                        style: TextStyle(
                          color: stampColor,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    Text(
                      previewData.formattedTimestamp,
                      style: TextStyle(
                        color: stampColor,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
                const Gap(8),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Image.file(
                    File(logoPath),
                    width: metrics.logoMaxSize * 0.6,
                    height: metrics.logoMaxSize * 0.6,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image, color: Colors.white38, size: 14),
                  ),
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
      ),
    );
  }
}
