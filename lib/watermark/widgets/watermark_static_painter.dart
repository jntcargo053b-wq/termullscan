// lib/watermark/widgets/watermark_static_painter.dart
// ============================================================
// CUSTOMPAINTER UNTUK ELEMEN STATIS OVERLAY LIVE PREVIEW
// ============================================================
// Pasangan dari WatermarkDynamicPainter. Menggambar HANYA elemen
// yang jarang berubah: logo, background bar, accent bar, brand,
// kode verifikasi, meta (barcode/operator — konten per-sesi).
//
// Dibungkus RepaintBoundary TERPISAH dari WatermarkDynamicPainter
// di in_app_camera_screen.dart, supaya Skia bisa cache layer ini
// sebagai raster dan TIDAK ikut digambar ulang tiap detik hanya
// karena jam / koordinat GPS berubah — hanya repaint kalau field
// yang relevan (logo, barcode, operator, style, dsb.) berubah.
//
// 100% delegasi ke WatermarkLayout.paintStaticOnly() — tidak ada
// logika watermark baru di file ini.
// ============================================================

import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import '../layouts/base_layout.dart';
import '../models/watermark_data.dart';

class WatermarkStaticPainter extends CustomPainter {
  final WatermarkLayout layout;
  final WatermarkData data;
  final ui.Image? logoImage;

  const WatermarkStaticPainter({
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

    layout.paintStaticOnly(
      canvas: canvas,
      metrics: metrics,
      logoImage: logoImage,
      data: data,
    );
  }

  // ─── Hanya repaint kalau elemen STATIS yang benar-benar berubah ──
  // SENGAJA TIDAK memeriksa timestamp/latitude/longitude/locationName
  // — itu tanggung jawab WatermarkDynamicPainter. Layer ini harus
  // tetap "diam" walau jam/GPS update tiap detik.
  @override
  bool shouldRepaint(covariant WatermarkStaticPainter oldDelegate) {
    if (!identical(oldDelegate.logoImage, logoImage)) return true;
    if (!identical(oldDelegate.layout, layout)) return true;
    final a = oldDelegate.data;
    final b = data;
    return a.operatorName != b.operatorName ||
        a.companyName != b.companyName ||
        a.barcodeValue != b.barcodeValue ||
        a.barcodeFormat != b.barcodeFormat ||
        a.logoPath != b.logoPath ||
        a.position != b.position ||
        a.fontSize != b.fontSize ||
        a.backgroundOpacity != b.backgroundOpacity ||
        a.fontFamily != b.fontFamily;
  }
}
