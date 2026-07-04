// ============================================================
// lib/watermark/theme/watermark_alignment.dart
// ============================================================
// Bagian dari WatermarkTheme. Menentukan posisi & perataan teks
// strip/overlay berdasarkan WatermarkPosition — sebelumnya logika
// switch-case ini ditulis ulang secara terpisah (dan sedikit
// berbeda-beda) di computeMetrics/paintOnCanvas tiap layout.
// ============================================================

import 'package:flutter/material.dart';
import '../watermark_settings.dart';

class WatermarkPlacement {
  /// Posisi atas (y) dari strip/overlay/panel.
  final double top;

  /// Perataan teks di dalam strip/overlay.
  final TextAlign textAlign;

  /// True jika strip berada di bagian bawah foto.
  final bool atBottom;

  const WatermarkPlacement({
    required this.top,
    required this.textAlign,
    required this.atBottom,
  });
}

class WatermarkAlignment {
  const WatermarkAlignment._();

  /// Menghitung posisi & alignment overlay/strip berdasarkan [WatermarkPosition].
  static WatermarkPlacement resolve({
    required WatermarkPosition position,
    required double photoHeight,
    required double overlayHeight,
  }) {
    switch (position) {
      case WatermarkPosition.bottomRight:
        return WatermarkPlacement(
          top: photoHeight - overlayHeight,
          textAlign: TextAlign.right,
          atBottom: true,
        );
      case WatermarkPosition.bottomLeft:
        return WatermarkPlacement(
          top: photoHeight - overlayHeight,
          textAlign: TextAlign.left,
          atBottom: true,
        );
      case WatermarkPosition.topRight:
        return WatermarkPlacement(
          top: 0,
          textAlign: TextAlign.right,
          atBottom: false,
        );
      case WatermarkPosition.topLeft:
        return WatermarkPlacement(
          top: 0,
          textAlign: TextAlign.left,
          atBottom: false,
        );
    }
  }

  /// Sisi horizontal (kiri/kanan) tempat elemen (mis. logo) ditempatkan,
  /// berlawanan dengan sisi teks — dipakai Stamp & Minimal layout.
  static bool isLeftAligned(WatermarkPosition position) =>
      position == WatermarkPosition.bottomLeft ||
      position == WatermarkPosition.topLeft;
}
