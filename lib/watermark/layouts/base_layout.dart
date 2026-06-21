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
  const WatermarkLayout();

  String get displayName;

  /// Default: tidak terikat ke satu WatermarkStyle spesifik.
  /// Layout lengkap (Polaroid/Minimal/Professional/Stamp) override ini.
  WatermarkStyle? get style => null;

  /// Hitung semua metrik layout.
  /// Layout preview-only (Standard/TopLeft/TopRight/BottomLeft/BottomRight)
  /// tidak perlu override ini karena tidak melakukan canvas rendering sendiri.
  LayoutMetrics computeMetrics({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    throw UnimplementedError(
      '$runtimeType belum mengimplementasikan computeMetrics()',
    );
  }

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
  /// Layout preview-only tidak perlu override ini.
  void paintOnCanvas({
    required ui.Canvas canvas,
    required LayoutMetrics metrics,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    throw UnimplementedError(
      '$runtimeType belum mengimplementasikan paintOnCanvas()',
    );
  }

  /// Widget preview untuk settings.
  Widget buildPreview({
    required WatermarkData previewData,
    required bool hasLogo,
    required String? logoPath,
    double previewWidth = 300,
    double previewHeight = 400,
  });
}
