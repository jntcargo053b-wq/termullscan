// ============================================================
// lib/watermark/theme/watermark_typography.dart
// ============================================================
// Bagian dari WatermarkTheme. Sumber tunggal rasio ukuran teks
// (judul, isi, caption, barcode) untuk SEMUA watermark layout.
// ============================================================

class WatermarkTypography {
  const WatermarkTypography._();

  /// Judul/heading (mis. label stempel besar di Stamp layout).
  static double title(double fontSize) => fontSize * 1.29;

  /// Teks isi/body utama (value pada baris info).
  static double body(double fontSize) => fontSize;

  /// Caption/label kecil (mis. label "WAKTU", "OPERATOR").
  static double caption(double fontSize) => fontSize * 0.79;

  /// Teks barcode/kode yang ditekankan (emphasize).
  static double barcode(double fontSize) => fontSize * 2.29;

  /// Jarak antar baris teks, konsisten di semua layout.
  static double lineHeight(double fontSize) => fontSize * 1.7;
}
