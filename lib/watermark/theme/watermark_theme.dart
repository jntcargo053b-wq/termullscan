// ============================================================
// lib/watermark/theme/watermark_theme.dart
// ============================================================
// Kelas payung (umbrella) yang menyatukan seluruh sub-modul:
//
//   WatermarkTheme
//   ├── WatermarkTypography  (judul/isi/caption/barcode/lineHeight)
//   ├── WatermarkSpacing     (padding/gap)
//   ├── WatermarkMetrics     (radius/border/stroke)
//   ├── WatermarkColor       (palet warna semantik per style)
//   ├── WatermarkShadow      (preset elevasi/shadow)
//   ├── WatermarkDivider     (garis pemisah)
//   ├── WatermarkLogoStyle   (ukuran & kartu latar logo)
//   └── WatermarkAlignment   (posisi & perataan strip/overlay)
//
// Setiap layout (Polaroid/Minimal/Professional/Stamp) HANYA
// memanggil `WatermarkTheme.of(...)` sekali, lalu membaca field
// yang sudah dihitung — bukan mendefinisikan ulang rasio/warna
// sendiri-sendiri.
// ============================================================

import 'dart:math' as math;
import '../models/watermark_data.dart';
import '../watermark_style.dart';
import 'watermark_color.dart';
import 'watermark_logo_style.dart';
import 'watermark_metrics.dart';
import 'watermark_shadow.dart';
import 'watermark_spacing.dart';
import 'watermark_typography.dart';

export 'watermark_alignment.dart';
export 'watermark_color.dart';
export 'watermark_divider.dart';
export 'watermark_logo_style.dart';
export 'watermark_metrics.dart';
export 'watermark_shadow.dart';
export 'watermark_spacing.dart';
export 'watermark_typography.dart';

class WatermarkTheme {
  final WatermarkStyle style;
  final double baseSize;
  final double fontSize;

  // ── Spacing ──────────────────────────────────────────────
  final double padding;

  // ── Typography (sudah dihitung dari data.fontSize) ───────
  final double titleFontSize;
  final double bodyFontSize;
  final double captionFontSize;
  final double barcodeFontSize;
  final double lineHeight;
  final double barcodeLineHeight;
  final double titleLineHeight;

  // ── Logo ──────────────────────────────────────────────────
  final double logoSize;

  // ── Color (palet sesuai style) ───────────────────────────
  final WatermarkColorScheme color;

  const WatermarkTheme._({
    required this.style,
    required this.baseSize,
    required this.fontSize,
    required this.padding,
    required this.titleFontSize,
    required this.bodyFontSize,
    required this.captionFontSize,
    required this.barcodeFontSize,
    required this.lineHeight,
    required this.barcodeLineHeight,
    required this.titleLineHeight,
    required this.logoSize,
    required this.color,
  });

  factory WatermarkTheme.of({
    required WatermarkStyle style,
    required WatermarkData data,
    required double baseSize,
  }) {
    final fontSize = data.fontSize;
    return WatermarkTheme._(
      style: style,
      baseSize: baseSize,
      fontSize: fontSize,
      padding: WatermarkSpacing.basePadding(baseSize),
      titleFontSize: WatermarkTypography.title(fontSize),
      bodyFontSize: WatermarkTypography.body(fontSize),
      captionFontSize: WatermarkTypography.caption(fontSize),
      barcodeFontSize: WatermarkTypography.barcode(fontSize),
      lineHeight: WatermarkTypography.lineHeight(fontSize),
      barcodeLineHeight:
          WatermarkTypography.lineHeight(WatermarkTypography.barcode(fontSize)),
      titleLineHeight:
          WatermarkTypography.lineHeight(WatermarkTypography.title(fontSize)),
      logoSize: WatermarkLogoStyle.size(baseSize),
      color: WatermarkColor.forStyle(style),
    );
  }

  /// Selisih tinggi baris saat baris barcode dirender lebih besar dari
  /// baris normal — dipakai untuk menambah tinggi strip/panel/overlay
  /// supaya baris barcode tidak tumpang tindih dengan baris di bawahnya.
  double get barcodeRowBonus => barcodeLineHeight - lineHeight;

  /// Sama seperti [barcodeRowBonus], tapi untuk baris judul (mis. nama
  /// lokasi di Professional layout) yang dirender lebih besar dari baris
  /// normal.
  double get titleRowBonus => titleLineHeight - lineHeight;

  // ── Metrics passthrough (supaya layout tidak perlu import terpisah) ──
  double get cardRadius => WatermarkMetrics.cardRadius;
  double get hairlineStroke => WatermarkMetrics.hairlineStroke(baseSize);
  double get accentBarWidth => WatermarkMetrics.accentBarWidth(baseSize);
  double get stampStroke => WatermarkMetrics.stampStroke(baseSize);

  // ── Shadow passthrough ────────────────────────────────────
  WatermarkShadowStyle get textShadow => WatermarkShadow.text;
  WatermarkShadowStyle get cardShadow => WatermarkShadow.card;
  WatermarkShadowStyle get floatingShadow => WatermarkShadow.floating;
  WatermarkShadowStyle get softShadow => WatermarkShadow.soft;

  // ── Logo card style passthrough ──────────────────────────
  double logoCardPadding(double drawW) => WatermarkLogoStyle.cardPadding(drawW);
  double logoCardRadius(double cardPad) => WatermarkLogoStyle.cardRadius(cardPad);

  /// Ukuran teks barcode yang di-clamp supaya tidak pernah melebihi
  /// [maxAllowed] (dipakai Stamp layout, di mana kotak stempel berukuran
  /// tetap berbasis baseSize, bukan fontSize).
  double clampedFontSize(double desired, double maxAllowed) =>
      math.min(desired, maxAllowed);
}
