// ============================================================
// lib/watermark/theme/watermark_metrics.dart
// ============================================================
// Bagian dari WatermarkTheme. Sumber tunggal untuk radius sudut
// dan lebar garis/stroke yang dipakai semua layout.
// ============================================================

import 'dart:math' as math;

class WatermarkMetrics {
  const WatermarkMetrics._();

  /// Radius sudut kartu utama (kartu Polaroid, container preview, dll).
  static const double cardRadius = 14.0;

  /// Radius sudut elemen kecil (badge "MANUAL", kotak stempel).
  static double smallBadgeRadius(double height, {double ratio = 0.22}) =>
      height * ratio;

  /// Lebar garis tepi tipis (mis. bingkai foto Polaroid).
  static double hairlineStroke(double baseSize,
          {double ratio = 0.0012, double min = 1.0}) =>
      math.max(min, baseSize * ratio);

  /// Lebar accent bar vertikal (Professional/Stamp layout).
  static double accentBarWidth(double baseSize,
          {double ratio = 0.004, double min = 2.0}) =>
      math.max(min, baseSize * ratio);

  /// Lebar stroke badge/stempel yang lebih tebal.
  static double stampStroke(double baseSize,
          {double ratio = 0.005, double min = 2.5}) =>
      math.max(min, baseSize * ratio);
}
