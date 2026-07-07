// lib/watermark/watermark_renderer.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/scan_entry.dart';
import 'models/watermark_data.dart';
import 'theme/watermark_theme.dart';
import 'watermark_style.dart';
import 'watermark_factory.dart';
import 'watermark_settings.dart';

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
  static final Map<String, ui.Image> _logoCache = {};
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

      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoImage = await _loadLogoWithCache(settings.logoPath!, targetWidth: srcImage.width);
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

      final baseSize = photoWidth < photoHeight ? photoWidth : photoHeight;
      final theme = WatermarkTheme.of(style: settings.style, data: data, baseSize: baseSize);

      final layout = WatermarkFactory.create(settings.style);
      final metrics = layout.computeMetrics(
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        data: data,
        theme: theme,
      );

      // Sebagian besar layout menyamakan canvasWidth/canvasHeight dengan
      // photoWidth/photoHeight, tapi layout seperti Polaroid sengaja
      // memperbesar kanvas untuk bingkai/frame putih di sekeliling foto.
      // Sebelumnya kanvas SELALU dipaksa sebesar foto asli sehingga bingkai
      // itu ikut terpotong — sekarang ukuran final mengikuti kebutuhan
      // masing-masing layout.
      final canvasWidth = metrics.canvasWidth;
      final canvasHeight = metrics.canvasHeight;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, canvasWidth, canvasHeight),
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
      outputImage = await picture.toImage(canvasWidth.round(), canvasHeight.round());

      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw Exception('Gagal encode PNG hasil watermark');
      }

      final outFile = File(outputPath);
      await outFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);

      if (kDebugMode) {
        debugPrint('✅ Watermark foto tersimpan: $outputPath (${canvasWidth.toInt()}x${canvasHeight.toInt()})');
      }

      return outputPath;
    } catch (e, stack) {
      if (kDebugMode) debugPrint('❌ Error WatermarkRenderer.render: $e\n$stack');
      return null;
    } finally {
      srcImage?.dispose();
      outputImage?.dispose();
      picture?.dispose();
      codec?.dispose();
    }
  }

  // ─── RENDER OVERLAY VIDEO (FULL-FRAME, CACHED) ──────────────
  static Future<(Uint8List?, int, int)?> renderVideoOverlaySmallPng({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    final cacheKey = _buildCacheKey(
      outW: outW,
      outH: outH,
      settings: settings,
      entry: entry,
    );

    if (_overlayCache.containsKey(cacheKey)) {
      final cached = _overlayCache[cacheKey]!;
      if (kDebugMode) debugPrint('♻️ Overlay from cache (${cached.width}x${cached.height})');
      return (cached.pngBytes, cached.offsetX, cached.offsetY);
    }

    ui.Image? logoImage;
    ui.Image? outputImage;
    ui.Image? placeholderImage;
    ui.Picture? picture;

    try {
      if (outW <= 0 || outH <= 0) {
        debugPrint('❌ renderVideoOverlaySmallPng: ukuran tidak valid');
        return null;
      }

      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoImage = await _loadLogoWithCache(settings.logoPath!, targetWidth: outW);
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

      final photoWidth = outW.toDouble();
      final photoHeight = outH.toDouble();
      final baseSize = photoWidth < photoHeight ? photoWidth : photoHeight;
      final theme = WatermarkTheme.of(style: settings.style, data: data, baseSize: baseSize);

      // Gunakan placeholder abu-abu agar layout dengan bingkai (seperti Polaroid) terlihat
      placeholderImage = await _createPlaceholderImage(outW, outH);

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, photoWidth, photoHeight),
      );

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
        srcImage: placeholderImage,
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        logoImage: logoImage,
        data: data,
        theme: theme,
      );

      picture = recorder.endRecording();
      outputImage = await picture.toImage(outW, outH);

      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('Gagal encode PNG');

      final pngBytes = byteData.buffer.asUint8List();

      // Debug: simpan ke file sementara
      if (kDebugMode) {
        try {
          final tempDir = await getTemporaryDirectory();
          final debugFile = File('${tempDir.path}/overlay_${DateTime.now().millisecondsSinceEpoch}.png');
          await debugFile.writeAsBytes(pngBytes);
          debugPrint('📸 Overlay PNG debug: ${debugFile.path}');
        } catch (e) {
          debugPrint('⚠️ Gagal simpan debug overlay: $e');
        }
      }

      final cached = _CachedOverlay(
        pngBytes: pngBytes,
        offsetX: 0,
        offsetY: 0,
        width: outW,
        height: outH,
      );
      _overlayCache[cacheKey] = cached;

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

      return (pngBytes, 0, 0);
    } catch (e, stack) {
      if (kDebugMode) debugPrint('❌ Error renderVideoOverlaySmallPng: $e\n$stack');
      return null;
    } finally {
      placeholderImage?.dispose();
      outputImage?.dispose();
      picture?.dispose();
    }
  }

  // ─── BUILD CACHE KEY ──────────────────────────────────────
  static String _buildCacheKey({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) {
    final parts = [
      outW,
      outH,
      settings.revision, // singleton: isi bisa berubah tanpa instance berubah
      settings.style.name,
      settings.companyName,
      settings.operatorName,
      entry.timestamp.toIso8601String(),
      entry.value,
      entry.barcodeFormat,
      entry.locationName ?? '',
      entry.latitude ?? '', // beda koordinat + locationName null harus beda key
      entry.longitude ?? '',
      settings.fontSize,
      settings.backgroundOpacity,
      settings.fontFamily,
      settings.hasLogo, // logo on/off harus beda key walau logoPath sama
      settings.logoPath ?? '',
      settings.position.name,
      settings.videoResolution.name,
    ];
    return parts.join('|');
  }

  // ─── BUAT GAMBAR PLACEHOLDER (ABU-ABU) ─────────────────────
  static Future<ui.Image> _createPlaceholderImage(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF1A1A1A),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
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
      // Cap dinaikkan dari 200 → 480: sekarang ukuran logo di layout benar2
      // proporsional dengan resolusi foto asli (lihat WatermarkTheme.of()),
      // jadi rasternya perlu cukup besar agar tidak buram saat di-upscale
      // ke logoMaxSize pada foto beresolusi tinggi.
      final logoTargetWidth = (targetWidth * 0.15).round().clamp(40, 480);
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
}
