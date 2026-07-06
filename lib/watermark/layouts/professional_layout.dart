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
    // Responsif terhadap orientasi
    final isPortrait = photoHeight > photoWidth;
    double effectiveBaseSize = theme.baseSize;
    double effectivePadding = theme.padding;
    if (theme.usePortraitScaling && isPortrait) {
      effectiveBaseSize *= theme.portraitScaleFactor;
      effectivePadding *= theme.portraitScaleFactor;
    }

    // Hitung jumlah baris
    int rowCount = 2; // tanggal, jam
    if (data.hasBarcode) rowCount++;
    if (data.hasOperator) rowCount++;
    final hasLocationTitle = data.hasLocation;
    if (hasLocationTitle) rowCount++; // judul lokasi
    if (data.hasCoordinates) rowCount += 2; // Lat + Lon

    final lineH = effectiveBaseSize * theme.lineHeight;
    final barcodeBonus = data.hasBarcode ? theme.barcodeRowBonus : 0.0;
    final titleBonus = hasLocationTitle ? theme.titleRowBonus : 0.0;

    // Tinggi panel minimal 9–11% dari tinggi frame
    final minHeight = photoHeight * theme.minPanelHeightFraction;
    final contentHeight = rowCount * lineH + barcodeBonus + titleBonus + effectivePadding * 2.0;
    final overlayHeight = math.max(minHeight, contentHeight);

    final logoMaxSize = effectiveBaseSize * (theme.logoSize / 10.0) * theme.logoScaleFactor;
    final rightReserved = logoMaxSize + effectivePadding * 1.4;
    final accentBarSpace = theme.accentBarWidth + effectivePadding * 0.5;
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
    final baseSize = metrics.baseSize;
    final overlayHeight = metrics.stripHeight;
    final c = theme.color;

    // Posisi panel (bawah/tengah)
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

    // ============================================================
    //  BACKGROUND PANEL PREMIUM (solid + gradien + border + highlight)
    // ============================================================
    final panelRect = Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight);

    // Layer 1: solid dengan opacity 55%
    canvas.drawRect(
      panelRect,
      Paint()..color = theme.panelBackgroundColor.withOpacity(theme.panelBackgroundOpacity),
    );

    // Layer 2: gradien halus dari atas ke bawah (atau sebaliknya)
    final gradientColors = overlayAtBottom
        ? [
            theme.panelBackgroundColor.withOpacity(theme.panelGradientStartOpacity),
            theme.panelBackgroundColor.withOpacity(theme.panelGradientEndOpacity),
          ]
        : [
            theme.panelBackgroundColor.withOpacity(theme.panelGradientEndOpacity),
            theme.panelBackgroundColor.withOpacity(theme.panelGradientStartOpacity),
          ];
    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, overlayTop),
        Offset(0, overlayTop + overlayHeight),
        gradientColors,
      );
    canvas.drawRect(panelRect, gradientPaint);

    // Layer 3: border tipis dengan radius
    final borderPaint = Paint()
      ..color = theme.panelBorderColor.withOpacity(theme.panelBorderOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = theme.panelBorderWidth;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          theme.panelBorderWidth / 2,
          overlayTop + theme.panelBorderWidth / 2,
          photoWidth - theme.panelBorderWidth,
          overlayHeight - theme.panelBorderWidth,
        ),
        Radius.circular(theme.panelBorderRadius),
      ),
      borderPaint,
    );

    // Layer 4: highlight 1px di bagian atas (efek glass)
    if (theme.panelHighlightOpacity > 0) {
      final highlightPaint = Paint()
        ..color = theme.panelHighlightColor.withOpacity(theme.panelHighlightOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      final highlightRect = Rect.fromLTWH(
        theme.panelBorderWidth + 2,
        overlayTop + theme.panelBorderWidth + 2,
        photoWidth - (theme.panelBorderWidth + 2) * 2,
        1.0,
      );
      canvas.drawRect(highlightRect, highlightPaint);
    }

    // ============================================================
    //  LOGO (posisi di tengah vertikal panel)
    // ============================================================
    final logoMaxSize = metrics.logoMaxSize; // sudah diskalakan
    final accentBarW = theme.accentBarWidth;
    final accentBarSpace = accentBarW + padding * 0.5;
    final logoReserve = (logoImage != null) ? logoMaxSize + padding * 1.4 : 0.0;
    final textContentWidth = photoWidth - padding * 2 - logoReserve - accentBarSpace;

    final double textX = textAlign == TextAlign.left
        ? padding + accentBarSpace
        : photoWidth - padding - textContentWidth;
    double textY = overlayTop + padding * 0.95;

    // Accent bar (dengan opacity)
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
      Paint()..color = c.accent.withOpacity(theme.accentBarOpacity),
    );

    // ============================================================
    //  FUNGSI GAMBAR TEKS DENGAN HIERARKI
    // ============================================================
    void drawLabelValue(
      String label,
      String value,
      Color valueColor, {
      bool emphasize = false,
      double? customFontSize,
    }) {
      final valueFontSize = customFontSize ??
          (emphasize ? theme.barcodeFontSize : theme.bodyFontSize);
      final rowLineHeight = emphasize ? theme.barcodeLineHeight : metrics.lineHeight;

      // Label – gunakan spacing jika termasuk dalam daftar
      String displayLabel = label;
      if (theme.useSpacedLabels && theme.spacedLabelKeys.contains(label)) {
        displayLabel = _spaceOutLabel(label);
      }

      TextHelper.paintText(
        canvas: canvas,
        text: displayLabel,
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
      // Nilai
      TextHelper.paintText(
        canvas: canvas,
        text: value,
        x: textX,
        y: textY + valueFontSize * 0.78,
        maxWidth: textContentWidth,
        color: valueColor,
        fontSize: valueFontSize,
        fontWeight: emphasize ? FontWeight.w600 : FontWeight.w500, // lebih halus
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

    // ============================================================
    //  URUTAN INFORMASI
    // ============================================================
    // 1. Lokasi (judul)
    if (data.hasLocation) {
      drawTitleRow(data.locationName!);
    }

    // 2. Tanggal & Jam (ukuran besar)
    drawLabelValue(
      'TANGGAL',
      data.formattedDate,
      Colors.white.withOpacity(0.85),
      customFontSize: theme.barcodeFontSize,
    );
    drawLabelValue(
      'JAM',
      data.formattedTime,
      Colors.white.withOpacity(0.80),
      customFontSize: theme.barcodeFontSize,
    );

    // Spasi antar grup
    textY += theme.groupSpacing;

    // 3. Operator & Barcode
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
        emphasize: true, // ukuran lebih besar, weight SemiBold
      );
    }

    // Spasi ekstra sebelum koordinat (1.2x groupSpacing)
    if (data.hasCoordinates) {
      textY += theme.groupSpacing * 1.2;
    }

    // 4. Koordinat (footer)
    if (data.hasCoordinates) {
      drawCoordLine(data.latText);
      drawCoordLine(data.lonText);
    }

    // ============================================================
    //  GAMBAR LOGO (di tengah vertikal panel)
    // ============================================================
    if (logoImage != null) {
      final logoMaxH = logoMaxSize;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoMaxH / logoW, logoMaxH / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;

      // Posisi logo: di tengah vertikal panel (jika centerLogoVertically = true)
      double logoX = textAlign == TextAlign.left
          ? photoWidth - padding - drawW
          : padding;
      double logoY;
      if (theme.centerLogoVertically) {
        logoY = overlayTop + (overlayHeight - drawH) / 2;
      } else {
        logoY = overlayAtBottom
            ? photoHeight - padding - drawH
            : padding;
      }

      // Card background dengan opacity lebih rendah (0.18)
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
        Paint()..color = Colors.black.withOpacity(theme.logoCardOpacity),
      );

      LogoWidget.paint(
        canvas: canvas,
        logoImage: logoImage,
        x: logoX,
        y: logoY,
        maxWidth: drawW,
        maxHeight: drawH,
        opacity: theme.logoOpacity,
      );
    }
  }

  String _spaceOutLabel(String label) {
    return label.split('').join('\u200a ');
  }

  // ================================================================
  //  PREVIEW – IDENTIK DENGAN RENDERER (menggunakan CustomPaint)
  // ================================================================
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

    // Untuk preview, kita akan menggunakan CustomPaint yang memanggil paintOnCanvas
    // dengan srcImage berupa gambar dummy (atau bisa juga menggunakan gambar latar belakang).
    // Karena kita tidak punya ui.Image di sini, kita buat dummy dengan menggunakan
    // gambar placeholder (gradient) yang sama dengan yang digunakan di renderer.
    // Cara paling sederhana: gunakan CustomPaint dengan painter yang menggambar
    // background gradient dan kemudian memanggil paintOnCanvas dengan ui.Image kosong?
    // Lebih praktis: kita rebuild ulang tampilan dengan widget yang sama persis
    // dengan yang dihasilkan oleh paintOnCanvas, tapi kali ini menggunakan
    // CustomPaint dan kita beri gambar placeholder.

    // Karena paintOnCanvas membutuhkan ui.Image, kita tidak bisa langsung memanggilnya
    // di widget. Alternatif: kita buat preview dengan cara meniru hasil secara manual,
    // tapi agar identik, kita bisa menggunakan CustomPaint dengan painter yang
    // menggambar background gradient dan teks-teks dengan gaya yang sama.
    // Saya akan membuat preview yang menggunakan canvas dengan cara yang sama
    // seperti paintOnCanvas, namun tanpa gambar latar (hanya gradient placeholder).

    // Untuk konsistensi, saya akan buat PreviewPainter yang meniru paintOnCanvas
    // dengan background berupa gradient abu-abu (placeholder).
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
          child: Container(), // biar CustomPaint yang menggambar semua
        ),
      ),
    );
  }
}

// ================================================================
//  PREVIEW PAINTER – identik dengan paintOnCanvas
// ================================================================
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
    final c = theme.color;

    // ---- Background placeholder (gradient abu-abu) ----
    final bgPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, 0),
        Offset(photoWidth, photoHeight),
        [const Color(0xFF33373D), const Color(0xFF1B1E22)],
      );
    canvas.drawRect(Rect.fromLTWH(0, 0, photoWidth, photoHeight), bgPaint);

    // ---- Gambar ikon image di tengah ----
    final iconPaint = Paint()..color = Colors.white12;
    const iconSize = 28.0;
    canvas.drawCircle(
      Offset(photoWidth / 2, photoHeight / 2),
      iconSize / 2,
      iconPaint,
    );

    // ---- Panel Background (sama seperti di paintOnCanvas) ----
    final panelRect = Rect.fromLTWH(0, overlayTop, photoWidth, overlayHeight);
    // Layer 1: solid
    canvas.drawRect(
      panelRect,
      Paint()..color = theme.panelBackgroundColor.withOpacity(theme.panelBackgroundOpacity),
    );
    // Layer 2: gradient
    final gradientColors = isBottom
        ? [
            theme.panelBackgroundColor.withOpacity(theme.panelGradientStartOpacity),
            theme.panelBackgroundColor.withOpacity(theme.panelGradientEndOpacity),
          ]
        : [
            theme.panelBackgroundColor.withOpacity(theme.panelGradientEndOpacity),
            theme.panelBackgroundColor.withOpacity(theme.panelGradientStartOpacity),
          ];
    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, overlayTop),
        Offset(0, overlayTop + overlayHeight),
        gradientColors,
      );
    canvas.drawRect(panelRect, gradientPaint);
    // Layer 3: border
    final borderPaint = Paint()
      ..color = theme.panelBorderColor.withOpacity(theme.panelBorderOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = theme.panelBorderWidth;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          theme.panelBorderWidth / 2,
          overlayTop + theme.panelBorderWidth / 2,
          photoWidth - theme.panelBorderWidth,
          overlayHeight - theme.panelBorderWidth,
        ),
        Radius.circular(theme.panelBorderRadius),
      ),
      borderPaint,
    );
    // Layer 4: highlight
    if (theme.panelHighlightOpacity > 0) {
      final highlightPaint = Paint()
        ..color = theme.panelHighlightColor.withOpacity(theme.panelHighlightOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawRect(
        Rect.fromLTWH(
          theme.panelBorderWidth + 2,
          overlayTop + theme.panelBorderWidth + 2,
          photoWidth - (theme.panelBorderWidth + 2) * 2,
          1.0,
        ),
        highlightPaint,
      );
    }

    // ---- Accent bar ----
    final accentBarW = theme.accentBarWidth;
    final accentBarSpace = accentBarW + padding * 0.5;
    final logoMaxSize = metrics.logoMaxSize;
    final logoReserve = (hasLogo && logoPath != null) ? logoMaxSize + padding * 1.4 : 0.0;
    final textContentWidth = photoWidth - padding * 2 - logoReserve - accentBarSpace;
    final double textX = isLeftAligned
        ? padding + accentBarSpace
        : photoWidth - padding - textContentWidth;
    double textY = overlayTop + padding * 0.95;

    final barX = isLeftAligned ? padding : photoWidth - padding - accentBarW;
    final barcodeBonus = previewData.hasBarcode ? theme.barcodeRowBonus : 0.0;
    final titleBonus = previewData.hasLocation ? theme.titleRowBonus : 0.0;
    final textBlockHeight =
        metrics.textRowCount * metrics.lineHeight + barcodeBonus + titleBonus;
    canvas.drawRect(
      Rect.fromLTWH(
        barX,
        overlayTop + padding * 0.85,
        accentBarW,
        textBlockHeight,
      ),
      Paint()..color = c.accent.withOpacity(theme.accentBarOpacity),
    );

    // ---- Fungsi teks (sama) ----
    void drawLabelValue(String label, String value, Color valueColor,
        {bool emphasize = false, double? customFontSize}) {
      final valueFontSize = customFontSize ??
          (emphasize ? theme.barcodeFontSize : theme.bodyFontSize);
      final rowLineHeight = emphasize ? theme.barcodeLineHeight : metrics.lineHeight;
      String displayLabel = label;
      if (theme.useSpacedLabels && theme.spacedLabelKeys.contains(label)) {
        displayLabel = label.split('').join('\u200a ');
      }
      TextHelper.paintText(
        canvas: canvas,
        text: displayLabel,
        x: textX,
        y: textY,
        maxWidth: textContentWidth,
        color: Colors.white.withOpacity(0.45),
        fontSize: theme.captionFontSize,
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
        color: c.accent,
        fontSize: theme.titleFontSize,
        fontWeight: FontWeight.w800,
        maxLines: 1,
        textAlign: textAlign,
        fontFamily: previewData.fontFamily,
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
        fontFamily: previewData.fontFamily,
      );
      textY += metrics.lineHeight;
    }

    // ---- Informasi ----
    if (previewData.hasLocation) {
      drawTitleRow(previewData.locationName!);
    }
    drawLabelValue(
      'TANGGAL',
      previewData.formattedDate,
      Colors.white.withOpacity(0.85),
      customFontSize: theme.barcodeFontSize,
    );
    drawLabelValue(
      'JAM',
      previewData.formattedTime,
      Colors.white.withOpacity(0.80),
      customFontSize: theme.barcodeFontSize,
    );
    textY += theme.groupSpacing;
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
      textY += theme.groupSpacing * 1.2;
      drawCoordLine(previewData.latText);
      drawCoordLine(previewData.lonText);
    }

    // ---- Logo ----
    if (hasLogo && logoPath != null) {
      // Karena kita tidak punya ui.Image, kita hanya gambar placeholder
      // Untuk preview, kita bisa gambar kotak atau ikon.
      // Tapi lebih baik kita tampilkan logo dari file (jika ada) dengan cara
      // menggunakan ui.Image dari file, tapi di painter tidak bisa async.
      // Untuk preview, kita akan tampilkan ikon bisnis sebagai placeholder.
      final logoSize = metrics.logoMaxSize;
      final drawW = logoSize * 0.8;
      final drawH = logoSize * 0.8;
      double logoX = isLeftAligned ? photoWidth - padding - drawW : padding;
      double logoY;
      if (theme.centerLogoVertically) {
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
        Paint()..color = Colors.black.withOpacity(theme.logoCardOpacity),
      );
      // Gambar ikon bisnis
      final iconPaint2 = Paint()..color = Colors.white38;
      canvas.drawRect(
        Rect.fromLTWH(logoX, logoY, drawW, drawH),
        iconPaint2,
      );
      // Teks "LOGO" placeholder
      final textStyle = ui.TextStyle(
        color: Colors.white54,
        fontSize: 10,
        fontWeight: FontWeight.w500,
      );
      final paragraphBuilder = ui.ParagraphBuilder(textStyle)
        ..addText('LOGO');
      final paragraph = paragraphBuilder.build()
        ..layout(ui.ParagraphConstraints(width: drawW));
      canvas.drawParagraph(
        paragraph,
        Offset(logoX + (drawW - paragraph.width) / 2, logoY + (drawH - paragraph.height) / 2),
      );
    }

    // ---- Label nama layout di pojok kiri atas ----
    final labelPaint = Paint()..color = Colors.grey.withOpacity(0.85);
    final labelRect = Rect.fromLTWH(6, 6, 60, 16);
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, Radius.circular(4)),
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
      ..layout(ui.ParagraphConstraints(width: 60));
    canvas.drawParagraph(labelPara, Offset(8, 7));
  }

  @override
  bool shouldRepaint(covariant _ProfessionalPreviewPainter oldDelegate) => false;
}
