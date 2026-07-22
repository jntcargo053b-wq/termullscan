// ============================================================
// lib/watermark/layouts/stamp_layout.dart (FINAL)
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
import '../helpers/watermark_typography.dart';
import '../utils/text_painter_cache.dart';
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
  }) {
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final padding = LayoutHelper.padding(baseSize);

    int lineCount = 1;
    if (data.hasBarcode) lineCount++;
    if (data.hasOperator) lineCount++;
    lineCount++; // location

    final fontSz = data.fontSize;
    final lineH = WatermarkTypography.lineHeight(fontSz);

    final barcodeLineH =
        WatermarkTypography.lineHeight(WatermarkTypography.barcode(fontSz));
    final barcodeBonus = data.hasBarcode ? (barcodeLineH - lineH) : 0.0;

    final panelHeight = lineCount * lineH + barcodeBonus + padding * 1.4;

    final logoMaxSize = WatermarkTypography.logo(baseSize);
    final panelWidth = baseSize * 0.50;
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
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
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

  // ─── INTERNAL PAINT ──────────────────────────────────────────
  void _paint({
    required ui.Canvas canvas,
    required LayoutMetrics metrics,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    final padding = metrics.padding;
    final baseSize = metrics.baseSize;

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
    final strokeWidth = math.max(2.5, baseSize * 0.005);

    // ─── STAMP BACKGROUND ──────────────────────────────────────
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

    // ─── STAMP TEXT ────────────────────────────────────────────
    var titleFontSize =
        math.min(WatermarkTypography.title(data.fontSize), stampH * 0.32);
    var captionFontSize =
        math.min(WatermarkTypography.caption(data.fontSize), stampH * 0.18);
    final stampTextMaxWidth = stampW - 24;
    final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(data.timestamp);

    // ✅ FIX OVERLAP: posisi baris di dalam lencana dulu memakai jarak
    // "ajaib" (titleLineH*0.62, captionLineH*0.75) yang tidak selalu
    // cukup menampung tinggi teks sebenarnya — pada kombinasi label +
    // operator + tanggal (3 baris), baris tanggal bisa meluber keluar
    // garis tepi lencana. Sekarang tinggi tiap baris DIUKUR langsung
    // (TextHelper.measureText), lalu jika totalnya tidak muat di dalam
    // tinggi lencana, seluruh font di dalam lencana diperkecil secara
    // proporsional sampai benar-benar muat — dijamin tidak overlap.
    const lineGapRatio = 0.18; // jarak antar baris, relatif thd font size
    double measureTotalHeight() {
      final gap = captionFontSize * lineGapRatio;
      double h = TextHelper.measureText(
        text: stampLabel,
        maxWidth: stampTextMaxWidth,
        fontSize: titleFontSize,
        fontWeight: FontWeight.w900,
        fontFamily: data.fontFamily,
      ).height;
      if (data.hasOperator) {
        h += gap +
            TextHelper.measureText(
              text: data.operatorName.toUpperCase(),
              maxWidth: stampTextMaxWidth,
              fontSize: captionFontSize,
              fontWeight: FontWeight.w600,
              fontFamily: data.fontFamily,
            ).height;
      }
      h += gap +
          TextHelper.measureText(
            text: dateStr,
            maxWidth: stampTextMaxWidth,
            fontSize: captionFontSize,
            fontWeight: FontWeight.w600,
            fontFamily: data.fontFamily,
          ).height;
      return h;
    }

    final maxBlockHeight = stampH * 0.84; // sisakan margin atas/bawah ~8%
    var totalHeight = measureTotalHeight();
    if (totalHeight > maxBlockHeight && totalHeight > 0) {
      final shrink = maxBlockHeight / totalHeight;
      titleFontSize *= shrink;
      captionFontSize *= shrink;
      totalHeight = measureTotalHeight();
    }

    final gap = captionFontSize * lineGapRatio;
    double textY = -totalHeight / 2;

    final titleH = TextHelper.paintText(
      canvas: canvas,
      text: stampLabel,
      x: -stampW / 2 + 12,
      y: textY,
      maxWidth: stampTextMaxWidth,
      color: stampColor,
      fontSize: titleFontSize,
      fontWeight: FontWeight.w900,
      textAlign: TextAlign.center,
      fontFamily: data.fontFamily,
    );
    textY += titleH + gap;

    if (data.hasOperator) {
      final opH = TextHelper.paintText(
        canvas: canvas,
        text: data.operatorName.toUpperCase(),
        x: -stampW / 2 + 12,
        y: textY,
        maxWidth: stampTextMaxWidth,
        color: stampColor,
        fontSize: captionFontSize,
        fontWeight: FontWeight.w600,
        textAlign: TextAlign.center,
        fontFamily: data.fontFamily,
      );
      textY += opH + gap;
    }

    TextHelper.paintText(
      canvas: canvas,
      text: dateStr,
      x: -stampW / 2 + 12,
      y: textY,
      maxWidth: stampTextMaxWidth,
      color: stampColor,
      fontSize: captionFontSize,
      fontWeight: FontWeight.w600,
      textAlign: TextAlign.center,
      fontFamily: data.fontFamily,
    );

    canvas.restore();

    // ─── INFO PANEL ────────────────────────────────────────────
    final infoLines = <(String, bool)>[];
    if (data.hasBarcode) infoLines.add((data.barcodeValue!, true));
    if (data.hasOperator) infoLines.add(('OP: ${data.operatorName}', false));
    infoLines.add((data.displayLocation, false));

    final fontSize = data.fontSize;
    final lineHeight = WatermarkTypography.lineHeight(fontSize);
    final barcodeRowH =
        WatermarkTypography.lineHeight(WatermarkTypography.barcode(fontSize));
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

    // ─── PANEL BACKGROUND ─────────────────────────────────────
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(panelX, panelY, panelWidth, panelHeight),
        Radius.circular(8),
      ),
      Paint()
        ..color = Colors.black.withOpacity(data.backgroundOpacity * 1.2)
        ..style = PaintingStyle.fill,
    );

    final accentBarW = math.max(3.0, baseSize * 0.004);
    canvas.drawRect(
      Rect.fromLTWH(
        panelX + 3,
        panelY + 6,
        accentBarW,
        panelHeight - 12,
      ),
      Paint()..color = stampColor.withOpacity(0.7),
    );

    // ─── PANEL TEXT ────────────────────────────────────────────
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
        fontSize: isBarcode
            ? WatermarkTypography.barcode(fontSize)
            : WatermarkTypography.body(fontSize),
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
