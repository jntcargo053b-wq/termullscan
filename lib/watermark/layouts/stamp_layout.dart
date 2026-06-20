import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'base_layout.dart';
import '../models/watermark_data.dart';
import '../models/watermark_style.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../widgets/logo_widget.dart';

class StampLayout implements WatermarkLayout {
  @override
  String get displayName => '✔ Verified Stamp';

  @override
  WatermarkStyle get style => WatermarkStyle.stamp;

  @override
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    return WatermarkCanvasSize(photoWidth, photoHeight);
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
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final padding = LayoutHelper.padding(baseSize);

    // Foto full
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    // --- STAMP (pojok kanan bawah) ---
    final stampColor = data.isManual
        ? const Color(0xFFE67E22)
        : const Color(0xFF2E8B57);
    final stampLabel = data.isManual ? 'MANUAL' : 'VERIFIED';

    final stampW = baseSize * 0.30;
    final stampH = baseSize * 0.14;
    final stampCenterX = photoWidth - padding - stampW / 2;
    final stampCenterY = photoHeight - padding - stampH / 2;

    canvas.save();
    canvas.translate(stampCenterX, stampCenterY);
    canvas.rotate(-0.08);

    final stampRect = Rect.fromCenter(
      center: Offset.zero,
      width: stampW,
      height: stampH,
    );
    final strokeWidth = math.max(2.0, baseSize * 0.0045);

    // Background
    canvas.drawRRect(
      RRect.fromRectAndRadius(stampRect, Radius.circular(stampH * 0.12)),
      Paint()
        ..color = stampColor.withOpacity(0.10)
        ..style = PaintingStyle.fill,
    );
    // Border
    canvas.drawRRect(
      RRect.fromRectAndRadius(stampRect, Radius.circular(stampH * 0.12)),
      Paint()
        ..color = stampColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    // Label utama
    final labelTp = TextHelper.paintText(
      canvas,
      text: stampLabel,
      x: -stampW / 2 + 8,
      y: -stampH * 0.35,
      maxWidth: stampW - 16,
      color: stampColor,
      fontSize: stampH * 0.28,
      fontWeight: FontWeight.w900,
      textAlign: TextAlign.center,
    );

    // Operator (jika ada)
    double currentY = stampH * 0.02;
    if (data.hasOperator) {
      final opTp = TextHelper.paintText(
        canvas,
        text: data.operatorName,
        x: -stampW / 2 + 8,
        y: currentY,
        maxWidth: stampW - 16,
        color: stampColor,
        fontSize: stampH * 0.16,
        fontWeight: FontWeight.w600,
        textAlign: TextAlign.center,
      );
      currentY += stampH * 0.20;
    }

    // Timestamp
    final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(data.timestamp);
    TextHelper.paintText(
      canvas,
      text: dateStr,
      x: -stampW / 2 + 8,
      y: currentY,
      maxWidth: stampW - 16,
      color: stampColor,
      fontSize: stampH * 0.14,
      fontWeight: FontWeight.w600,
      textAlign: TextAlign.center,
    );

    canvas.restore();

    // --- INFO PANEL (pojok kiri bawah) ---
    final infoLines = <String>[];
    if (data.hasBarcode) infoLines.add(data.barcodeValue!);
    if (data.hasOperator) infoLines.add('OP: ${data.operatorName}');
    infoLines.add(data.displayLocation);

    final fontSize = baseSize * 0.024;
    final lineHeight = fontSize * 1.5;
    final panelHeight = infoLines.length * lineHeight + padding;
    final panelWidth = baseSize * 0.46;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          padding * 0.6,
          photoHeight - padding * 0.6 - panelHeight,
          panelWidth,
          panelHeight,
        ),
        Radius.circular(baseSize * 0.012),
      ),
      Paint()..color = Colors.black.withOpacity(0.45),
    );

    double textY = photoHeight - padding * 0.6 - panelHeight + padding * 0.4;
    final textX = padding * 0.6 + padding * 0.4;
    for (final line in infoLines) {
      TextHelper.paintText(
        canvas,
        text: line,
        x: textX,
        y: textY,
        maxWidth: panelWidth - padding * 0.8,
        color: Colors.white,
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        maxLines: 1,
      );
      textY += lineHeight;
    }

    // Logo (pojok kiri atas)
    if (logoImage != null) {
      final logoSize = baseSize * 0.12;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoSize / logoW, logoSize / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;

      LogoWidget.paint(
        canvas: canvas,
        logoImage: logoImage,
        x: padding,
        y: padding,
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
    final stampColor = previewData.isManual
        ? const Color(0xFFE67E22)
        : const Color(0xFF2E8B57);
    final stampLabel = previewData.isManual ? 'MANUAL' : 'VERIFIED';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: stampColor, width: 1.5),
                borderRadius: BorderRadius.circular(4),
                color: stampColor.withOpacity(0.1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    stampLabel,
                    style: TextStyle(
                      color: stampColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                  const Gap(2),
                  if (previewData.hasOperator)
                    Text(
                      previewData.operatorName,
                      style: TextStyle(
                        color: stampColor,
                        fontSize: 8,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(
                    previewData.formattedTimestamp,
                    style: TextStyle(
                      color: stampColor,
                      fontSize: 8,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
              const Gap(8),
              Image.file(
                File(logoPath),
                width: 28,
                height: 28,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.business, color: Colors.white24),
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
    );
  }
}
