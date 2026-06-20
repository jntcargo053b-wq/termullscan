import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'base_layout.dart';
import '../models/watermark_data.dart';
import '../models/watermark_style.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../widgets/logo_widget.dart';

class ProfessionalLayout implements WatermarkLayout {
  @override
  String get displayName => '🏢 Professional';

  @override
  WatermarkStyle get style => WatermarkStyle.professional;

  @override
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final rowHeight = baseSize * 0.052;
    int rowCount = 1; // timestamp
    if (data.hasBarcode) rowCount++;
    if (data.hasOperator) rowCount++;
    rowCount++; // location
    final stripHeight = rowCount * rowHeight + baseSize * 0.04;
    return WatermarkCanvasSize(photoWidth, photoHeight + stripHeight);
  }

  @override
  void paintOnCanvas({
    required Canvas canvas,
    required WatermarkCanvasSize canvasSize,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    final canvasWidth = canvasSize.width;
    final canvasHeight = canvasSize.height;
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final stripHeight = canvasHeight - photoHeight;
    final stripTop = photoHeight;
    final padding = LayoutHelper.padding(baseSize);

    // Foto
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    // Strip putih
    canvas.drawRect(
      Rect.fromLTWH(0, stripTop, canvasWidth, stripHeight),
      Paint()..color = Colors.white,
    );
    // Garis pemisah tebal
    canvas.drawLine(
      Offset(0, stripTop),
      Offset(canvasWidth, stripTop),
      Paint()
        ..color = const Color(0xFF1A2A3A)
        ..strokeWidth = math.max(2.0, baseSize * 0.003),
    );

    // Logo reserve (kanan)
    final logoReserve = logoImage != null ? baseSize * 0.20 : 0.0;

    // Tabel dua kolom
    _paintTwoColumnTable(
      canvas: canvas,
      data: data,
      x: padding,
      y: stripTop + padding * 0.6,
      maxWidth: canvasWidth - padding * 2 - logoReserve,
      baseSize: baseSize,
    );

    // Manual badge
    if (data.isManual) {
      _paintManualBadge(
        canvas: canvas,
        x: canvasWidth - padding - logoReserve - baseSize * 0.13,
        y: stripTop + padding * 0.6,
        baseSize: baseSize,
      );
    }

    // Logo
    if (logoImage != null) {
      final logoMaxH = stripHeight * 0.55;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = logoMaxH / logoH;
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      final logoX = canvasWidth - padding - drawW;
      final logoY = stripTop + (stripHeight - drawH) / 2;

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

  @override
  Widget buildPreview({
    required WatermarkData previewData,
    required bool hasLogo,
    required String? logoPath,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (previewData.hasOperator)
                    _PreviewRow(label: 'Operator', value: previewData.operatorName),
                  if (previewData.hasBarcode)
                    _PreviewRow(label: 'Barcode', value: previewData.barcodeValue!),
                  _PreviewRow(label: 'Tanggal', value: previewData.formattedTimestamp),
                  _PreviewRow(label: 'Lokasi', value: previewData.displayLocation),
                ],
              ),
            ),
            if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
              const Gap(8),
              Image.file(
                File(logoPath),
                width: 32,
                height: 32,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.business, color: Colors.white24),
              ),
            ],
          ],
        ),
        const Gap(6),
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
    );
  }

  // --- PRIVATE HELPERS ---

  void _paintTwoColumnTable({
    required Canvas canvas,
    required WatermarkData data,
    required double x,
    required double y,
    required double maxWidth,
    required double baseSize,
  }) {
    final fontSz = LayoutHelper.fontSize(baseSize, ratio: 0.026);
    final lineH = LayoutHelper.lineHeight(baseSize, ratio: 0.052);
    final col1Width = maxWidth * 0.30;
    final col2Width = maxWidth * 0.65;
    double currentY = y;

    void drawRow(String label, String value, {bool emphasize = false}) {
      // Label (rata kanan)
      TextHelper.paintText(
        canvas,
        text: label,
        x: x,
        y: currentY,
        maxWidth: col1Width,
        color: const Color(0xFF8A95A5),
        fontSize: fontSz * 0.9,
        fontWeight: FontWeight.w600,
        textAlign: TextAlign.right,
      );
      // Value (rata kiri)
      TextHelper.paintText(
        canvas,
        text: value,
        x: x + col1Width + 8,
        y: currentY,
        maxWidth: col2Width,
        color: const Color(0xFF1A2A3A),
        fontSize: fontSz,
        fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
      );
      currentY += lineH;
    }

    if (data.hasBarcode) {
      drawRow('Kode', data.barcodeValue!, emphasize: true);
    }
    if (data.hasOperator) {
      drawRow('Operator', data.operatorName);
    }
    drawRow('Tanggal', data.formattedTimestamp);
    drawRow('Lokasi', data.displayLocation);
  }

  void _paintManualBadge({
    required Canvas canvas,
    required double x,
    required double y,
    required double baseSize,
  }) {
    final badgeW = baseSize * 0.13;
    final badgeH = baseSize * 0.026;
    canvas.drawRect(
      Rect.fromLTWH(x, y, badgeW, badgeH),
      Paint()..color = const Color(0xFF1A2A3A),
    );
    final badgeTp = TextHelper.paintText(
      canvas,
      text: 'INPUT MANUAL',
      x: x + 4,
      y: y + 2,
      maxWidth: badgeW - 8,
      color: Colors.white,
      fontSize: badgeH * 0.45,
      fontWeight: FontWeight.w700,
    );
  }
}

// --- Preview row untuk professional ---
class _PreviewRow extends StatelessWidget {
  final String label;
  final String value;

  const _PreviewRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              '$label:',
              style: const TextStyle(
                color: Color(0xFF8A95A5),
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.right,
            ),
          ),
          const Gap(6),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Color(0xFF1A2A3A),
                fontSize: 9,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
