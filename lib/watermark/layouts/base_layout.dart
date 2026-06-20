import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/watermark_data.dart';
import '../models/watermark_style.dart';
import 'layout_metrics.dart';

class WatermarkCanvasSize {
  final double width;
  final double height;
  const WatermarkCanvasSize(this.width, this.height);
}

/// Base class untuk semua layout.
abstract class WatermarkLayout {
  String get displayName;
  WatermarkStyle get style;

  /// Hitung semua metrik layout. WAJIB diimplementasikan.
  LayoutMetrics computeMetrics({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  });

  /// Hitung ukuran kanvas (implementasi DEFAULT, pakai metrics).
  /// SUBCLASS TIDAK PERLU OVERRIDE METHOD INI.
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    final metrics = computeMetrics(
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      data: data,
    );
    return WatermarkCanvasSize(metrics.canvasWidth, metrics.canvasHeight);
  }

  /// Gambar layout ke Canvas.
  void paintOnCanvas({
    required ui.Canvas canvas,
    required LayoutMetrics metrics,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  });

  /// Widget preview untuk settings.
  Widget buildPreview({
    required WatermarkData previewData,
    required bool hasLogo,
    required String? logoPath,
    double previewWidth = 300,
    double previewHeight = 400,
  });
}
