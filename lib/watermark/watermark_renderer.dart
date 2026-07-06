// ============================================================
// lib/watermark/watermark_renderer.dart
// ============================================================
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import '../models/scan_entry.dart';
import 'models/watermark_data.dart';
import 'theme/watermark_theme.dart';
import 'watermark_style.dart';
import 'watermark_factory.dart';
import 'watermark_settings.dart';

// ─── DATA CLASS UNTUK CACHE OVERLAY ──────────────────────────
class _CachedOverlay {
  final Uint8List pngBytes;
  final int offsetX;
  final int offsetY;
  final int width;
  final int height;

  _CachedOverlay({
    required this.pngBytes,
    required this.offsetX,
    required this.offsetY,
    required this.width,
    required this.height,
  });
}

class WatermarkRenderer {
  static const Set<WatermarkStyle> _stylesWithRealRenderer = {
    WatermarkStyle.minimal,
    WatermarkStyle.professional,
    WatermarkStyle.polaroid,
    WatermarkStyle.stamp,
    WatermarkStyle.timestamp,
  };

  // ─── CACHE LOGO (ui.Image) ──────────────────────────────────
  static final Map<String, ui.Image> _logoCache = {};

  // ─── CACHE OVERLAY (PNG + posisi) ──────────────────────────
  static final Map<String, _CachedOverlay> _overlayCache = {};
  static const int _maxCacheSize = 30;

  // ─── RENDER UNTUK FOTO ──────────────────────────────────────
  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    ui.Image? srcImage;
    ui.Image? logoImage;
    ui.Image? outputImage;
    ui.Picture? picture;
    ui.Codec? codec;

    try {
      // ─── 1. Baca & decode foto asli ───────────────────────
      final imageFile = File(imagePath);
      if (!await imageFile.exists()) {
        debugPrint('❌ WatermarkRenderer.render: file tidak ditemukan: $imagePath');
        return null;
      }

      final imageBytes = await imageFile.readAsBytes();
      codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      srcImage = frame.image;

      final photoWidth = srcImage.width.toDouble();
      final photoHeight = srcImage.height.toDouble();

      // ─── 2. Load logo (dengan cache) bila diaktifkan ──────
      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoImage = await _loadLogoWithCache(settings.logoPath!, targetWidth: srcImage.width);
      }

      // ─── 3. Siapkan data & theme ───────────────────────────
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

      final baseSize = photoWidth < photoHeight ? photoWidth : photoHeight;
      final theme = WatermarkTheme.of(
        style: settings.style,
        data: data,
        baseSize: baseSize,
      );

      // ─── 4. Hitung metrics layout ──────────────────────────
      final layout = WatermarkFactory.create(settings.style);
      final metrics = layout.computeMetrics(
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        data: data,
        theme: theme,
      );

      // ─── 5. Gambar foto asli + watermark di kanvas full-size
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      );

      layout.paintOnCanvas(
        canvas: canvas,
        metrics: metrics,
        srcImage: srcImage,
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        logoImage: logoImage,
        data: data,
        theme: theme,
      );

      picture = recorder.endRecording();

      // ─── 6. Render ke gambar akhir ──────────────────────────
      outputImage = await picture.toImage(
        photoWidth.round(),
        photoHeight.round(),
      );

      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw Exception('Gagal encode PNG hasil watermark');
      }

      // ─── 7. Simpan ke outputPath ────────────────────────────
      final outFile = File(outputPath);
      await outFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);

      if (kDebugMode) {
        debugPrint('✅ Watermark foto tersimpan: $outputPath (${photoWidth.toInt()}x${photoHeight.toInt()})');
      }

      return outputPath;
    } catch (e, stack) {
      if (kDebugMode) debugPrint('❌ Error WatermarkRenderer.render: $e\n$stack');
      return null;
    } finally {
      // ⚠️ logoImage TIDAK di-dispose: gambar itu milik _logoCache dan
      // dipakai ulang untuk foto/video berikutnya.
      srcImage?.dispose();
      outputImage?.dispose();
      picture?.dispose();
      codec?.dispose();
    }
  }

  // ─── LOAD LOGO DENGAN CACHE ─────────────────────────────────
  static Future<ui.Image?> _loadLogoWithCache(
    String logoPath, {
    required int targetWidth,
  }) async {
    final cacheKey = '${logoPath}_$targetWidth';
    if (_logoCache.containsKey(cacheKey)) {
      if (kDebugMode) debugPrint('♻️ Logo from cache');
      return _logoCache[cacheKey];
    }

    try {
      final logoFile = File(logoPath);
      if (!await logoFile.exists()) return null;

      final logoBytes = await logoFile.readAsBytes();
      final logoTargetWidth = (targetWidth * 0.15).round().clamp(40, 200);
      final codec = await ui.instantiateImageCodec(
        logoBytes,
        targetWidth: logoTargetWidth,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();

      if (frame.image != null) {
        _logoCache[cacheKey] = frame.image;
        if (kDebugMode) debugPrint('✅ Logo cached');
        return frame.image;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error memuat logo: $e');
    }
    return null;
  }

  // ─── RENDER OVERLAY VIDEO (FULL-FRAME, CACHED) ──────────────
  static Future<(Uint8List?, int, int)?> renderVideoOverlaySmallPng({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    // ─── 1. Buat cache key ──────────────────────────────────
    final cacheKey = _buildCacheKey(
      outW: outW,
      outH: outH,
      settings: settings,
      entry: entry,
    );

    // ─── 2. Cek cache ──────────────────────────────────────
    if (_overlayCache.containsKey(cacheKey)) {
      final cached = _overlayCache[cacheKey]!;
      if (kDebugMode) debugPrint('♻️ Overlay from cache (${cached.width}x${cached.height})');
      return (cached.pngBytes, cached.offsetX, cached.offsetY);
    }

    ui.Image? logoImage;
    ui.Image? outputImage;
    ui.Image? transparentSrc;
    ui.Picture? picture;

    try {
      if (outW <= 0 || outH <= 0) {
        debugPrint('❌ renderVideoOverlaySmallPng: ukuran tidak valid');
        return null;
      }

      // ─── 3. Load logo (dengan cache) ──────────────────────
      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoImage = await _loadLogoWithCache(settings.logoPath!, targetWidth: outW);
      }

      // ─── 4. Siapkan data & theme ──────────────────────────
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

      final photoWidth = outW.toDouble();
      final photoHeight = outH.toDouble();
      final baseSize = photoWidth < photoHeight ? photoWidth : photoHeight;
      final theme = WatermarkTheme.of(
        style: settings.style,
        data: data,
        baseSize: baseSize,
      );

      // ─── 5. Buat gambar transparan untuk srcImage ────────
      // (Layout mungkin memerlukan srcImage untuk background, kita berikan
      //  gambar transparan ukuran penuh agar tidak mempengaruhi overlay)
      transparentSrc = await _createTransparentImage(outW, outH);

      // ─── 6. Kanvas UKURAN PENUH (outW x outH) ─────────────
      // ⚠️ PENTING: sebelumnya di sini dipakai perkiraan "kotak konten
      // kecil" (_calculateContentSize/_calculatePosition) yang HANYA
      // cocok untuk layout berbentuk kartu kecil di pojok (mis.
      // Timestamp). Layout lain (Minimal/Professional = pita
      // full-width; Polaroid = bingkai foto; Stamp = badge melingkar)
      // punya geometri sendiri yang dihitung oleh computeMetrics()
      // masing-masing dan TIDAK sama dengan kotak kecil itu — akibatnya
      // watermark digambar di luar area kanvas kecil yang direkam
      // (ter-crop total) dan hasilnya transparan / tidak terlihat sama
      // sekali di video untuk gaya selain Timestamp.
      //
      // Perbaikan: gambar overlay di kanvas SELEBAR FRAME VIDEO (persis
      // seperti pipeline foto di WatermarkRenderer.render() di atas),
      // supaya computeMetrics()/paintOnCanvas() tiap layout menghasilkan
      // posisi & ukuran yang identik dengan hasil di foto. Offset overlay
      // ke FFmpeg jadi selalu (0, 0) karena PNG sudah seukuran frame.
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      );

      // ─── 7. Gambar layout (sama seperti pipeline foto) ────
      final layout = WatermarkFactory.create(settings.style);
      final metrics = layout.computeMetrics(
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        data: data,
        theme: theme,
      );

      layout.paintOnCanvas(
        canvas: canvas,
        metrics: metrics,
        srcImage: transparentSrc,
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        logoImage: logoImage,
        data: data,
        theme: theme,
      );

      picture = recorder.endRecording();

      // ─── 8. Render ke PNG seukuran frame ──────────────────
      outputImage = await picture.toImage(outW, outH);

      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw Exception('Gagal encode PNG');
      }

      final pngBytes = byteData.buffer.asUint8List();
      const offsetX = 0;
      const offsetY = 0;

      // ─── 9. Simpan ke cache ──────────────────────────────
      final cached = _CachedOverlay(
        pngBytes: pngBytes,
        offsetX: offsetX,
        offsetY: offsetY,
        width: outW,
        height: outH,
      );

      _overlayCache[cacheKey] = cached;

      // Jaga ukuran cache
      if (_overlayCache.length > _maxCacheSize) {
        final keys = _overlayCache.keys.toList();
        for (int i = 0; i < keys.length - _maxCacheSize; i++) {
          _overlayCache.remove(keys[i]);
        }
      }

      if (kDebugMode) {
        debugPrint('✅ Overlay PNG full-frame: ${outW}x$outH, style=${settings.style.name}, ${pngBytes.length} bytes');
        debugPrint('   Cache size: ${_overlayCache.length} entries');
      }

      return (pngBytes, offsetX, offsetY);
    } catch (e, stack) {
      if (kDebugMode) debugPrint('❌ Error renderVideoOverlaySmallPng: $e\n$stack');
      return null;
    } finally {
      // ⚠️ logoImage TIDAK di-dispose: gambar itu milik _logoCache dan
      // dipakai ulang untuk frame/foto berikutnya.
      transparentSrc?.dispose();
      outputImage?.dispose();
      picture?.dispose();
    }
  }

  // ─── BUILD CACHE KEY ────────────────────────────────────────
  static String _buildCacheKey({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) {
    final parts = [
      outW,
      outH,
      settings.style.name,
      settings.companyName,
      settings.operatorName,
      entry.timestamp.toIso8601String(),
      entry.value,
      entry.barcodeFormat,
      entry.locationName ?? '',
      settings.fontSize,
      settings.backgroundOpacity,
      settings.fontFamily,
      settings.logoPath ?? '',
      settings.position.name,
    ];
    return parts.join('|');
  }

  // ─── VERSI LAMA (Fullscreen) untuk kompatibilitas ─────────
  static Future<Uint8List?> renderVideoOverlayPng({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    final result = await renderVideoOverlaySmallPng(
      outW: outW,
      outH: outH,
      settings: settings,
      entry: entry,
    );
    return result?.$1;
  }

  // ─── BUAT GAMBAR TRANSPARAN ─────────────────────────────────
  static Future<ui.Image> _createTransparentImage(int width, int height) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder); // tidak menggambar apa pun → transparan
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }
}
