import 'package:flutter/material.dart';
import '../watermark_style.dart';

class WatermarkColorScheme {
  final Color surface;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
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

  // ─── TAMBAHKAN fullInfo ──────────────────────────────────────
  static const fullInfo = WatermarkColorScheme(
    surface: Color(0xFF000000),
    textPrimary: Colors.white,
    textSecondary: Colors.white,
    textMuted: Colors.white70,
    accent: Color(0xFFFFC107), // warna kuning/amber
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
      case WatermarkStyle.fullInfo:
        return fullInfo; // ← case baru
    }
  }
}
