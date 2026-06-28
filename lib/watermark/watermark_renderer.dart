// ============================================================
// lib/watermark/watermark_renderer.dart
// ============================================================
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

// ---- font bawaan dari package:image (ukuran terbatas) ----
import 'package:image/fonts/arial_14.dart' as arial_14;
import 'package:image/fonts/arial_24.dart' as arial_24;
import 'package:image/fonts/arial_48.dart' as arial_48;

import '../models/scan_entry.dart';
import 'watermark_style.dart';
import 'watermark_settings.dart';

/// Objek data yang dikirim ke isolate.
class _RenderArgs {
  final Uint8List imageBytes;
  final Uint8List? logoBytes;
  final WatermarkSettings settings;
  final ScanEntry entry;
  const _RenderArgs({
    required this.imageBytes,
    this.logoBytes,
    required this.settings,
    required this.entry,
  });
}

class WatermarkRenderer {
  static const Set<WatermarkStyle> _stylesWithRealRenderer = {
    WatermarkStyle.minimal,
    WatermarkStyle.professional,
    WatermarkStyle.polaroid,
    WatermarkStyle.stamp,
  };

  /// Render watermark ke file output.
  /// Berjalan **di background isolate** – aman untuk batch besar.
  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    try {
      // Baca file sumber (I/O ringan di UI thread)
      final srcFile = File(imagePath);
      if (!await srcFile.exists()) {
        if (kDebugMode) debugPrint('❌ File tidak ditemukan: $imagePath');
        return null;
      }
      final imageBytes = await srcFile.readAsBytes();

      Uint8List? logoBytes;
      if (settings.hasLogo && settings.logoPath != null) {
        final logoFile = File(settings.logoPath!);
        if (await logoFile.exists()) {
          logoBytes = await logoFile.readAsBytes();
        }
      }

      // Jalankan seluruh rendering di isolate
      final outputBytes = await compute(
        _renderInIsolate,
        _RenderArgs(
          imageBytes: imageBytes,
          logoBytes: logoBytes,
          settings: settings,
          entry: entry,
        ),
      );

      // Tulis hasil ke disk
      final outFile = File(outputPath);
      await outFile.writeAsBytes(outputBytes);

      if (kDebugMode) {
        debugPrint('✅ Watermark berhasil disimpan: $outputPath');
      }
      return outputPath;
    } catch (e, stack) {
      if (kDebugMode) debugPrint('❌ Render error: $e\n$stack');
      return null;
    }
  }
}

// ======================================================================
// Fungsi top‑level (bebas) yang akan dijalankan di isolate terpisah
// ======================================================================
Uint8List _renderInIsolate(_RenderArgs args) {
  // 1. Decode gambar sumber
  final src = img.decodeImage(args.imageBytes);
  if (src == null) throw Exception('Gagal decode gambar sumber');

  // 2. Decode logo (jika ada)
  img.Image? logo;
  if (args.logoBytes != null) {
    logo = img.decodeImage(args.logoBytes!);
  }

  // 3. Siapkan teks watermark
  final barcode = args.entry.value;
  final operator = args.settings.operatorName;
  final timestamp = args.entry.timestamp.toIso8601String().substring(0, 19);

  // Daftar baris teks (bisa disesuaikan per style)
  final lines = <String>[];
  if (args.settings.style == WatermarkStyle.minimal) {
    lines.add('$barcode');
    lines.add(operator);
  } else {
    lines.add('$barcode');
    lines.add('Operator: $operator');
    lines.add(timestamp);
    if (args.entry.locationName != null && args.entry.locationName!.isNotEmpty) {
      lines.add(args.entry.locationName!);
    }
  }

  // 4. Pilih font bitmap berdasarkan fontSize
  final font = _selectFont(args.settings.fontSize);

  // 5. Hitung ukuran area teks
  final textWidths = lines.map((l) => _measureText(l, font)).toList();
  final textBlockWidth = textWidths.reduce((a, b) => a > b ? a : b);
  final lineHeight = font.lineHeight + 4; // spasi antar baris
  final textBlockHeight = lines.length * lineHeight;

  // 6. Ukuran logo
  int logoWidth = 0, logoHeight = 0;
  if (logo != null) {
    // logo di-resize max 120px lebar
    final maxLogoW = 120;
    if (logo.width > maxLogoW) {
      logo = img.copyResize(logo, width: maxLogoW);
    }
    logoWidth = logo.width;
    logoHeight = logo.height;
  }

  // 7. Hitung total dimensi watermark box
  final padding = 20;
  final spacing = 10; // antara logo & teks (jika ada)
  final boxWidth = textBlockWidth + padding * 2 + (logo != null ? logoWidth + spacing : 0);
  final boxHeight = (textBlockHeight > logoHeight ? textBlockHeight : logoHeight) + padding * 2;

  // 8. Tentukan posisi di gambar
  final pos = _calculatePosition(
    imageW: src.width,
    imageH: src.height,
    boxW: boxWidth,
    boxH: boxHeight,
    position: args.settings.position,
    margin: 20,
  );

  // 9. Gambar background semi-transparan
  final bgColor = _colorFromOpacity(args.settings.backgroundOpacity);
  img.fillRect(src, x: pos.dx, y: pos.dy, width: boxWidth, height: boxHeight, color: bgColor);

  // 10. Gambar logo (jika ada)
  int textStartX = pos.dx + padding;
  if (logo != null) {
    final logoY = pos.dy + (boxHeight - logoHeight) ~/ 2;
    img.compositeImage(src, logo, dstX: textStartX, dstY: logoY);
    textStartX += logoWidth + spacing;
  }

  // 11. Gambar teks
  final textColor = img.ColorRgb8(255, 255, 255); // putih
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    final textY = pos.dy + padding + i * lineHeight + font.ascent;
    img.drawString(src, line, font: font, x: textStartX, y: textY, color: textColor);
  }

  // 12. Encode hasil
  return img.encodePng(src);
}

// ====================== Helper Functions ======================

/// Pilih font bitmap berdasarkan fontSize (14/24/48). Bisa diperluas.
img.BitmapFont _selectFont(double fontSize) {
  if (fontSize >= 36) return arial_48.font;
  if (fontSize >= 20) return arial_24.font;
  return arial_14.font;
}

/// Hitung lebar string dengan font tertentu.
int _measureText(String text, img.BitmapFont font) {
  int w = 0;
  for (int i = 0; i < text.length; i++) {
    final ch = text.codeUnitAt(i);
    final glyph = font.glyphs[ch] ?? font.glyphs['?'.codeUnitAt(0)];
    w += glyph?.xadvance ?? font.lineHeight ~/ 2;
  }
  return w;
}

/// Hasil koordinat
class _Pos { final int dx, dy; const _Pos(this.dx, this.dy); }

/// Hitung posisi kiri atas watermark box.
_Pos _calculatePosition({
  required int imageW,
  required int imageH,
  required int boxW,
  required int boxH,
  required WatermarkPosition position,
  required int margin,
}) {
  int x, y;
  switch (position) {
    case WatermarkPosition.topLeft:
      x = margin;
      y = margin;
      break;
    case WatermarkPosition.topCenter:
      x = (imageW - boxW) ~/ 2;
      y = margin;
      break;
    case WatermarkPosition.topRight:
      x = imageW - boxW - margin;
      y = margin;
      break;
    case WatermarkPosition.center:
      x = (imageW - boxW) ~/ 2;
      y = (imageH - boxH) ~/ 2;
      break;
    case WatermarkPosition.bottomLeft:
      x = margin;
      y = imageH - boxH - margin;
      break;
    case WatermarkPosition.bottomCenter:
      x = (imageW - boxW) ~/ 2;
      y = imageH - boxH - margin;
      break;
    case WatermarkPosition.bottomRight:
    default:
      x = imageW - boxW - margin;
      y = imageH - boxH - margin;
  }
  // Pastikan tidak keluar batas (basic clamp)
  x = x.clamp(0, imageW - boxW);
  y = y.clamp(0, imageH - boxH);
  return _Pos(x, y);
}

/// Konversi opacity (0.0 - 1.0) ke warna RGBA hitam semi-transparan.
int _colorFromOpacity(double opacity) {
  final alpha = (opacity * 255).round().clamp(0, 255);
  return img.ColorRgba8(0, 0, 0, alpha);
}
