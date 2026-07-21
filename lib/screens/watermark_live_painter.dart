// lib/watermark/widgets/watermark_live_painter.dart
// ============================================================
// CUSTOMPAINTER UNTUK PRATINJAU WATERMARK LIVE (IN-APP CAMERA)
// ============================================================
// GANTI dari pendekatan lama (renderOverlayPng → PictureRecorder →
// toImage → encode PNG → Image.memory decode) yang berjalan tiap
// detik. Painter ini HANYA memanggil canvas API yang sama dengan
// yang dipakai overlay video — WatermarkLayout.paintWatermarkOnly()
// — langsung ke Canvas milik Flutter di paint(). Tidak ada
// PictureRecorder, tidak ada raster ke bitmap, tidak ada encode/
// decode PNG sama sekali untuk jalur live preview ini.
//
// ✅ TIDAK ADA logika watermark baru di file ini — 100% delegasi ke
// method WatermarkLayout yang sudah ada (base_layout.dart & subclass
// -nya). File ini murni "jalur render" yang lebih murah.
// ============================================================

import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import '../layouts/base_layout.dart';
import '../models/watermark_data.dart';

class WatermarkLivePainter extends CustomPainter {
  final WatermarkLayout layout;
  final WatermarkData data;
  final ui.Image? logoImage;

  const WatermarkLivePainter({
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

    layout.paintWatermarkOnly(
      canvas: canvas,
      metrics: metrics,
      logoImage: logoImage,
      data: data,
    );
  }

  // ─── Skip repaint kalau tidak ada elemen yang benar-benar berubah ──
  // Ini bagian dari optimasi: detak Timer 1 detik tetap memicu build,
  // tapi kalau isi watermark ternyata identik (mis. logo belum siap /
  // GPS mengirim event tanpa perubahan koordinat), Flutter tidak perlu
  // menggambar ulang layer ini sama sekali.
  @override
  bool shouldRepaint(covariant WatermarkLivePainter oldDelegate) {
    if (!identical(oldDelegate.logoImage, logoImage)) return true;
    if (!identical(oldDelegate.layout, layout)) return true;
    final a = oldDelegate.data;
    final b = data;
    return a.formattedTimestamp != b.formattedTimestamp ||
        a.latitude != b.latitude ||
        a.longitude != b.longitude ||
        a.locationName != b.locationName ||
        a.operatorName != b.operatorName ||
        a.companyName != b.companyName ||
        a.barcodeValue != b.barcodeValue ||
        a.position != b.position ||
        a.fontSize != b.fontSize ||
        a.backgroundOpacity != b.backgroundOpacity ||
        a.fontFamily != b.fontFamily;
  }
}
