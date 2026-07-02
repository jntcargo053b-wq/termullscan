import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class LogoWidget {
  /// Menggambar logo dengan opacity murni (tidak mengubah warna asli logo).
  ///
  /// FIX PENTING: implementasi lama memakai
  /// `ColorFilter.mode(Colors.white.withOpacity(opacity), blendMode)` yang
  /// men-tint seluruh logo menjadi putih solid saat opacity mendekati 1.0
  /// (logo berwarna/brand jadi hilang, cuma siluet putih). Preview di UI
  /// (pakai Image.file biasa) tidak kena bug ini, jadi hasil akhir foto
  /// tidak pernah cocok dengan preview. Sekarang opacity hanya memodulasi
  /// alpha channel gambar lewat Paint.color, warna asli logo tetap utuh.
  static void paint({
    required Canvas canvas,
    required ui.Image? logoImage,
    required double x,
    required double y,
    required double maxWidth,
    required double maxHeight,
    double opacity = 1.0,
  }) {
    if (logoImage == null) {
      debugPrint('⚠️ LogoWidget: logoImage is null, skipping paint');
      return;
    }

    final logoW = logoImage.width.toDouble();
    final logoH = logoImage.height.toDouble();

    final scaleX = maxWidth / logoW;
    final scaleY = maxHeight / logoH;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final drawW = logoW * scale;
    final drawH = logoH * scale;

    canvas.drawImageRect(
      logoImage,
      Rect.fromLTWH(0, 0, logoW, logoH),
      Rect.fromLTWH(x, y, drawW, drawH),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true
        // Alpha-only modulation — warna asli logo (brand color) tetap terjaga.
        ..color = Colors.white.withOpacity(opacity.clamp(0.0, 1.0)),
    );
  }
}
