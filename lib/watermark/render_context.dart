// lib/watermark/render_context.dart
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/watermark_style.dart';

class RenderContext {
  final ui.Font? font;
  final ui.Image? logoImage;
  final TextStyle titleStyle;
  final TextStyle bodyStyle;
  final Paint shadowPaint;
  final Paint dividerPaint;
  final EdgeInsets padding;
  final double blockHeight;
  final double blockLineHeight;
  final Map<WatermarkStyle, _LayoutMetrics> metrics;

  RenderContext._({
    this.font,
    this.logoImage,
    required this.titleStyle,
    required this.bodyStyle,
    required this.shadowPaint,
    required this.dividerPaint,
    required this.padding,
    required this.blockHeight,
    required this.blockLineHeight,
    required this.metrics,
  });

  factory RenderContext.fromSettings(WatermarkSettings settings, {ui.Image? logo}) {
    // Inisialisasi font
    final fontLoader = FontLoader('customFont');
    // ... load font dari file

    // Buat TextStyles berdasarkan settings
    final titleStyle = TextStyle(
      fontFamily: 'customFont',
      fontSize: settings.fontSize + 6,
      color: Colors.orange,
      fontWeight: FontWeight.bold,
      shadows: const [Shadow(color: Colors.black87, offset: Offset(2, 2))],
    );
    final bodyStyle = TextStyle(
      fontFamily: 'customFont',
      fontSize: settings.fontSize,
      color: Colors.white,
      shadows: const [Shadow(color: Colors.black87, offset: Offset(1, 1))],
    );

    // Paint untuk shadow (jika diperlukan)
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.8)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    final dividerPaint = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..strokeWidth = 1;

    // Layout metrics per gaya
    final metrics = <WatermarkStyle, _LayoutMetrics>{};
    for (var style in WatermarkStyle.values) {
      if (style == WatermarkStyle.timestamp) {
        // Hitung khusus timestamp
      } else {
        final layout = _StyleLayout.forStyle(style, settings.position);
        final blockLineHeight = settings.fontSize + 8;
        final blockHeight = (4 * blockLineHeight) + (layout.padding * 2); // asumsi 4 baris
        metrics[style] = _LayoutMetrics(
          blockHeight: blockHeight,
          blockLineHeight: blockLineHeight,
          padding: layout.padding,
        );
      }
    }

    return RenderContext._(
      font: null, // nanti diisi setelah load
      logoImage: logo,
      titleStyle: titleStyle,
      bodyStyle: bodyStyle,
      shadowPaint: shadowPaint,
      dividerPaint: dividerPaint,
      padding: const EdgeInsets.all(14),
      blockHeight: 0,
      blockLineHeight: 0,
      metrics: metrics,
    );
  }
}

class _LayoutMetrics {
  final double blockHeight;
  final double blockLineHeight;
  final double padding;
  _LayoutMetrics({required this.blockHeight, required this.blockLineHeight, required this.padding});
}
