// ============================================================
// lib/watermark/theme/watermark_divider.dart
// ============================================================
// Bagian dari WatermarkTheme. Gaya garis pemisah (mis. antara
// foto & strip info) yang dipakai layout Polaroid & Professional.
// ============================================================

import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class WatermarkDividerStyle {
  final Color color;
  final double strokeWidth;
  final double opacity;

  const WatermarkDividerStyle({
    required this.color,
    this.strokeWidth = 1.2,
    this.opacity = 1.0,
  });

  void paint(ui.Canvas canvas, Offset p1, Offset p2) {
    canvas.drawLine(
      p1,
      p2,
      Paint()
        ..color = color.withOpacity(opacity)
        ..strokeWidth = strokeWidth,
    );
  }
}

class WatermarkDivider {
  const WatermarkDivider._();

  /// Divider tipis untuk latar terang (kartu Polaroid).
  static const light = WatermarkDividerStyle(
    color: Color(0xFFE2E0D8),
    strokeWidth: 1.2,
  );

  /// Divider tipis untuk latar gelap/overlay foto (Professional).
  static const onDark = WatermarkDividerStyle(
    color: Colors.white,
    strokeWidth: 1.0,
    opacity: 0.10,
  );
}
