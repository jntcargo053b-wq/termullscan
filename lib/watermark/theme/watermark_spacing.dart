// ============================================================
// lib/watermark/theme/watermark_spacing.dart
// ============================================================
// Bagian dari WatermarkTheme. Sumber tunggal untuk padding &
// gap yang dipakai semua layout.
// ============================================================

class WatermarkSpacing {
  const WatermarkSpacing._();

  /// Padding utama, relatif terhadap baseSize foto (min(width, height)).
  static double basePadding(double baseSize, {double ratio = 0.04}) =>
      baseSize * ratio;

  /// Jarak kecil antar elemen dalam satu baris (icon–teks, teks–logo, dst).
  static const double inlineGap = 8.0;

  /// Jarak antar baris di preview widget (bukan Canvas export).
  static const double previewRowGap = 4.0;
}
