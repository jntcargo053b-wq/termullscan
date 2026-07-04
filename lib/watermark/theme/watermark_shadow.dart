// ============================================================
// lib/watermark/theme/watermark_shadow.dart
// ============================================================
// Bagian dari WatermarkTheme. Preset shadow/elevasi yang dipakai
// berulang di semua layout (shadow teks, shadow kartu, shadow
// logo card) — supaya nilai blur/opacity tidak ditulis ulang
// dengan angka berbeda-beda di tiap file.
// ============================================================

import 'package:flutter/material.dart';

class WatermarkShadowStyle {
  final Color color;
  final double blur;
  final double opacity;
  final Offset offset;

  const WatermarkShadowStyle({
    required this.color,
    required this.blur,
    required this.opacity,
    this.offset = Offset.zero,
  });

  List<Shadow> toTextShadows() => [
        Shadow(
          color: color.withOpacity(opacity),
          blurRadius: blur,
          offset: offset,
        ),
      ];

  Paint toPaint() => Paint()..color = color.withOpacity(opacity);
}

class WatermarkShadow {
  const WatermarkShadow._();

  /// Shadow tipis di belakang teks agar tetap terbaca di atas foto apa pun.
  static const text = WatermarkShadowStyle(
    color: Colors.black,
    blur: 3,
    opacity: 0.55,
    offset: Offset(0, 1),
  );

  /// Shadow lembut untuk kartu/badge kecil (mis. logo card).
  static const soft = WatermarkShadowStyle(
    color: Colors.black,
    blur: 6,
    opacity: 0.20,
  );

  /// Shadow kartu utama (mis. bingkai kartu Polaroid).
  static const card = WatermarkShadowStyle(
    color: Colors.black,
    blur: 14,
    opacity: 0.25,
    offset: Offset(0, 6),
  );

  /// Shadow melayang lebih dalam (drop-shadow ganda pada kartu Polaroid).
  static const floating = WatermarkShadowStyle(
    color: Colors.black,
    blur: 22,
    opacity: 0.28,
  );

  /// Shadow untuk kartu/badge di atas foto gelap (logo card, badge manual).
  static const overlayCard = WatermarkShadowStyle(
    color: Colors.black,
    blur: 0,
    opacity: 0.30,
  );
}
