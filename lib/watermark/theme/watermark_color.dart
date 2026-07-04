// ============================================================
// lib/watermark/theme/watermark_color.dart
// ============================================================
// Bagian dari WatermarkTheme. Setiap watermark style (Polaroid,
// Minimal, Professional, Stamp) tetap punya identitas visual
// berbeda — tapi sekarang diakses lewat SATU struktur field yang
// sama (WatermarkColorScheme), bukan hex-code tersebar di tiap
// file layout.
// ============================================================

import 'package:flutter/material.dart';
import '../watermark_style.dart';

class WatermarkColorScheme {
  /// Warna dasar kartu/panel (mis. kertas Polaroid, panel gelap Stamp).
  final Color surface;

  /// Warna teks utama/ditekankan (value barcode, judul stempel).
  final Color textPrimary;

  /// Warna teks sekunder (value baris biasa: operator, waktu, lokasi).
  final Color textSecondary;

  /// Warna teks label/caption kecil (mis. "WAKTU", "OPERATOR").
  final Color textMuted;

  /// Warna aksen/highlight khas style ini (garis tepi, accent bar, badge).
  final Color accent;

  /// Warna garis divider tipis.
  final Color divider;

  const WatermarkColorScheme({
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.divider,
  });
}

class WatermarkColor {
  const WatermarkColor._();

  static const polaroid = WatermarkColorScheme(
    surface: Color(0xFFFAFAF6),
    textPrimary: Color(0xFF1F1F1F),
    textSecondary: Color(0xFF2C2C2C),
    textMuted: Color(0xFF8A8A82),
    accent: Color(0xFFE67E22),
    divider: Color(0xFFE2E0D8),
  );

  static const minimal = WatermarkColorScheme(
    surface: Color(0xFF1B1E22),
    textPrimary: Colors.white,
    textSecondary: Colors.white,
    textMuted: Colors.white,
    accent: Color(0xFFFFB74D),
    divider: Colors.white,
  );

  static const professional = WatermarkColorScheme(
    surface: Color(0xFF1B1E22),
    textPrimary: Colors.white,
    textSecondary: Colors.white,
    textMuted: Colors.white,
    accent: Color(0xFF4FA8E8),
    divider: Colors.white,
  );

  static const stamp = WatermarkColorScheme(
    surface: Color(0xFF000000),
    textPrimary: Colors.white,
    // stampColor (hijau VERIFIED / oranye MANUAL) ditentukan dinamis di
    // stamp_layout.dart karena bergantung pada data.isManual, jadi accent
    // di sini hanya dipakai sebagai fallback/aksen sekunder.
    textSecondary: Colors.white,
    textMuted: Colors.white70,
    accent: Color(0xFF2E8B57),
    divider: Colors.white,
  );

  static const timestamp = WatermarkColorScheme(
    surface: Color(0xFF000000),
    textPrimary: Colors.white,
    textSecondary: Colors.white,
    textMuted: Colors.white70,
    accent: Color(0xFFFFC107),
    divider: Colors.white,
  );

  static WatermarkColorScheme forStyle(WatermarkStyle style) {
    switch (style) {
      case WatermarkStyle.polaroid:
        return polaroid;
      case WatermarkStyle.minimal:
        return minimal;
      case WatermarkStyle.professional:
        return professional;
      case WatermarkStyle.stamp:
        return stamp;
      case WatermarkStyle.timestamp:
        return timestamp;
    }
  }
}
