import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/watermark_data.dart';

/// Ukuran kanvas yang dibutuhkan sebuah renderer untuk satu foto.
class WatermarkCanvasSize {
  final double width;
  final double height;
  const WatermarkCanvasSize(this.width, this.height);
}

/// Kontrak yang harus diimplementasikan setiap gaya watermark.
///
/// Setiap renderer bertanggung jawab untuk:
/// 1. Menghitung ukuran kanvas akhir lewat [computeCanvasSize].
/// 2. Menggambar seluruh elemen visual (background, foto, teks, badge,
///    logo) lewat [paint].
///
/// Loading gambar sumber/logo dari disk, encoding ke PNG, dan penulisan
/// file output dilakukan terpusat di `WatermarkService` — bukan tugas
/// renderer — supaya logika I/O tidak terduplikasi di setiap gaya.
abstract class WatermarkRenderer {
  /// Nama gaya, untuk logging.
  String get name;

  /// Hitung ukuran kanvas akhir berdasarkan ukuran foto asli dan data
  /// watermark (jumlah baris teks bisa mempengaruhi tinggi strip, dsb).
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  });

  /// Gambar seluruh elemen watermark ke [canvas].
  ///
  /// [canvasSize] adalah hasil dari [computeCanvasSize] untuk foto yang
  /// sama. [srcImage] adalah foto asli (belum dipotong/diskalakan).
  /// [logoImage] adalah logo perusahaan jika berhasil dimuat (boleh null).
  void paint({
    required Canvas canvas,
    required WatermarkCanvasSize canvasSize,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  });
}
