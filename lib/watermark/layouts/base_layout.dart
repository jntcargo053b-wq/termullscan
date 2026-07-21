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

  // ─── SPLIT STATIC / DYNAMIC (khusus live preview kamera) ────────
  // Tujuannya supaya WatermarkStaticPainter & WatermarkDynamicPainter
  // (lib/watermark/widgets/) bisa membungkus masing-masing dalam
  // RepaintBoundary sendiri: elemen yang jarang berubah (logo, bar
  // background, brand, kode verifikasi) tidak perlu di-raster ulang
  // tiap detik hanya karena jam / koordinat GPS berubah.
  //
  // DEFAULT di bawah ini SENGAJA dibuat agar layout yang BELUM
  // diimplementasikan (belum override) tetap berjalan 100% seperti
  // sebelumnya — paintDynamicOnly() default memanggil
  // paintWatermarkOnly() penuh tiap tick (tidak ada regresi),
  // sedangkan paintStaticOnly() default no-op (tidak menggambar apa
  // pun, karena semua sudah digambar penuh oleh paintDynamicOnly()).
  // Override kedua method ini bersama-sama di subclass kalau ingin
  // memanfaatkan optimasi repaint-terpisah.

  /// Gambar elemen yang JARANG berubah: logo, background bar, accent
  /// bar, brand, kode verifikasi, meta (barcode/operator — ini juga
  /// dianggap "static" karena tidak berubah per-tick, hanya per sesi).
  void paintStaticOnly({
    required ui.Canvas canvas,
    required LayoutMetrics metrics,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    // no-op by default — lihat paintDynamicOnly()
  }

  /// Gambar elemen yang SERING berubah: jam, tanggal, koordinat,
  /// alamat, akurasi, (cuaca jika ada).
  void paintDynamicOnly({
    required ui.Canvas canvas,
    required LayoutMetrics metrics,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    paintWatermarkOnly(
      canvas: canvas,
      metrics: metrics,
      logoImage: logoImage,
      data: data,
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
