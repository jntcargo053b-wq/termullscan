import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/watermark_data.dart';

/// Ukuran kanvas yang dibutuhkan oleh layout.
class WatermarkCanvasSize {
  final double width;
  final double height;
  const WatermarkCanvasSize(this.width, this.height);
}

/// Kontrak yang harus diimplementasikan setiap layout.
/// Layout bertanggung jawab untuk:
/// 1. Menghitung ukuran kanvas
/// 2. Menggambar ke Canvas (digunakan oleh renderer)
/// 3. Menyediakan Widget preview (digunakan di settings)
abstract class WatermarkLayout {
  /// Nama layout yang ramah user (dengan emoji jika perlu).
  String get displayName;

  /// Gaya enum yang sesuai.
  WatermarkStyle get style;

  /// Hitung ukuran kanvas berdasarkan ukuran foto dan data.
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  });

  /// Gambar layout ke Canvas.
  void paintOnCanvas({
    required Canvas canvas,
    required WatermarkCanvasSize canvasSize,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  });

  /// Bangun Widget preview untuk ditampilkan di settings.
  Widget buildPreview({
    required WatermarkData previewData,
    required bool hasLogo,
    required String? logoPath,
  });
}
