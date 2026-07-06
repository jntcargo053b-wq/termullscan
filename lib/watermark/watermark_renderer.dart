// ============================================================
// lib/watermark/watermark_renderer.dart (FIXED)
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

class _CachedOverlay {
  final Uint8List pngBytes;
  final int offsetX;
  final int offsetY;
  final int width;
  final int height;
  _CachedOverlay({required this.pngBytes, required this.offsetX, required this.offsetY, required this.width, required this.height});
}

class WatermarkRenderer {
  static final Map<String, ui.Image> _logoCache = {};
  static final Map<String, _CachedOverlay> _overlayCache = {};
  static const int _maxCacheSize = 30;

  // ... (render untuk foto tetap sama) ...

  // ─── RENDER OVERLAY VIDEO (FULL-FRAME, CACHED) ──────────────
  static Future<(Uint8List?, int, int)?> renderVideoOverlaySmallPng({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    final cacheKey = _buildCacheKey(outW: outW, outH: outH, settings: settings, entry: entry);

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

      // ✅ PERBAIKAN: gunakan placeholder abu-abu, bukan transparan
      placeholderImage = await _createPlaceholderImage(outW, outH);

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, photoWidth, photoHeight));

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

      // ✅ DEBUG: simpan ke file sementara
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

  // ─── BUILD CACHE KEY (DENGAN FONT FAMILY) ──────────────────
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
      settings.fontFamily, // ← tambahkan
      settings.logoPath ?? '',
      settings.position.name,
      settings.videoResolution.name, // ← tambahkan
    ];
    return parts.join('|');
  }

  // ─── BUAT GAMBAR PLACEHOLDER (ABU-ABU) ─────────────────────
  static Future<ui.Image> _createPlaceholderImage(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF1A1A1A),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }

  // ─── LOAD LOGO (sama seperti sebelumnya) ────────────────────
  static Future<ui.Image?> _loadLogoWithCache(String logoPath, {required int targetWidth}) async {
    final cacheKey = '${logoPath}_$targetWidth';
    if (_logoCache.containsKey(cacheKey)) return _logoCache[cacheKey];
    try {
      final logoFile = File(logoPath);
      if (!await logoFile.exists()) return null;
      final logoBytes = await logoFile.readAsBytes();
      final logoTargetWidth = (targetWidth * 0.15).round().clamp(40, 200);
      final codec = await ui.instantiateImageCodec(logoBytes, targetWidth: logoTargetWidth);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (frame.image != null) {
        _logoCache[cacheKey] = frame.image;
        return frame.image;
      }
    } catch (e) {
      debugPrint('⚠️ Error memuat logo: $e');
    }
    return null;
  }
}
