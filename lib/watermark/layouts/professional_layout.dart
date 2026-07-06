// ============================================================
// lib/watermark/layouts/professional_layout.dart (FINAL – WatermarkTheme)
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
    final baseSize = theme.baseSize;
    final padding = theme.padding;

    // Baris yang SELALU ada: tanggal + jam (dipisah, bukan digabung jadi
    // satu baris seperti sebelumnya — mengikuti panel info kamera profesional).
    int rowCount = 2; // tanggal, jam
    if (data.hasBarcode) rowCount++;
    if (data.hasOperator) rowCount++;
    final hasLocationTitle = data.hasLocation;
    if (hasLocationTitle) rowCount++; // baris judul nama lokasi
    if (data.hasCoordinates) rowCount += 2; // Lat + Lon, baris kecil terpisah

    final lineH = theme.lineHeight; // ✅ konsisten di semua layout
    final barcodeBonus = data.hasBarcode ? theme.barcodeRowBonus : 0.0;
    final titleBonus = hasLocationTitle ? theme.titleRowBonus : 0.0;

    final overlayHeight = math.max(
      photoHeight * 0.14,
      rowCount * lineH + barcodeBonus + titleBonus + padding * 2.0,
    );

    final logoMaxSize = theme.logoSize;
    final rightReserved = logoMaxSize + padding * 1.4;
    final accentBarSpace = theme.accentBarWidth + padding * 0.5;
    final textW = photoWidth - padding * 2 - rightReserved - accentBarSpace;

    return LayoutMetrics(
      baseSize: baseSize,
      padding: padding,
      fontSize: theme.fontSize,
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
    final baseSize = metrics.baseSize;
    final overlayHeight = metrics.stripHeight;
    final c = theme.color;

    final placement = WatermarkAlignment.resolve(
      position: data.position,
      photoHeight: photoHeight,
      overlayHeight: overlayHeight,
    );
    final overlayTop = placement.top;
    final textAlign = placement.textAlign;
    final overlayAtBottom = placement.atBottom;

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

    final dividerY = overlayAtBottom ? overlayTop : overlayTop + overlayHeight;
    WatermarkDivider.onDark.paint(
      canvas,
      Offset(0, dividerY),
      Offset(photoWidth, dividerY),
    );

    final logoMaxSize = metrics.logoMaxSize;
    final accentBarW = theme.accentBarWidth;
    final accentBarSpace = accentBarW + padding * 0.5;
    final logoReserve = (logoImage != null) ? logoMaxSize + padding * 1.4 : 0.0;
    final textContentWidth = photoWidth - padding * 2 - logoReserve - accentBarSpace;

    final double textX = textAlign == TextAlign.left
        ? padding + accentBarSpace
        : photoWidth - padding - textContentWidth;
    double textY = overlayTop + padding * 0.95;

    final barX = textAlign == TextAlign.left
        ? padding
        : photoWidth - padding - accentBarW;
    final barcodeBonus = data.hasBarcode ? theme.barcodeRowBonus : 0.0;
    final titleBonus = data.hasLocation ? theme.titleRowBonus : 0.0;
    final textBlockHeight =
        metrics.textRowCount * metrics.lineHeight + barcodeBonus + titleBonus;
    canvas.drawRect(
      Rect.fromLTWH(
        barX,
        overlayTop + padding * 0.85,
        accentBarW,
        textBlockHeight,
      ),
      Paint()..color = c.accent.withOpacity(0.9),
    );

    void drawLabelValue(
      String label,
      String value,
      Color valueColor, {
      bool emphasize = false,
    }) {
      final valueFontSize =
          emphasize ? theme.barcodeFontSize : theme.bodyFontSize;
      final rowLineHeight =
          emphasize ? theme.barcodeLineHeight : metrics.lineHeight;

      TextHelper.paintText(
        canvas: canvas,
        text: _spaceOutLabel(label),
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: Colors.white.withOpacity(0.45),
        fontSize: theme.captionFontSize,
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
        fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
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
        color: c.accent,
        fontSize: theme.titleFontSize,
        fontWeight: FontWeight.w800,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      textY += metrics.lineHeight + theme.titleRowBonus;
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
        fontSize: theme.captionFontSize,
        fontWeight: FontWeight.w600,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: data.fontFamily,
      );
      textY += metrics.lineHeight;
    }

    // ─── Urutan sesuai panel info kamera profesional ───────
    // Nama lokasi (besar, aksen) → data operasional (barcode/operator) →
    // tanggal & jam terpisah → koordinat (kecil, opsional, skip jika kosong)
    if (data.hasLocation) {
      drawTitleRow(data.locationName!);
    }
    if (data.hasBarcode) {
      drawLabelValue(
        'KODE BARANG',
        data.barcodeValue ?? '',
        Colors.white,
        emphasize: true,
      );
    }
    if (data.hasOperator) {
      drawLabelValue(
        'OPERATOR',
        data.operatorName,
        Colors.white.withOpacity(0.92),
      );
    }
    drawLabelValue(
      'TANGGAL',
      data.formattedDate,
      Colors.white.withOpacity(0.85),
    );
    drawLabelValue(
      'JAM',
      data.formattedTime,
      Colors.white.withOpacity(0.80),
    );
    if (data.hasCoordinates) {
      drawCoordLine(data.latText);
      drawCoordLine(data.lonText);
    }

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

    final overlayFractionHeight = metrics.stripHeight / previewHeight;
    final isBottom = previewData.position == WatermarkPosition.bottomRight ||
        previewData.position == WatermarkPosition.bottomLeft ||
        (previewData.position != WatermarkPosition.topLeft &&
            previewData.position != WatermarkPosition.topRight);
    final isLeftAligned = WatermarkAlignment.isLeftAligned(previewData.position);

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
                        _buildAccentBar(theme),
                        const Gap(8),
                        Expanded(child: _buildTextColumn(previewData, isLeftAligned)),
                      ] else ...[
                        Expanded(child: _buildTextColumn(previewData, isLeftAligned)),
                        const Gap(8),
                        _buildAccentBar(theme),
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

  Widget _buildAccentBar(WatermarkTheme theme) {
    return Container(
      width: 2.5,
      height: 36,
      decoration: BoxDecoration(
        color: theme.color.accent,
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
        if (previewData.hasLocation)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              previewData.locationName!,
              style: const TextStyle(
                color: Color(0xFFFFA726), // aksen oranye tema professional
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: isLeftAligned ? TextAlign.left : TextAlign.right,
            ),
          ),
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
          label: 'TANGGAL',
          value: previewData.formattedDate,
          valueColor: Colors.white.withOpacity(0.85),
          alignEnd: !isLeftAligned,
        ),
        _PreviewField(
          label: 'JAM',
          value: previewData.formattedTime,
          valueColor: Colors.white.withOpacity(0.80),
          alignEnd: !isLeftAligned,
        ),
        if (previewData.hasCoordinates) ...[
          Text(
            previewData.latText,
            style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 7.5),
            textAlign: isLeftAligned ? TextAlign.left : TextAlign.right,
          ),
          Text(
            previewData.lonText,
            style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 7.5),
            textAlign: isLeftAligned ? TextAlign.left : TextAlign.right,
          ),
        ],
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
