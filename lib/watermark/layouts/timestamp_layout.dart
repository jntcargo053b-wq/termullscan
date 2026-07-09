// lib/watermark/layouts/timestamp_layout.dart
// ============================================================
// LAYOUT GPS TIMESTAMP – REFACTORED & FINAL
// ============================================================
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/watermark_data.dart';
import '../watermark_style.dart';
import '../watermark_settings.dart';
import '../helpers/layout_helper.dart';
import '../helpers/text_helper.dart';
import '../helpers/watermark_typography.dart';
import '../widgets/logo_widget.dart';
import 'base_layout.dart';
import 'layout_metrics.dart';

class TimestampLayout extends WatermarkLayout {
  @override
  String get displayName => '🕒 GPS Timestamp';

  @override
  WatermarkStyle get style => WatermarkStyle.timestamp;

  // ─── KONSTANTA ──────────────────────────────────────────────────
  static const Color _accentColor = Color(0xFF4FA8E8);

  // Skala font
  static const double _timeScale = 0.11;
  static const double _metaScale = 0.032;
  static const double _dateScale = 0.034;
  static const double _dayScale = 0.028;
  static const double _addressScale = 0.030;
  static const double _brandScale = 0.042;
  static const double _taglineScale = 0.024;
  static const double _codeScale = 0.020;
  static const double _manualScale = 0.95;
  static const double _logoScale = 0.6;
  static const double _dividerScale = 0.006;

  // Spacing / padding factors
  static const double _timeRowPadding = 1.25;
  static const double _addressLineSpacing = 1.3;
  static const double _metaLineSpacing = 1.3;
  static const double _barVerticalPadding = 1.6;
  static const double _topPaddingFactor = 0.7;
  static const double _dividerSpacing = 0.5;
  static const double _dateSpacing = 0.02;
  static const double _logoReserveScale = 0.6;
  static const double _codeVerticalOffset = 0.55;

  // Opacity
  static const double _opacityMeta = 0.9;
  static const double _opacityOperator = 0.85;
  static const double _opacityDay = 0.75;
  static const double _opacityBrand = 0.9;
  static const double _opacityCode = 0.85;
  static const double _opacityLogo = 0.95;
  static const double _shadowOpacity = 0.6;

  // ─── HARI INDONESIA ────────────────────────────────────────────
  static const List<String> _hariIndo = [
    'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu',
  ];

  static String _dayName(DateTime dt) => _hariIndo[dt.weekday - 1];

  // ─── GENERATE VERIFICATION CODE ──────────────────────────────
  static String _generateVerificationCode(WatermarkData data) {
    final seed = '${data.timestamp.millisecondsSinceEpoch}'
        '${data.operatorName}${data.barcodeValue ?? ''}';
    final hash = seed.codeUnits.fold<int>(0, (p, c) => (p * 31 + c) & 0x7FFFFFFF);
    final code = hash.toRadixString(36).toUpperCase();
    return code.padLeft(10, 'X').substring(0, 10);
  }

  // ─── COMPUTE METRICS ───────────────────────────────────────────
  @override
  LayoutMetrics computeMetrics({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final baseSize = LayoutHelper.getBaseSize(photoWidth, photoHeight);
    final padding = LayoutHelper.padding(baseSize);

    final metaFontSize = baseSize * _metaScale;
    final metaLineH = metaFontSize * _metaLineSpacing;
    final timeFontSize = baseSize * _timeScale;
    final addressFontSize = baseSize * _addressScale;
    final addressLineH = addressFontSize * _addressLineSpacing;

    int metaLines = 0;
    if (data.hasBarcode) metaLines++;
    if (data.hasOperator) metaLines++;

    final barHeight = (metaLines * metaLineH) +
        timeFontSize * _timeRowPadding +
        addressLineH * 2 +
        padding * _barVerticalPadding;

    final logoMaxSize = WatermarkTypography.logo(baseSize);

    return LayoutMetrics(
      baseSize: baseSize,
      padding: padding,
      fontSize: timeFontSize,
      lineHeight: addressLineH,
      stripHeight: barHeight,
      logoMaxSize: logoMaxSize,
      textRowCount: metaLines + 3,
      canvasWidth: photoWidth,
      canvasHeight: photoHeight,
      textAvailableWidth: photoWidth - padding * 2,
    );
  }

  // ─── PAINT ON CANVAS ──────────────────────────────────────────
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
      ui.Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      ui.Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      ui.Paint()
        ..filterQuality = ui.FilterQuality.high
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

  // ─── PAINT WATERMARK ONLY ────────────────────────────────────
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
    final baseSize = metrics.baseSize;
    final padding = metrics.padding;
    final barHeight = metrics.stripHeight;
    final barTop = photoHeight - barHeight;
    final bgOpacity = data.backgroundOpacity.clamp(0.4, 1.0);

    // ─── BAR BAWAH ──────────────────────────────────────────────
    canvas.drawRect(
      ui.Rect.fromLTWH(0, barTop, photoWidth, barHeight),
      ui.Paint()..color = Colors.black.withOpacity(bgOpacity),
    );

    double cursorY = barTop + padding * _topPaddingFactor;

    // ─── META ────────────────────────────────────────────────────
    cursorY = _drawMeta(canvas, data, metrics, padding, cursorY);

    // ─── TIME ────────────────────────────────────────────────────
    cursorY = _drawTime(canvas, data, metrics, padding, baseSize, cursorY);

    // ─── LOCATION ───────────────────────────────────────────────
    _drawLocation(canvas, data, metrics, padding, baseSize, cursorY, logoImage);

    // ─── MANUAL BADGE ───────────────────────────────────────────
    _drawManualBadge(canvas, data, padding, baseSize, barTop, photoWidth);

    // ─── LOGO ────────────────────────────────────────────────────
    _drawLogo(canvas, logoImage, metrics, padding, photoWidth, photoHeight);

    // ─── BRAND ──────────────────────────────────────────────────
    _drawBrand(canvas, data, padding, photoWidth, baseSize);

    // ─── VERIFICATION CODE ─────────────────────────────────────
    _drawVerification(canvas, data, padding, baseSize, photoWidth, barTop);
  }

  // ─── HELPERS ──────────────────────────────────────────────────

  double _drawMeta(
    ui.Canvas canvas,
    WatermarkData data,
    LayoutMetrics metrics,
    double padding,
    double cursorY,
  ) {
    final metaFontSize = metrics.baseSize * _metaScale;
    final metaLineH = metaFontSize * _metaLineSpacing;

    if (data.hasBarcode) {
      TextHelper.paintText(
        canvas: canvas,
        text: '📦 ${data.barcodeValue}',
        x: padding,
        y: cursorY,
        maxWidth: metrics.textAvailableWidth,
        color: Colors.white.withOpacity(_opacityMeta),
        fontSize: metaFontSize,
        fontWeight: FontWeight.w600,
        maxLines: 1,
        fontFamily: data.fontFamily,
      );
      cursorY += metaLineH;
    }
    if (data.hasOperator) {
      TextHelper.paintText(
        canvas: canvas,
        text: '👤 ${data.operatorName}',
        x: padding,
        y: cursorY,
        maxWidth: metrics.textAvailableWidth,
        color: Colors.white.withOpacity(_opacityOperator),
        fontSize: metaFontSize,
        fontWeight: FontWeight.w500,
        maxLines: 1,
        fontFamily: data.fontFamily,
      );
      cursorY += metaLineH;
    }
    return cursorY;
  }

  double _drawTime(
    ui.Canvas canvas,
    WatermarkData data,
    LayoutMetrics metrics,
    double padding,
    double baseSize,
    double cursorY,
  ) {
    final timeFontSize = metrics.fontSize;
    final rowTop = cursorY;

    // Jam
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
    timeTp.paint(canvas, ui.Offset(padding, rowTop));

    // Divider
    final dividerX = padding + timeTp.width + padding * _dividerSpacing;
    final dividerH = timeFontSize * 0.95;
    canvas.drawRect(
      ui.Rect.fromLTWH(dividerX, rowTop + (timeTp.height - dividerH) / 2, baseSize * _dividerScale, dividerH),
      ui.Paint()..color = _accentColor,
    );

    // Tanggal & Hari
    final dateColX = dividerX + baseSize * _dateSpacing;
    final dateFontSize = baseSize * _dateScale;
    final dayFontSize = baseSize * _dayScale;

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
    dateTp.paint(canvas, ui.Offset(dateColX, rowTop));

    final dayTp = TextPainter(
      text: TextSpan(
        text: _dayName(data.timestamp),
        style: TextStyle(
          color: Colors.white.withOpacity(_opacityDay),
          fontSize: dayFontSize,
          fontWeight: FontWeight.w400,
          fontFamily: data.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    dayTp.paint(canvas, ui.Offset(dateColX, rowTop + dateTp.height));

    return rowTop + timeTp.height + padding * _topPaddingFactor;
  }

  void _drawLocation(
    ui.Canvas canvas,
    WatermarkData data,
    LayoutMetrics metrics,
    double padding,
    double baseSize,
    double cursorY,
    ui.Image? logoImage,
  ) {
    final addressFontSize = baseSize * _addressScale;
    final logoReserve = (logoImage != null) ? metrics.logoMaxSize * _logoReserveScale : 0.0;

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
  }

  void _drawManualBadge(
    ui.Canvas canvas,
    WatermarkData data,
    double padding,
    double baseSize,
    double barTop,
    double photoWidth,
  ) {
    if (!data.isManual) return;

    final metaFontSize = baseSize * _metaScale;
    final manualTp = TextPainter(
      text: TextSpan(
        text: 'INPUT MANUAL',
        style: TextStyle(
          color: const Color(0xFFFFB74D),
          fontSize: metaFontSize * _manualScale,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          fontFamily: data.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    manualTp.paint(
      canvas,
      ui.Offset(photoWidth - padding - manualTp.width, barTop + padding * _topPaddingFactor),
    );
  }

  void _drawLogo(
    ui.Canvas canvas,
    ui.Image? logoImage,
    LayoutMetrics metrics,
    double padding,
    double photoWidth,
    double photoHeight,
  ) {
    if (logoImage == null) return;

    final logoSize = metrics.logoMaxSize * _logoScale;
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
      opacity: _opacityLogo,
    );
  }

  void _drawBrand(
    ui.Canvas canvas,
    WatermarkData data,
    double padding,
    double photoWidth,
    double baseSize,
  ) {
    final brandText = data.companyName.isNotEmpty ? data.companyName : 'TermulScan';
    final brandFontSize = baseSize * _brandScale;
    final taglineFontSize = baseSize * _taglineScale;
    final shadow = TextHelper.softShadow(opacity: _shadowOpacity, blur: 4);

    final brandTp = TextPainter(
      text: TextSpan(
        text: brandText,
        style: TextStyle(
          color: _accentColor,
          fontSize: brandFontSize,
          fontWeight: FontWeight.w800,
          fontFamily: data.fontFamily,
          shadows: shadow,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    )..layout(maxWidth: photoWidth - padding * 2);
    brandTp.paint(canvas, ui.Offset(photoWidth - padding - brandTp.width, padding * _topPaddingFactor));

    final taglineTp = TextPainter(
      text: TextSpan(
        text: 'Foto Terverifikasi GPS',
        style: TextStyle(
          color: Colors.white.withOpacity(_opacityBrand),
          fontSize: taglineFontSize,
          fontWeight: FontWeight.w400,
          fontFamily: data.fontFamily,
          shadows: shadow,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    )..layout(maxWidth: photoWidth - padding * 2);
    taglineTp.paint(
      canvas,
      ui.Offset(
        photoWidth - padding - taglineTp.width,
        padding * _topPaddingFactor + brandTp.height + 2,
      ),
    );
  }

  void _drawVerification(
    ui.Canvas canvas,
    WatermarkData data,
    double padding,
    double baseSize,
    double photoWidth,
    double barTop,
  ) {
    final code = _generateVerificationCode(data);
    final shadow = TextHelper.softShadow(opacity: _shadowOpacity, blur: 4);

    final vertTp = TextPainter(
      text: TextSpan(
        text: '$code   •   TERMULSCAN VERIFIED',
        style: TextStyle(
          color: Colors.white.withOpacity(_opacityCode),
          fontSize: baseSize * _codeScale,
          fontWeight: FontWeight.w500,
          letterSpacing: 1.0,
          fontFamily: data.fontFamily,
          shadows: shadow,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    canvas.save();
    final vertX = photoWidth - padding * _codeVerticalOffset;
    final vertYBottom = barTop - padding * _topPaddingFactor;
    canvas.translate(vertX, vertYBottom);
    canvas.rotate(-math.pi / 2);
    vertTp.paint(canvas, ui.Offset(0, -vertTp.height / 2));
    canvas.restore();
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
    // Gunakan computeMetrics() agar ukuran konsisten dengan export
    final metrics = computeMetrics(
      photoWidth: previewWidth,
      photoHeight: previewHeight,
      data: previewData,
    );
    final baseSize = metrics.baseSize;
    final barHeight = metrics.stripHeight;
    final padding = metrics.padding;

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: previewWidth / previewHeight,
        child: Stack(
          children: [
            // Background
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
            // Brand badge
            Positioned(
              top: 8,
              right: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    previewData.companyName.isNotEmpty
                        ? previewData.companyName
                        : 'TermulScan',
                    style: TextStyle(
                      color: _accentColor,
                      fontSize: baseSize * _brandScale,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    'Foto Terverifikasi GPS',
                    style: TextStyle(
                      color: Colors.white.withOpacity(_opacityBrand),
                      fontSize: baseSize * _taglineScale,
                    ),
                  ),
                ],
              ),
            ),
            // Verification code (vertical)
            Positioned(
              right: 3,
              top: previewHeight * 0.35,
              bottom: previewHeight * 0.32,
              child: RotatedBox(
                quarterTurns: 3,
                child: Center(
                  child: Text(
                    '${_generateVerificationCode(previewData)} • VERIFIED',
                    style: TextStyle(
                      color: Colors.white.withOpacity(_opacityCode),
                      fontSize: baseSize * _codeScale,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
            // Bottom bar
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: barHeight,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: padding,
                  vertical: padding * _topPaddingFactor,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(
                    previewData.backgroundOpacity.clamp(0.4, 1.0),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (previewData.hasBarcode)
                      Text(
                        '📦 ${previewData.barcodeValue}',
                        style: TextStyle(
                          color: Colors.white.withOpacity(_opacityMeta),
                          fontSize: baseSize * _metaScale,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (previewData.hasOperator)
                      Text(
                        '👤 ${previewData.operatorName}',
                        style: TextStyle(
                          color: Colors.white.withOpacity(_opacityOperator),
                          fontSize: baseSize * _metaScale,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _hhmm(previewData.timestamp),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: baseSize * _timeScale,
                            fontWeight: FontWeight.w800,
                            height: 1.0,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: baseSize * _dividerScale,
                          height: baseSize * _timeScale * 0.95,
                          color: _accentColor,
                        ),
                        const SizedBox(width: 6),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _ddmmyyyy(previewData.timestamp),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: baseSize * _dateScale,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              _dayName(previewData.timestamp),
                              style: TextStyle(
                                color: Colors.white.withOpacity(_opacityDay),
                                fontSize: baseSize * _dayScale,
                              ),
                            ),
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
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: baseSize * _addressScale,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (hasLogo && logoPath != null && logoPath.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          // Logo preview dengan aspect ratio terjaga
                          ClipRect(
                            child: Image.file(
                              File(logoPath),
                              width: metrics.logoMaxSize * _logoScale,
                              height: metrics.logoMaxSize * _logoScale,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.business, color: Colors.white38, size: 14),
                            ),
                          ),
                        ],
                      ],
                    ),
                    // Badge "INPUT MANUAL" (dalam Column, pakai Align)
                    if (previewData.isManual)
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'INPUT MANUAL',
                            style: TextStyle(
                              color: const Color(0xFFFFB74D),
                              fontSize: baseSize * _metaScale * _manualScale,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Label layout
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

  // ─── HELPERS ──────────────────────────────────────────────────
  static String _hhmm(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  static String _ddmmyyyy(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
}
