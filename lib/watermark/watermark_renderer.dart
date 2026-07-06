// ============================================================
// lib/watermark/watermark_renderer.dart
// ============================================================
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
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

  // ─── RENDER UNTUK FOTO (DIPERTAHANKAN) ─────────────────────
  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    if (kDebugMode) {
      debugPrint('🎯 WATERMARK RENDER START');
      debugPrint('  Style: ${settings.style.name}');
    }

    ui.Image? srcImage;
    ui.Image? logoImage;
    ui.Codec? codec;
    ui.Image? outputImage;

    try {
      final file = File(imagePath);
      if (!await file.exists()) {
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

      // Gunakan cache logo
      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoImage = await _loadLogoWithCache(settings.logoPath!, targetWidth: 1600);
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

      final baseSize = photoWidth < photoHeight ? photoWidth : photoHeight;
      final theme = WatermarkTheme.of(
        style: settings.style,
        data: data,
        baseSize: baseSize,
      );

      final metrics = layout.computeMetrics(
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        data: data,
        theme: theme,
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
        theme: theme,
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
        debugPrint('❌ Gagal encode PNG');
        return null;
      }

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(byteData.buffer.asUint8List());

      if (kDebugMode) debugPrint('✅ Watermark saved: $outputPath');
      return outputPath;
    } catch (e, stack) {
      if (kDebugMode) debugPrint('❌ Error: $e\n$stack');
      return null;
    } finally {
      codec?.dispose();
      srcImage?.dispose();
      logoImage?.dispose();
      outputImage?.dispose();
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

  // ─── HITUNG UKURAN WATERMARK (TANPA GAMBAR FULL HD) ──────
  static (int width, int height) _calculateContentSize({
    required WatermarkData data,
    required WatermarkTheme theme,
    required ui.Image? logoImage,
    required WatermarkStyle style,
    required double photoWidth,
    required double photoHeight,
  }) {
    // Gunakan TextPainter untuk mengukur teks
    final textStyle = theme.textStyle;
    final double padding = theme.padding;
    final double spacing = 4.0;

    // Kumpulkan semua teks yang akan ditampilkan
    final List<String> lines = [];

    // Timestamp
    final timestampStr = _formatTimestamp(data.timestamp);
    lines.add(timestampStr);

    // Operator
    if (data.operatorName.isNotEmpty) {
      lines.add('Operator: ${data.operatorName}');
    }

    // Company
    if (data.companyName.isNotEmpty) {
      lines.add(data.companyName);
    }

    // Barcode
    if (data.barcodeValue.isNotEmpty) {
      lines.add('${data.barcodeFormat}: ${data.barcodeValue}');
    }

    // Lokasi
    if (data.locationName != null && data.locationName!.isNotEmpty) {
      lines.add('📍 ${data.locationName}');
    }

    // GPS
    if (data.latitude != null && data.longitude != null) {
      final lat = data.latitude!.toStringAsFixed(6);
      final lng = data.longitude!.toStringAsFixed(6);
      lines.add('🌐 $lat, $lng');
    }

    // Ukur setiap baris
    double maxLineWidth = 0;
    double totalTextHeight = 0;

    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    );

    for (int i = 0; i < lines.length; i++) {
      painter.text = TextSpan(text: lines[i], style: textStyle);
      painter.layout(maxWidth: photoWidth * 0.9); // batasi agar tidak overflow

      final lineWidth = painter.width;
      if (lineWidth > maxLineWidth) maxLineWidth = lineWidth;

      totalTextHeight += painter.height;
      if (i < lines.length - 1) totalTextHeight += spacing;
    }

    // Lebar watermark = max lebar teks + padding + logo
    double logoWidth = 0;
    double logoHeight = 0;
    if (logoImage != null) {
      final logoMaxSize = 60.0;
      final scale = logoMaxSize / (logoImage.width > logoImage.height
          ? logoImage.width
          : logoImage.height);
      logoWidth = logoImage.width * scale;
      logoHeight = logoImage.height * scale;
    }

    final double contentWidth = maxLineWidth + (padding * 2) + (logoImage != null ? logoWidth + 12 : 0);
    final double contentHeight = (logoImage != null && logoHeight > totalTextHeight)
        ? logoHeight + (padding * 2)
        : totalTextHeight + (padding * 2);

    // Pastikan minimal 80x40 agar tidak terlalu kecil
    final int finalWidth = (contentWidth < 80 ? 80 : contentWidth).ceil();
    final int finalHeight = (contentHeight < 40 ? 40 : contentHeight).ceil();

    if (kDebugMode) {
      debugPrint('📐 Content size: ${finalWidth}x$finalHeight (text lines: ${lines.length})');
    }

    return (finalWidth, finalHeight);
  }

  static String _formatTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  // ─── HITUNG POSISI (offsetX, offsetY) ──────────────────────
  static (int x, int y) _calculatePosition({
    required int contentWidth,
    required int contentHeight,
    required double photoWidth,
    required double photoHeight,
    required WatermarkPosition position,
    required double padding,
  }) {
    final margin = (padding * 1.5).ceil();

    int x = 0, y = 0;

    switch (position) {
      case WatermarkPosition.bottomRight:
        x = photoWidth.toInt() - contentWidth - margin;
        y = photoHeight.toInt() - contentHeight - margin;
        break;
      case WatermarkPosition.bottomLeft:
        x = margin;
        y = photoHeight.toInt() - contentHeight - margin;
        break;
      case WatermarkPosition.topRight:
        x = photoWidth.toInt() - contentWidth - margin;
        y = margin;
        break;
      case WatermarkPosition.topLeft:
        x = margin;
        y = margin;
        break;
    }

    // Pastikan tidak negatif
    x = x.clamp(0, photoWidth.toInt() - contentWidth);
    y = y.clamp(0, photoHeight.toInt() - contentHeight);

    return (x, y);
  }

  // ─── RENDER OVERLAY VIDEO (SMALL, CACHED) ──────────────────
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

      // ─── 5. Hitung ukuran watermark ──────────────────────
      final (contentW, contentH) = _calculateContentSize(
        data: data,
        theme: theme,
        logoImage: logoImage,
        style: settings.style,
        photoWidth: photoWidth,
        photoHeight: photoHeight,
      );

      // ─── 6. Hitung posisi offset ──────────────────────────
      final (offsetX, offsetY) = _calculatePosition(
        contentWidth: contentW,
        contentHeight: contentH,
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        position: settings.position,
        padding: theme.padding,
      );

      if (kDebugMode) {
        debugPrint('🎯 Content: ${contentW}x$contentH, Offset: ($offsetX, $offsetY)');
      }

      // ─── 7. Buat kanvas SESUAI UKURAN WATERMARK ──────────
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      // Translasi agar layout (yang menggambar relatif terhadap full photo)
      // sekarang menggambar di area kecil kita.
      canvas.translate(-offsetX.toDouble(), -offsetY.toDouble());

      // Potong agar tidak meluber
      canvas.clipRect(ui.Rect.fromLTWH(
        offsetX.toDouble(),
        offsetY.toDouble(),
        contentW.toDouble(),
        contentH.toDouble(),
      ));

      // ─── 8. Gunakan layout yang sudah ada untuk menggambar ──
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
        srcImage: null, // Tidak perlu foto asli
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        logoImage: logoImage,
        data: data,
        theme: theme,
      );

      picture = recorder.endRecording();

      // ─── 9. Render ke PNG ukuran kecil ────────────────────
      outputImage = await picture.toImage(contentW, contentH);
      if (outputImage == null) {
        throw Exception('Gagal membuat ui.Image kecil');
      }

      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw Exception('Gagal encode PNG');
      }

      final pngBytes = byteData.buffer.asUint8List();

      // ─── 10. Simpan ke cache ──────────────────────────────
      final cached = _CachedOverlay(
        pngBytes: pngBytes,
        offsetX: offsetX,
        offsetY: offsetY,
        width: contentW,
        height: contentH,
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
        debugPrint('✅ Overlay PNG small: ${contentW}x$contentH, pos=($offsetX,$offsetY), ${pngBytes.length} bytes');
        debugPrint('   Cache size: ${_overlayCache.length} entries');
      }

      return (pngBytes, offsetX, offsetY);
    } catch (e, stack) {
      if (kDebugMode) debugPrint('❌ Error renderVideoOverlaySmallPng: $e\n$stack');
      return null;
    } finally {
      logoImage?.dispose();
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
  // Tetap dipertahankan, tapi internal memanggil yang baru
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
}
