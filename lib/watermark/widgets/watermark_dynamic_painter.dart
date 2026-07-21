// lib/watermark/widgets/watermark_dynamic_painter.dart
// ============================================================
// CUSTOMPAINTER UNTUK ELEMEN DINAMIS OVERLAY LIVE PREVIEW
// ============================================================
// Pasangan dari WatermarkStaticPainter. Menggambar HANYA elemen
// yang sering berubah: jam, tanggal, hari, koordinat, alamat,
// akurasi (dan cuaca jika ada di masa depan).
//
// Dibungkus RepaintBoundary TERPISAH dari WatermarkStaticPainter
// di in_app_camera_screen.dart, supaya tiap tick clock/GPS HANYA
// me-raster ulang layer kecil ini — logo, background bar, brand,
// dsb. di layer static tidak ikut ter-repaint.
//
// 100% delegasi ke WatermarkLayout.paintDynamicOnly() — tidak ada
// logika watermark baru di file ini.
// ============================================================

import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import '../layouts/base_layout.dart';
import '../models/watermark_data.dart';

class WatermarkDynamicPainter extends CustomPainter {
  final WatermarkLayout layout;
  final WatermarkData data;
  final ui.Image? logoImage;

  const WatermarkDynamicPainter({
    required this.layout,
    required this.data,
    required this.logoImage,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final metrics = layout.computeMetrics(
      photoWidth: size.width,
      photoHeight: size.height,
      data: data,
    );
    if (metrics.canvasWidth <= 0 || metrics.canvasHeight <= 0) return;

    layout.paintDynamicOnly(
      canvas: canvas,
      metrics: metrics,
      logoImage: logoImage,
      data: data,
    );
  }

  // ─── Skip repaint kalau tidak ada elemen dinamis yang berubah ──
  @override
  bool shouldRepaint(covariant WatermarkDynamicPainter oldDelegate) {
    if (!identical(oldDelegate.logoImage, logoImage)) return true;
    if (!identical(oldDelegate.layout, layout)) return true;
    final a = oldDelegate.data;
    final b = data;
    return a.formattedTimestamp != b.formattedTimestamp ||
        a.latitude != b.latitude ||
        a.longitude != b.longitude ||
        a.locationName != b.locationName;
  }
}
