// lib/watermark/layouts/timestamp_layout.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/watermark_data.dart';
import '../watermark_style.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../theme/watermark_theme.dart';
import '../widgets/logo_widget.dart';
import 'base_layout.dart';
import 'layout_metrics.dart';

class TimestampLayout extends WatermarkLayout {
  @override
  String get displayName => '🕒 GPS Timestamp';

  @override
  WatermarkStyle get style => WatermarkStyle.timestamp;

  static const List<String> _hariIndo = [
    'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu',
  ];

  static String _dayName(DateTime dt) => _hariIndo[dt.weekday - 1];

  static String _generateCode(WatermarkData data) {
    final seed = '${data.timestamp.millisecondsSinceEpoch}'
        '${data.operatorName}${data.barcodeValue ?? ''}';
    final hash = seed.codeUnits.fold<int>(0, (p, c) => (p * 31 + c) & 0x7FFFFFFF);
    final code = hash.toRadixString(36).toUpperCase();
    return code.padLeft(10, 'X').substring(0, 10);
  }

  @override
  LayoutMetrics computeMetrics({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
    required WatermarkTheme theme,
  }) {
    final baseSize = theme.typography.baseSize;
    final padding = theme.typography.padding;

    final timeFontSize = baseSize * 0.11;
    final addressFontSize = baseSize * 0.030;
    final addressLineH = addressFontSize * 1.3;

    int metaLines = 0;
    if (data.hasBarcode) metaLines++;
    if (data.hasOperator) metaLines++;

    final metaLineH = baseSize * 0.032 * 1.3;
    final barHeight = (metaLines * metaLineH) +
        timeFontSize * 1.25 +
        addressLineH * 2 +
        padding * 1.6;

    return LayoutMetrics(
      baseSize: baseSize,
      padding: padding,
      fontSize: timeFontSize,
      lineHeight: addressLineH,
      stripHeight: barHeight,
      logoMaxSize: theme.logo.maxSize,
      textRowCount: metaLines + 3,
      canvasWidth: photoWidth,
      canvasHeight: photoHeight,
      textAvailableWidth: photoWidth - padding * 2,
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
    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    final baseSize = metrics.baseSize;
    final padding = metrics.padding;
    final barHeight = metrics.stripHeight;
    final barTop = photoHeight - barHeight;
    final bgOpacity = data.backgroundOpacity.clamp(0.4, 1.0);

    // ── Bar bawah solid ──
    canvas.drawRect(
      Rect.fromLTWH(0, barTop, photoWidth, barHeight),
      Paint()..color = Colors.black.withOpacity(bgOpacity),
    );

    double cursorY = barTop + padding * 0.7;

    // ── Baris meta kecil ──
    final metaFontSize = baseSize * 0.032;
    if (data.hasBarcode) {
      TextHelper.paintText(
        canvas: canvas,
        text: '📦 ${data.barcodeValue}',
        x: padding,
        y: cursorY,
        maxWidth: metrics.textAvailableWidth,
        color: Colors.white.withOpacity(0.9),
        fontSize: metaFontSize,
        fontWeight: FontWeight.w600,
        maxLines: 1,
        fontFamily: data.fontFamily,
      );
      cursorY += metaFontSize * 1.3;
    }
    if (data.hasOperator) {
      TextHelper.paintText(
        canvas: canvas,
        text: '👤 ${data.operatorName}',
        x: padding,
        y: cursorY,
        maxWidth: metrics.textAvailableWidth,
        color: Colors.white.withOpacity(0.85),
        fontSize: metaFontSize,
        fontWeight: FontWeight.w500,
        maxLines: 1,
        fontFamily: data.fontFamily,
      );
      cursorY += metaFontSize * 1.3;
    }

    // ── Jam besar + divider + tanggal/hari ──
    final timeFontSize = metrics.fontSize;
    final rowTop = cursorY;

    final timeTp = TextPainter(
      text: TextSpan(
        text: _hhmm(data.timestamp),
        style: TextStyle(
          color: Colors.white,
          fontSize: timeFontSize,
          fontWeight: FontWeight.w800,
          fontFamily: data.fontFamily,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    timeTp.paint(canvas, Offset(padding, rowTop));

    final dividerX = padding + timeTp.width + padding * 0.5;
    final dividerH = timeFontSize * 0.95;
    canvas.drawRect(
      Rect.fromLTWH(dividerX, rowTop + (timeTp.height - dividerH) / 2, baseSize * 0.006, dividerH),
      Paint()..color = theme.accent.color,
    );

    final dateColX = dividerX + baseSize * 0.02;
    final dateFontSize = baseSize * 0.034;
    final dayFontSize = baseSize * 0.028;
    final dateTp = TextPainter(
      text: TextSpan(
        text: _ddmmyyyy(data.timestamp),
        style: TextStyle(
          color: Colors.white,
          fontSize: dateFontSize,
          fontWeight: FontWeight.w600,
          fontFamily: data.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    dateTp.paint(canvas, Offset(dateColX, rowTop));

    final dayTp = TextPainter(
      text: TextSpan(
        text: _dayName(data.timestamp),
        style: TextStyle(
          color: Colors.white.withOpacity(0.75),
          fontSize: dayFontSize,
          fontWeight: FontWeight.w400,
          fontFamily: data.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    dayTp.paint(canvas, Offset(dateColX, rowTop + dateTp.height));

    cursorY = rowTop + timeTp.height + padding * 0.5;

    // ── Alamat / lokasi ──
    final addressFontSize = baseSize * 0.030;
    final logoReserve = (logoImage != null) ? metrics.logoMaxSize * 0.6 : 0.0;
    TextHelper.paintText(
      canvas: canvas,
      text: data.displayLocation,
      x: padding,
      y: cursorY,
      maxWidth: metrics.textAvailableWidth - logoReserve,
      color: Colors.white,
      fontSize: addressFontSize,
      fontWeight: FontWeight.w600,
      maxLines: 2,
      fontFamily: data.fontFamily,
    );

    if (data.isManual) {
      final manualTp = TextPainter(
        text: TextSpan(
          text: 'INPUT MANUAL',
          style: TextStyle(
            color: theme.accent.color,
            fontSize: metaFontSize * 0.95,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            fontFamily: data.fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      manualTp.paint(canvas, Offset(photoWidth - padding - manualTp.width, barTop + padding * 0.4));
    }

    // ── Logo ──
    if (logoImage != null) {
      final logoSize = metrics.logoMaxSize * 0.6;
      final logoW = logoImage.width.toDouble();
      final logoH = logoImage.height.toDouble();
      final scale = math.min(logoSize / logoW, logoSize / logoH);
      final drawW = logoW * scale;
      final drawH = logoH * scale;
      LogoWidget.paint(
        canvas: canvas,
        logoImage: logoImage,
        x: photoWidth - padding - drawW,
        y: photoHeight - padding - drawH,
        maxWidth: drawW,
        maxHeight: drawH,
        opacity: 0.95,
      );
    }

    // ── Badge brand pojok kanan atas ──
    final brandText = data.hasCompany ? data.companyName : 'TermulScan';
    final brandFontSize = baseSize * 0.042;
    final taglineFontSize = baseSize * 0.024;
    final shadow = TextHelper.softShadow(opacity: 0.6, blur: 4);

    final brandTp = TextPainter(
      text: TextSpan(
        text: brandText,
        style: TextStyle(
          color: theme.accent.color,
          fontSize: brandFontSize,
          fontWeight: FontWeight.w800,
          fontFamily: data.fontFamily,
          shadows: shadow,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    )..layout(maxWidth: photoWidth - padding * 2);
    brandTp.paint(canvas, Offset(photoWidth - padding - brandTp.width, padding * 0.7));

    final taglineTp = TextPainter(
      text: TextSpan(
        text: 'Foto Terverifikasi GPS',
        style: TextStyle(
          color: Colors.white.withOpacity(0.9),
          fontSize: taglineFontSize,
          fontWeight: FontWeight.w400,
          fontFamily: data.fontFamily,
          shadows: shadow,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    )..layout(maxWidth: photoWidth - padding * 2);
    taglineTp.paint(canvas, Offset(photoWidth - padding - taglineTp.width, padding * 0.7 + brandTp.height + 2));

    // ── Kode verifikasi vertikal ──
    final code = _generateCode(data);
    final vertTp = TextPainter(
      text: TextSpan(
        text: '$code   •   TERMULSCAN VERIFIED',
        style: TextStyle(
          color: Colors.white.withOpacity(0.85),
          fontSize: baseSize * 0.020,
          fontWeight: FontWeight.w500,
          letterSpacing: 1.0,
          fontFamily: data.fontFamily,
          shadows: shadow,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    canvas.save();
    final vertX = photoWidth - padding * 0.55;
    final vertYBottom = barTop - padding * 0.6;
    canvas.translate(vertX, vertYBottom);
    canvas.rotate(-math.pi / 2);
    vertTp.paint(canvas, Offset(0, -vertTp.height / 2));
    canvas.restore();
  }

  static String _hhmm(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  static String _ddmmyyyy(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

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
            // Badge brand
            Positioned(
              top: 8, right: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    previewData.hasCompany ? previewData.companyName : 'TermulScan',
                    style: TextStyle(color: theme.accent.color, fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                  const Text(
                    'Foto Terverifikasi GPS',
                    style: TextStyle(color: Colors.white70, fontSize: 7),
                  ),
                ],
              ),
            ),
            // Kode vertikal
            Positioned(
              right: 3,
              top: previewHeight * 0.35,
              bottom: previewHeight * 0.32,
              child: RotatedBox(
                quarterTurns: 3,
                child: Center(
                  child: Text(
                    '${_generateCode(previewData)} • VERIFIED',
                    style: const TextStyle(color: Colors.white54, fontSize: 6, letterSpacing: 0.5),
                  ),
                ),
              ),
            ),
            // Bar bawah
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(previewData.backgroundOpacity.clamp(0.4, 1.0)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (previewData.hasBarcode)
                      Text('📦 ${previewData.barcodeValue}', style: const TextStyle(color: Colors.white70, fontSize: 8)),
                    if (previewData.hasOperator)
                      Text('👤 ${previewData.operatorName}', style: const TextStyle(color: Colors.white70, fontSize: 8)),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _hhmm(previewData.timestamp),
                          style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, height: 1.0),
                        ),
                        const SizedBox(width: 6),
                        Container(width: 2, height: 24, color: theme.accent.color),
                        const SizedBox(width: 6),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_ddmmyyyy(previewData.timestamp), style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
                            Text(_dayName(previewData.timestamp), style: const TextStyle(color: Colors.white70, fontSize: 8)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            previewData.displayLocation,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Image.file(
                            File(logoPath),
                            width: 16,
                            height: 16,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.business, color: Colors.white38, size: 14),
                          ),
                        ],
                      ],
                    ),
                  ],
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
}
