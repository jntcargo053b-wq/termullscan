import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:gap/gap.dart';
import 'base_layout.dart';
import '../models/watermark_data.dart';
import '../models/watermark_style.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../widgets/logo_widget.dart';

class PolaroidLayout implements WatermarkLayout {
  @override
  String get displayName => '📷 Polaroid';

  @override
  WatermarkStyle get style => WatermarkStyle.polaroid;

  @override
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final padding = LayoutHelper.padding(baseSize);
    final rowCount = _countTextLines(data);
    final bottomStripHeight = math.max(
      photoHeight * 0.22,
      rowCount * LayoutHelper.lineHeight(baseSize) + padding * 2.5,
    );
    return WatermarkCanvasSize(
      photoWidth + padding * 2,
      photoHeight + padding + bottomStripHeight,
    );
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
    final padding = LayoutHelper.padding(baseSize);
    final bottomStripHeight = canvasHeight - photoHeight - padding;

    // --- Background kertas ---
    canvas.drawRect(
      Rect.fromLTWH(0, 0, canvasWidth, canvasHeight),
      Paint()..color = const Color(0xFFF5F5F0),
    );

    // --- Shadow ---
    final shadowPath = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, canvasWidth, canvasHeight),
        const Radius.circular(2),
      ));
    canvas.drawShadow(shadowPath, Colors.black.withOpacity(0.3), 14, true);

    // --- Area foto ---
    final photoRect = Rect.fromLTWH(padding, padding, photoWidth, photoHeight);
    canvas.drawRect(photoRect, Paint()..color = const Color(0xFF111111));
    canvas.drawRect(
      photoRect,
      Paint()
        ..color = const Color(0xFFDDDDDD)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, baseSize * 0.002),
    );
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      photoRect,
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    // --- Strip bawah ---
    final stripTop = photoHeight + padding;
    // Garis pemisah (opsional)
    canvas.drawLine(
      Offset(padding, stripTop),
      Offset(canvasWidth - padding, stripTop),
      Paint()
        ..color = const Color(0xFFDDDDDD)
        ..strokeWidth = 1,
    );

    // --- Tabel info ---
    final isManual = data.isManual;
    final hasLogo = logoImage != null;
    final rightReserved = (isManual ? baseSize * 0.10 : 0.0) +
        (hasLogo ? baseSize * 0.15 : 0.0);

    final tableX = padding + 6;
    final tableY = stripTop + (bottomStripHeight * 0.06);
    final tableWidth = canvasWidth - padding * 2 - 12 - rightReserved;

    _paintInfoTable(
      canvas: canvas,
      data: data,
      x: tableX,
      y: tableY,
      maxWidth: tableWidth,
      baseSize: baseSize,
    );

    // --- Manual badge ---
    if (isManual) {
      _paintManualBadge(
        canvas: canvas,
        x: canvasWidth - padding - baseSize * 0.09 - 6,
        y: stripTop + (bottomStripHeight * 0.10),
        baseSize: baseSize,
      );
    }

    // --- Logo ---
    if (hasLogo) {
      final logoMaxH = bottomStripHeight * 0.45;
      final logoW = logoImage!.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = logoMaxH / logoH;
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      final logoX = canvasWidth - padding - drawW - 6;
      final logoY = isManual
          ? stripTop + (bottomStripHeight * 0.10) + (baseSize * 0.028) + 4
          : stripTop + (bottomStripHeight - drawH) / 2;

      LogoWidget.paint(
        canvas: canvas,
        logoImage: logoImage,
        x: logoX,
        y: logoY.clamp(stripTop, stripTop + bottomStripHeight - drawH),
        maxWidth: drawW,
        maxHeight: drawH,
        opacity: 0.25,
        blendMode: BlendMode.modulate,
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
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PreviewLine(
                    text: previewData.operatorName,
                    color: const Color(0xFF8B6914),
                    icon: Icons.person,
                  ),
                  const Gap(3),
                  _PreviewLine(
                    text: previewData.barcodeValue ?? '8991234567890',
                    color: const Color(0xFF2C2C2C),
                    icon: Icons.qr_code,
                  ),
                  const Gap(3),
                  _PreviewLine(
                    text: previewData.formattedTimestamp,
                    color: const Color(0xFF666666),
                    icon: Icons.access_time,
                  ),
                  const Gap(3),
                  _PreviewLine(
                    text: previewData.displayLocation,
                    color: const Color(0xFF888888),
                    icon: Icons.location_on,
                  ),
                ],
              ),
            ),
            if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
              const Gap(8),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Image.file(
                  File(logoPath),
                  width: 40,
                  height: 40,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white24),
                ),
              ),
            ] else ...[
              const Gap(8),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Icon(Icons.business, color: Colors.white24, size: 20),
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

  int _countTextLines(WatermarkData data) {
    int lines = 0;
    if (data.hasBarcode) lines++;
    if (data.hasOperator) lines++;
    lines++; // waktu
    lines++; // lokasi
    return lines + 1; // +1 padding ekstra
  }

  void _paintInfoTable({
    required Canvas canvas,
    required WatermarkData data,
    required double x,
    required double y,
    required double maxWidth,
    required double baseSize,
  }) {
    final fontSz = LayoutHelper.fontSize(baseSize, ratio: 0.032);
    final lineH = LayoutHelper.lineHeight(baseSize, ratio: 0.048);
    double currentY = y;

    void drawRow(String label, String value, {bool emphasize = false}) {
      final labelTp = TextHelper.paintText(
        canvas,
        text: label.toUpperCase(),
        x: x,
        y: currentY,
        maxWidth: maxWidth * 0.25,
        color: const Color(0xFF666666),
        fontSize: fontSz * 0.85,
        fontWeight: FontWeight.w700,
      );
      TextHelper.paintText(
        canvas,
        text: value,
        x: x + maxWidth * 0.25,
        y: currentY,
        maxWidth: maxWidth * 0.75,
        color: const Color(0xFF2C2C2C),
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
    drawRow('Waktu', data.formattedTimestamp);
    drawRow('Lokasi', data.displayLocation);
  }

  void _paintManualBadge({
    required Canvas canvas,
    required double x,
    required double y,
    required double baseSize,
  }) {
    final badgeW = baseSize * 0.09;
    final badgeH = baseSize * 0.028;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, badgeW, badgeH),
        Radius.circular(badgeH * 0.2),
      ),
      Paint()..color = const Color(0xFFE67E22),
    );
    final badgeTp = TextHelper.paintText(
      canvas,
      text: 'MANUAL',
      x: x + 4,
      y: y + 2,
      maxWidth: badgeW - 8,
      color: Colors.white,
      fontSize: badgeH * 0.45,
      fontWeight: FontWeight.w800,
    );
  }
}

// --- Preview line widget ---
class _PreviewLine extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;

  const _PreviewLine({
    required this.text,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 10, color: color.withOpacity(0.7)),
        const Gap(4),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
