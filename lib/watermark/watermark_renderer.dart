import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import '../models/scan_entry.dart';
import 'models/watermark_data.dart';
import 'watermark_factory.dart';
import 'watermark_settings.dart';

class WatermarkRenderer {
  /// Diisi setiap render() dipanggil (null jika berhasil, terisi jika
  /// gagal). Dipakai pemanggil (photo_scan_screen.dart) untuk
  /// menampilkan alasan kegagalan ke user, alih-alih diam-diam
  /// menyimpan foto tanpa watermark seperti sebelumnya.
  static String? lastError;

  /// Render watermark ke file output (FOTO)
  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    lastError = null;
    if (kDebugMode) {
      debugPrint('🎯 WATERMARK RENDER START');
      debugPrint('  Style: ${settings.style.name}');
    }

    ui.Image? srcImage;
    ui.Image? logoImage;
    ui.Codec? codec;
    ui.Codec? logoCodec;
    ui.Image? outputImage;

    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        lastError = 'File foto sumber tidak ditemukan';
        debugPrint('❌ File tidak ditemukan: $imagePath');
        return null;
      }

      final imageBytes = await file.readAsBytes();

      codec = await ui.instantiateImageCodec(
        imageBytes,
        targetWidth: 1600,
      );
      final frame = await codec.getNextFrame();
      srcImage = frame.image;
      codec.dispose();
      codec = null;

      final photoWidth = srcImage.width.toDouble();
      final photoHeight = srcImage.height.toDouble();

      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoCodec = await _loadLogoCodec(settings.logoPath!, targetWidth: 1600);
        if (logoCodec != null) {
          final logoFrame = await logoCodec.getNextFrame();
          logoImage = logoFrame.image;
          logoCodec.dispose();
          logoCodec = null;
        }
      }

      final data = WatermarkData(
        timestamp: entry.timestamp,
        operatorName: settings.operatorName,
        companyName: settings.companyName,
        barcodeValue: entry.value,
        barcodeFormat: entry.barcodeFormat,
        latitude: entry.latitude,
        longitude: entry.longitude,
        locationName: entry.locationName,
        logoPath: settings.logoPath,
        position: settings.position,
        fontSize: settings.fontSize,
        backgroundOpacity: settings.backgroundOpacity,
        fontFamily: settings.fontFamily,
      );

      final layout = WatermarkFactory.create(settings.style);
      final metrics = layout.computeMetrics(
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        data: data,
      );

      if (metrics.canvasWidth <= 0 || metrics.canvasHeight <= 0) {
        throw Exception('Canvas size invalid');
      }

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      layout.paintOnCanvas(
        canvas: canvas,
        metrics: metrics,
        srcImage: srcImage,
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        logoImage: logoImage,
        data: data,
      );

      final picture = recorder.endRecording();
      outputImage = await picture.toImage(
        metrics.canvasWidth.round(),
        metrics.canvasHeight.round(),
      );

      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      outputImage.dispose();
      outputImage = null;

      if (byteData == null) {
        lastError = 'Gagal meng-encode PNG hasil watermark';
        debugPrint('❌ Gagal encode PNG');
        return null;
      }

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(byteData.buffer.asUint8List());

      if (kDebugMode) debugPrint('✅ Watermark saved: $outputPath');
      return outputPath;
    } catch (e, stack) {
      lastError = e.toString();
      if (kDebugMode) debugPrint('❌ Error: $e\n$stack');
      return null;
    } finally {
      codec?.dispose();
      logoCodec?.dispose();
      srcImage?.dispose();
      logoImage?.dispose();
      outputImage?.dispose();
    }
  }

  // ─── RENDER OVERLAY PNG UNTUK VIDEO ────────────────────
  /// Generate overlay PNG (full-frame, transparan) untuk video.
  static Future<Uint8List?> renderOverlayPng({
    required int canvasWidth,
    required int canvasHeight,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    ui.Image? logoImage;
    ui.Codec? logoCodec;
    ui.Image? outputImage;

    try {
      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoCodec = await _loadLogoCodec(settings.logoPath!, targetWidth: canvasWidth);
        if (logoCodec != null) {
          final logoFrame = await logoCodec.getNextFrame();
          logoImage = logoFrame.image;
          logoCodec.dispose();
          logoCodec = null;
        }
      }

      final data = WatermarkData(
        timestamp: entry.timestamp,
        operatorName: settings.operatorName,
        companyName: settings.companyName,
        barcodeValue: entry.value,
        barcodeFormat: entry.barcodeFormat,
        latitude: entry.latitude,
        longitude: entry.longitude,
        locationName: entry.locationName,
        logoPath: settings.logoPath,
        position: settings.position,
        fontSize: settings.fontSize,
        backgroundOpacity: settings.backgroundOpacity,
        fontFamily: settings.fontFamily,
      );

      final layout = WatermarkFactory.create(settings.style);

      // ✅ Guard eksplisit: sebagian gaya (mis. Polaroid) menambahkan
      // border/strip di sekeliling foto sehingga canvas-nya LEBIH BESAR
      // dari frame video — secara struktural tidak bisa dipakai sebagai
      // overlay video (overlay wajib berukuran identik dengan frame).
      // Daripada memanggil paintWatermarkOnly() dan menangkap
      // UnimplementedError (yang tetap membuang waktu decode logo di
      // atas), kita deteksi lebih awal supaya pemanggil langsung tahu
      // dan bisa fallback ke drawtext tanpa proses sia-sia.
      if (!layout.supportsVideoOverlay) {
        debugPrint(
          '⚠️ Gaya "${settings.style.name}" tidak kompatibel dengan overlay video '
          '(canvas lebih besar dari frame) — fallback ke drawtext.',
        );
        return null;
      }

      final metrics = layout.computeMetrics(
        photoWidth: canvasWidth.toDouble(),
        photoHeight: canvasHeight.toDouble(),
        data: data,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      // HANYA GAMBAR ELEMEN WATERMARK TANPA FOTO LATAR
      layout.paintWatermarkOnly(
        canvas: canvas,
        metrics: metrics,
        logoImage: logoImage,
        data: data,
      );

      final picture = recorder.endRecording();
      outputImage = await picture.toImage(
        metrics.canvasWidth.round(),
        metrics.canvasHeight.round(),
      );
      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('❌ Gagal render overlay PNG: $e');
      return null;
    } finally {
      // ✅ Dijamin dispose apa pun yang sempat ter-load, termasuk di jalur
      // exception (mis. paintWatermarkOnly gagal) — sebelumnya logoImage
      // hanya di-dispose di jalur sukses sehingga bocor di jalur gagal.
      logoCodec?.dispose();
      logoImage?.dispose();
      outputImage?.dispose();
    }
  }

  // ─── LOAD LOGO ──────────────────────────────────────────
  static Future<ui.Codec?> _loadLogoCodec(
    String logoPath, {
    required int targetWidth,
  }) async {
    try {
      final logoFile = File(logoPath);
      if (!await logoFile.exists()) return null;

      final logoBytes = await logoFile.readAsBytes();
      final logoTargetWidth = (targetWidth * 0.15).round().clamp(40, 200);
      return await ui.instantiateImageCodec(
        logoBytes,
        targetWidth: logoTargetWidth,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error memuat logo: $e');
      return null;
    }
  }
}
