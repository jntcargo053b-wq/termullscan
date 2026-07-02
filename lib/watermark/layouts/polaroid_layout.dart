// ============================================================
// lib/watermark/layouts/polaroid_layout.dart (FINAL)
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
import '../widgets/logo_widget.dart';

class PolaroidLayout extends WatermarkLayout {
  @override
  String get displayName => '📷 Polaroid';

  @override
  WatermarkStyle get style => WatermarkStyle.polaroid;

  static const double _frameBorderRatio = 0.018;

  @override
  LayoutMetrics computeMetrics({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final padding = LayoutHelper.padding(baseSize);
    final rowCount = _countTextLines(data);

    final fontSz = data.fontSize;
    final lineH = fontSz * 1.7; // ✅ konsisten 1.7

    final bottomStripHeight = math.max(
      photoHeight * 0.20,
      rowCount * lineH + padding * 2.2,
    );

    final frameBorder = math.max(10.0, baseSize * _frameBorderRatio);

    final canvasW = photoWidth + padding * 2;
    final canvasH = photoHeight + padding + bottomStripHeight;

    final logoMaxH = bottomStripHeight * 0.55;
    final isManual = data.isManual;
    final rightReserved = (isManual ? baseSize * 0.11 : 0.0) +
        (bottomStripHeight * 0.55);
    final textW = canvasW - padding * 2 - 14 - rightReserved;

    return LayoutMetrics(
      baseSize: baseSize,
      padding: padding,
      fontSize: fontSz,
      lineHeight: lineH,
      stripHeight: bottomStripHeight,
      logoMaxSize: logoMaxH,
      textRowCount: rowCount,
      canvasWidth: canvasW,
      canvasHeight: canvasH,
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
    final canvasWidth = metrics.canvasWidth;
    final canvasHeight = metrics.canvasHeight;
    final padding = metrics.padding;
    final baseSize = metrics.baseSize;
    final stripHeight = metrics.stripHeight;
    final stripTop = photoHeight + padding;
    final frameBorder = math.max(10.0, baseSize * _frameBorderRatio);

    final paperRect = Rect.fromLTWH(0, 0, canvasWidth, canvasHeight);
    final paperShader = ui.Gradient.linear(
      paperRect.topLeft,
      paperRect.bottomRight,
      [const Color(0xFFFAFAF6), const Color(0xFFF0EFE9)],
    );
    // Radius kartu diperbesar dari 3 → 14 supaya terasa modern (kartu polaroid
    // lama terasa flat karena sudutnya nyaris kotak sempurna).
    const cardRadius = Radius.circular(14);
    final cardRRect = RRect.fromRectAndRadius(paperRect, cardRadius);
    final cardPath = Path()..addRRect(cardRRect);
    canvas.drawShadow(cardPath, Colors.black.withOpacity(0.20), 6, true);
    canvas.drawShadow(cardPath, Colors.black.withOpacity(0.28), 22, true);

    // Clip seluruh kanvas ke rounded-rect supaya foto & strip bawah ikut
    // mengikuti sudut membulat kartu, bukan hanya background paper-nya.
    canvas.save();
    canvas.clipRRect(cardRRect);
    canvas.drawRect(paperRect, Paint()..shader = paperShader);

    final outerPhotoRect = Rect.fromLTWH(
      padding - frameBorder,
      padding - frameBorder,
      photoWidth + frameBorder * 2,
      photoHeight + frameBorder * 2,
    );
    canvas.drawRect(outerPhotoRect, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawRect(
      outerPhotoRect,
      Paint()
        ..color = const Color(0xFFE2E0D8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, baseSize * 0.0012),
    );

    final photoRect = Rect.fromLTWH(padding, padding, photoWidth, photoHeight);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(photoRect, const Radius.circular(6)));
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      photoRect,
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    final vignette = ui.Gradient.radial(
      photoRect.center,
      photoRect.longestSide * 0.62,
      [
        Colors.transparent,
        Colors.black.withOpacity(0.16),
      ],
      [0.72, 1.0],
    );
    canvas.drawRect(photoRect, Paint()..shader = vignette);
    canvas.drawRect(
      photoRect,
      Paint()..color = const Color(0xFFE8A95B).withOpacity(0.05),
    );
    canvas.restore();

    canvas.drawLine(
      Offset(padding, stripTop),
      Offset(canvasWidth - padding, stripTop),
      Paint()
        ..color = const Color(0xFFE2E0D8)
        ..strokeWidth = 1.2,
    );

    final isManual = data.isManual;
    final hasLogo = logoImage != null;
    final rightReserved = (isManual ? baseSize * 0.11 : 0.0) +
        (hasLogo ? baseSize * 0.16 : 0.0);
    final tableX = padding + 8;
    final tableY = stripTop + (stripHeight * 0.10);
    final tableWidth = canvasWidth - padding * 2 - 16 - rightReserved;

    _paintInfoTable(
      canvas: canvas,
      data: data,
      x: tableX,
      y: tableY,
      maxWidth: tableWidth,
      baseSize: baseSize,
      fontSize: data.fontSize,
      lineHeight: metrics.lineHeight,
    );

    if (isManual) {
      _paintManualBadge(
        canvas: canvas,
        data: data,
        x: canvasWidth - padding - baseSize * 0.105 - 8,
        y: stripTop + (stripHeight * 0.12),
        baseSize: baseSize,
      );
    }

    if (hasLogo) {
      final logoMaxH = metrics.logoMaxSize;
      final logoW = logoImage!.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = logoMaxH / logoH;
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      final logoX = canvasWidth - padding - drawW - 8;
      final logoY = isManual
          ? stripTop + (stripHeight * 0.12) + (baseSize * 0.032) + 6
          : stripTop + (stripHeight - drawH) / 2;

      // ✅ cardPad diperbesar (logo di polaroid menggunakan opacity, tapi tetap tambahkan background)
      final cardPad = drawW * 0.20;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            logoX - cardPad,
            logoY.clamp(stripTop, stripTop + stripHeight - drawH) - cardPad,
            drawW + cardPad * 2,
            drawH + cardPad * 2,
          ),
          Radius.circular(cardPad * 0.8),
        ),
        Paint()..color = Colors.black.withOpacity(0.30),
      );

      LogoWidget.paint(
        canvas: canvas,
        logoImage: logoImage,
        x: logoX,
        y: logoY.clamp(stripTop, stripTop + stripHeight - drawH),
        maxWidth: drawW,
        maxHeight: drawH,
        opacity: 0.85,
      );
    }

    // Menutup save() dari clipRRect kartu di awal method.
    canvas.restore();
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

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFAFAF6), Color(0xFFF0EFE9)],
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xFFE2E0D8)),
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.0,
                    colors: [
                      const Color(0xFF3A3A38),
                      Colors.black.withOpacity(0.85),
                    ],
                  ),
                ),
                child: const Center(
                  child: Icon(Icons.image, color: Colors.white24, size: 28),
                ),
              ),
            ),
          ),
          const Gap(10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (previewData.hasBarcode) ...[
                      _PreviewRow(
                        label: 'Kode',
                        value: previewData.barcodeValue ?? '8991234567890',
                        valueColor: const Color(0xFF2C2C2C),
                        emphasize: true,
                        icon: Icons.qr_code,
                      ),
                      const Gap(4),
                    ],
                    if (previewData.hasOperator) ...[
                      _PreviewRow(
                        label: 'Operator',
                        value: previewData.operatorName,
                        valueColor: const Color(0xFF2C2C2C),
                        icon: Icons.person_outline,
                      ),
                      const Gap(4),
                    ],
                    _PreviewRow(
                      label: 'Waktu',
                      value: previewData.formattedTimestamp,
                      valueColor: const Color(0xFF555555),
                      icon: Icons.access_time,
                    ),
                    const Gap(4),
                    _PreviewRow(
                      label: 'Lokasi',
                      value: previewData.displayLocation,
                      valueColor: const Color(0xFF777777),
                      icon: Icons.location_on_outlined,
                    ),
                  ],
                ),
              ),
              if (previewData.isManual) ...[
                const Gap(6),
                Transform.rotate(
                  angle: -0.12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE67E22),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: Colors.white.withOpacity(0.6), width: 1),
                    ),
                    child: const Text(
                      'MANUAL',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ),
              ],
              if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
                const Gap(8),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Image.file(
                    File(logoPath),
                    width: metrics.logoMaxSize,
                    height: metrics.logoMaxSize,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image, color: Colors.black26),
                  ),
                ),
              ],
            ],
          ),
          const Gap(8),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
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
          ),
        ],
      ),
    );
  }

  int _countTextLines(WatermarkData data) {
    int lines = 0;
    if (data.hasBarcode) lines++;
    if (data.hasOperator) lines++;
    lines++; // waktu
    lines++; // lokasi
    return lines + 1;
  }

  void _paintInfoTable({
    required ui.Canvas canvas,
    required WatermarkData data,
    required double x,
    required double y,
    required double maxWidth,
    required double baseSize,
    required double fontSize,
    required double lineHeight,
  }) {
    double currentY = y;

    void drawRow(String label, String value, {bool emphasize = false}) {
      TextHelper.paintText(
        canvas: canvas,
        text: label.toUpperCase(),
        x: x,
        y: currentY,
        maxWidth: maxWidth * 0.26,
        color: const Color(0xFF8A8A82),
        fontSize: fontSize * 0.8,
        fontWeight: FontWeight.w700,
        fontFamily: data.fontFamily,
      );
      TextHelper.paintText(
        canvas: canvas,
        text: value,
        x: x + maxWidth * 0.26,
        y: currentY,
        maxWidth: maxWidth * 0.74,
        color: emphasize ? const Color(0xFF1F1F1F) : const Color(0xFF2C2C2C),
        fontSize: emphasize ? fontSize * 1.08 : fontSize,
        fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
        fontFamily: data.fontFamily,
      );
      currentY += lineHeight;
    }

    if (data.hasBarcode) {
      drawRow('Kode', data.barcodeValue!, emphasize: true);
    }
    if (data.hasOperator) {
      drawRow('Operator', data.operatorName);
    }
    drawRow('Waktu', data.formattedTimestamp);
    drawRow('Lokasi', data.displayLocation);
  }

  void _paintManualBadge({
    required ui.Canvas canvas,
    required WatermarkData data,
    required double x,
    required double y,
    required double baseSize,
  }) {
    final badgeW = baseSize * 0.105;
    final badgeH = baseSize * 0.032;

    canvas.save();
    canvas.translate(x + badgeW / 2, y + badgeH / 2);
    canvas.rotate(-0.07);
    canvas.translate(-badgeW / 2, -badgeH / 2);

    final rect = Rect.fromLTWH(0, 0, badgeW, badgeH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(badgeH * 0.22)),
      Paint()..color = const Color(0xFFE67E22),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(badgeH * 0.22)),
      Paint()
        ..color = Colors.white.withOpacity(0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, badgeH * 0.06),
    );
    TextHelper.paintText(
      canvas: canvas,
      text: 'MANUAL',
      x: 5,
      y: badgeH * 0.22,
      maxWidth: badgeW - 10,
      color: Colors.white,
      fontSize: badgeH * 0.46,
      fontWeight: FontWeight.w800,
      fontFamily: data.fontFamily,
    );
    canvas.restore();
  }
}

class _PreviewRow extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;
  final IconData icon;
  final bool emphasize;

  const _PreviewRow({
    required this.label,
    required this.value,
    required this.valueColor,
    required this.icon,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 10, color: valueColor.withOpacity(0.6)),
        const Gap(4),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF9A9A92),
            fontSize: 7,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        const Gap(4),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: emphasize ? 11 : 10,
              fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
