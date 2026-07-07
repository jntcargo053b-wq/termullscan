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
    // ... (kode ini tetap sama, tidak diubah) ...
  }

  // ─── RENDER OVERLAY VIDEO (FULL-FRAME, CACHED) ──────────────
  static Future<(Uint8List?, int, int)?> renderVideoOverlaySmallPng({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    // ... (kode ini tetap sama, tidak diubah) ...
    // Hanya fungsi _createPlaceholderImage yang diubah
  }

  // ─── BUILD CACHE KEY ──────────────────────────────────────
  static String _buildCacheKey({...}) { /* ... */ }

  // ─── BUAT GAMBAR PLACEHOLDER (TRANSPARAN) ─────────────────────
  static Future<ui.Image> _createPlaceholderImage(int width, int height) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder); // tidak menggambar → transparan
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }

  // ─── LOAD LOGO DENGAN CACHE ─────────────────────────────────
  static Future<ui.Image?> _loadLogoWithCache(...) { /* ... */ }
}
