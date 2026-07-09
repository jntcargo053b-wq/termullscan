// ============================================================
// lib/watermark/layouts/professional_layout.dart (REFACTORED + FIX SPACING)
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
import '../helpers/watermark_typography.dart';
import '../widgets/logo_widget.dart';

class ProfessionalLayout extends WatermarkLayout {
  @override
  String get displayName => '🏢 Professional';

  @override
  WatermarkStyle get style => WatermarkStyle.professional;

  static const Color _accentColor = Color(0xFF4FA8E8);

  // ─── KONSTANTA SPASI ──────────────────────────────────────────
  static const double _rowSpacingMultiplier = 1.8; // ✅ Perbaikan: spasi antar baris lebih besar
  static const double _labelValueOffset = 0.78;   // offset value terhadap label
  static const double _topPaddingFactor = 0.85;
  static const double _bottomPaddingFactor = 0.7;
  static const double _logoCardScale = 0.25;
  static const double _logoCardRadiusScale = 0.8;
  static const double _accentBarWidthScale = 0.004;

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

    final fontSz = data.fontSize;
    // ✅ Perbaikan: gunakan multiplier yang lebih besar untuk spasi antar baris
    final lineH = fontSz * _rowSpacingMultiplier;

    // Barcode memiliki font lebih besar, jadi butuh extra space
    final barcodeFontSize = WatermarkTypography.barcode(fontSz);
    final barcodeLineH = barcodeFontSize * _rowSpacingMultiplier;
    final barcodeBonus = data.hasBarcode ? (barcodeLineH - lineH) : 0.0;

    final overlayHeight = math.max(
      photoHeight * 0.14,
      rowCount * lineH + barcodeBonus + padding * 2.0,
    );

    final logoMaxSize = WatermarkTypography.logo(baseSize);
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
    // Gambar foto
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

    // ─── BACKGROUND GRADIEN ──────────────────────────────────
    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, overlayTop),
        Offset(0, overlayTop + overlayHeight),
        overlayAtBottom
            ? [
                Colors.black.withOpacity(0.0),
                Colors.black.withOpacity(data.backgroundOpacity * 0.55),
                Colors.black.withOpacity(data.backgroundOpacity),
              ]
            : [
                Colors.black.withOpacity(data.backgroundOpacity),
                Colors.black.withOpacity(data.backgroundOpacity * 0.55),
                Colors.black.withOpacity(0.0),
              ],
        overlayAtBottom ? [0.0, 0.45, 1.0] : [0.0, 0.55, 1.0],
      );
    canvas.drawRect(
      Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight),
      gradientPaint,
    );

    // ─── GARIS PEMISAH ──────────────────────────────────────
    final dividerY = overlayAtBottom ? overlayTop : overlayTop + overlayHeight;
    canvas.drawLine(
      Offset(0, dividerY),
      Offset(photoWidth, dividerY),
      Paint()
        ..color = Colors.white.withOpacity(0.10)
        ..strokeWidth = 1,
    );

    // ─── LAYOUT: TEKS + LOGO ──────────────────────────────────
    final logoMaxSize = metrics.logoMaxSize;
    final accentBarW = math.max(2.0, baseSize * _accentBarWidthScale);
    final accentBarSpace = accentBarW + padding * 0.5;
    final logoReserve = (logoImage != null) ? logoMaxSize + padding * 1.4 : 0.0;
    final textContentWidth = photoWidth - padding * 2 - logoReserve - accentBarSpace;

    final double textX = textAlign == TextAlign.left
        ? padding + accentBarSpace
        : photoWidth - padding - textContentWidth;
    double textY = overlayTop + padding * _topPaddingFactor;

    // ─── ACCENT BAR ──────────────────────────────────────────
    final barX = textAlign == TextAlign.left
        ? padding
        : photoWidth - padding - accentBarW;
    final barcodeFontSize = data.hasBarcode
        ? WatermarkTypography.barcode(data.fontSize)
        : data.fontSize;
    final barcodeLineH = barcodeFontSize * _rowSpacingMultiplier;
    final normalLineH = data.fontSize * _rowSpacingMultiplier;
    final barcodeBonus = data.hasBarcode ? (barcodeLineH - normalLineH) : 0.0;
    final textBlockHeight =
        metrics.textRowCount * normalLineH + barcodeBonus;
    canvas.drawRect(
      Rect.fromLTWH(
        barX,
        overlayTop + padding * 0.7,
        accentBarW,
        textBlockHeight,
      ),
      Paint()..color = _accentColor.withOpacity(0.9),
    );

    // ─── FUNGSI GAMBAR 1 BARIS (LABEL + VALUE) ──────────────
    void drawLabelValue(String label, String value, Color valueColor, {bool emphasize = false}) {
      final valueFontSize = emphasize
          ? WatermarkTypography.barcode(data.fontSize)
          : WatermarkTypography.body(data.fontSize);
      final labelFontSize = WatermarkTypography.caption(data.fontSize);

      // ✅ PERBAIKAN: Hitung tinggi baris berdasarkan konten
      // Value di-offset ke bawah sebesar valueFontSize * _labelValueOffset
      // Total tinggi = offset + tinggi value
      final labelHeight = WatermarkTypography.lineHeight(labelFontSize);
      final valueHeight = WatermarkTypography.lineHeight(valueFontSize);
      final totalHeightNeeded = (valueFontSize * _labelValueOffset) + valueHeight;
      final rowLineHeight = math.max(labelHeight, totalHeightNeeded) + 4; // +4 padding

      // Label (uppercase, abu-abu, kecil)
      final labelY = textY + (rowLineHeight - labelHeight) / 2;
      TextHelper.paintText(
        canvas: canvas,
        text: label.toUpperCase(),
        x: textX,
        y: labelY,
        maxWidth: textContentWidth,
        color: Colors.white.withOpacity(0.45),
        fontSize: labelFontSize,
        fontWeight: FontWeight.w700,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );

      // Value (besar, bold, warna sesuai)
      final valueY = textY + (valueFontSize * _labelValueOffset);
      TextHelper.paintText(
        canvas: canvas,
        text: value,
        x: textX,
        y: valueY,
        maxWidth: textContentWidth,
        color: valueColor,
        fontSize: valueFontSize,
        fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );

      textY += rowLineHeight;
    }

    // ─── RENDER BARIS ──────────────────────────────────────────
    if (data.hasBarcode) {
      drawLabelValue('KODE BARANG', data.barcodeValue ?? '', Colors.white, emphasize: true);
    }
    if (data.hasOperator) {
      drawLabelValue('OPERATOR', data.operatorName, Colors.white.withOpacity(0.92));
    }
    drawLabelValue('WAKTU', data.formattedTimestamp, Colors.white.withOpacity(0.80));
    drawLabelValue('LOKASI', data.displayLocation, Colors.white.withOpacity(0.70));

    // ─── LOGO ──────────────────────────────────────────────────
    if (logoImage != null) {
      final logoMaxH = logoMaxSize;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoMaxH / logoW, logoMaxH / logoH);
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
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            logoX - cardPad,
            logoY - cardPad,
            drawW + cardPad * 2,
            drawH + cardPad * 2,
          ),
          Radius.circular(cardPad * _logoCardRadiusScale),
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
                heightFactor: overlayFractionHeight.clamp(0.18, 0.9),
                widthFactor: 1.0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                    crossAxisAlignment: CrossAxisAlignment.end,
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
      width: 2.5,
      height: 36,
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
          _PreviewField(
            label: 'KODE BARANG',
            value: previewData.barcodeValue ?? '',
            valueColor: Colors.white,
            bold: true,
            alignEnd: !isLeftAligned,
          ),
        if (previewData.hasOperator)
          _PreviewField(
            label: 'OPERATOR',
            value: previewData.operatorName,
            valueColor: Colors.white.withOpacity(0.92),
            alignEnd: !isLeftAligned,
          ),
        _PreviewField(
          label: 'WAKTU',
          value: previewData.formattedTimestamp,
          valueColor: Colors.white.withOpacity(0.80),
          alignEnd: !isLeftAligned,
        ),
        _PreviewField(
          label: 'LOKASI',
          value: previewData.displayLocation,
          valueColor: Colors.white.withOpacity(0.70),
          alignEnd: !isLeftAligned,
        ),
      ],
    );
  }
}

class _PreviewField extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;
  final bool bold;
  final bool alignEnd;

  const _PreviewField({
    required this.label,
    required this.value,
    required this.valueColor,
    this.bold = false,
    this.alignEnd = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Column(
        crossAxisAlignment:
            alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.45),
              fontSize: 6.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: bold ? 10.5 : 9.5,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: alignEnd ? TextAlign.right : TextAlign.left,
          ),
        ],
      ),
    );
  }
}
