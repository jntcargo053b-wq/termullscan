import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/watermark_data.dart';
import '../watermark_style.dart';
import 'layout_metrics.dart';

abstract class WatermarkLayout {
  const WatermarkLayout();

  String get displayName;

  WatermarkStyle? get style => null;

  /// Apakah gaya ini bisa dipakai sebagai overlay PNG pada video.
  /// Overlay video WAJIB berukuran identik dengan frame video, jadi
  /// default true di sini hanya valid untuk layout yang canvas-nya
  /// = ukuran foto/frame asli. Layout yang menambah border/strip di
  /// sekeliling foto (sehingga canvasWidth/Height > photoWidth/Height,
  /// mis. Polaroid) WAJIB override ini ke false.
  bool get supportsVideoOverlay => true;

  LayoutMetrics computeMetrics({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    throw UnimplementedError(
      '$runtimeType belum mengimplementasikan computeMetrics()',
    );
  }

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

  /// Gambar hanya elemen watermark (teks, logo, barcode) tanpa foto latar.
  /// Digunakan untuk menghasilkan overlay PNG transparan pada video.
  void paintWatermarkOnly({
    required ui.Canvas canvas,
    required LayoutMetrics metrics,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    throw UnimplementedError(
      '$runtimeType belum mengimplementasikan paintWatermarkOnly()',
    );
  }

  Widget buildPreview({
    required WatermarkData previewData,
    required bool hasLogo,
    required String? logoPath,
    double previewWidth = 300,
    double previewHeight = 400,
  });
}
