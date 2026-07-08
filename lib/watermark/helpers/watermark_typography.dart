// ============================================================
// lib/watermark/helpers/watermark_typography.dart
// ============================================================
// Sumber tunggal (single source of truth) untuk rasio ukuran
// logo, judul, isi, caption, dan barcode di SEMUA watermark
// layout (Polaroid, Minimal, Professional, Stamp).
//
// Tujuan: memastikan keempat layout memakai proporsi yang sama
// relatif terhadap `data.fontSize` (isi/body) dan `baseSize`
// (logo), alih-alih setiap layout menulis angka rasio sendiri.
//
// Basis acuan (saat fontSize default = 14):
//   Logo     : baseSize * 0.18   (≈ 40px pada foto ukuran umum)
//   Judul    : fontSize * 1.29   (≈ 18)
//   Isi      : fontSize * 1.00   (≈ 13-14)
//   Caption  : fontSize * 0.79   (≈ 11)
//   Barcode  : fontSize * 2.29   (≈ 32, ditekankan/emphasize)
//   LineHeight: fontSize * 1.7   (spasi antar baris, konsisten)
// ============================================================

class WatermarkTypography {
  const WatermarkTypography._();

  /// Ukuran maksimum logo, relatif terhadap [baseSize] foto
  /// (baseSize = min(width, height)).
  static double logo(double baseSize) => baseSize * 0.18;

  /// Ukuran judul/heading (mis. label stempel besar di Stamp layout).
  static double title(double fontSize) => fontSize * 1.29;

  /// Ukuran teks isi/body utama (value pada baris info).
  static double body(double fontSize) => fontSize;

  /// Ukuran caption/label kecil (mis. label "WAKTU", "OPERATOR").
  static double caption(double fontSize) => fontSize * 0.79;

  /// Ukuran teks barcode/kode yang ditekankan (emphasize).
  static double barcode(double fontSize) => fontSize * 2.29;

  /// Jarak antar baris teks, konsisten di semua layout.
  static double lineHeight(double fontSize) => fontSize * 1.7;
}
