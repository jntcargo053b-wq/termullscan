// ============================================================
// lib/watermark/theme/watermark_logo_style.dart
// ============================================================
// Bagian dari WatermarkTheme. Sumber tunggal ukuran logo dan
// gaya kartu latar belakang logo (cardPad/radius/opacity),
// yang sebelumnya beda-beda rasio di tiap layout (0.20 vs 0.25).
// ============================================================

import 'package:flutter/material.dart';

class WatermarkLogoStyle {
  const WatermarkLogoStyle._();

  /// Ukuran maksimum logo, relatif terhadap baseSize foto.
  static double size(double baseSize, {double ratio = 0.18}) =>
      baseSize * ratio;

  /// Padding kartu latar belakang logo, relatif terhadap lebar logo
  /// yang sudah discale (drawW). Sebelumnya Polaroid pakai 0.20 sementara
  /// Minimal/Professional/Stamp pakai 0.25 — sekarang satu rasio untuk semua.
  static double cardPadding(double drawW, {double ratio = 0.22}) =>
      drawW * ratio;

  /// Radius sudut kartu latar belakang logo, relatif terhadap cardPad.
  static double cardRadius(double cardPad, {double ratio = 0.8}) =>
      cardPad * ratio;

  /// Warna latar kartu logo (transparan gelap agar logo tetap kontras
  /// di atas foto apa pun).
  static Color cardBackground({double opacity = 0.30}) =>
      Colors.black.withOpacity(opacity);
}
