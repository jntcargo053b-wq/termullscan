// ============================================================
// lib/watermark/watermark_renderer.dart (ISOLATE VERSION)
// ============================================================
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui; // hanya untuk Color (dipakai di isolate? Tidak – hapus nanti)
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../models/scan_entry.dart';
import 'models/watermark_data.dart';
import 'watermark_style.dart';
import 'watermark_factory.dart';
import 'watermark_settings.dart';

class WatermarkRenderer {
  /// Render watermark ke file output – sekarang via compute().
  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    // Baca file sumber di UI thread (I/O ringan)
    final srcFile = File(imagePath);
    if (!await srcFile.exists()) {
      debugPrint('❌ File tidak ditemukan: $imagePath');
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

    // Data font (cukup satu saja, pilih berdasarkan fontSize)
    final fontPath = _getFontPath(settings.fontFamily);
    Uint8List? fontBytes;
    if (fontPath != null) {
      final fontFile = File(fontPath);
      if (await fontFile.exists()) {
        fontBytes = await fontFile.readAsBytes();
      }
    }

    final args = _RenderArgs(
      imageBytes: imageBytes,
      logoBytes: logoBytes,
      fontBytes: fontBytes,
      settings: settings,
      entry: entry,
    );

    // Jalankan rendering di isolate
    final resultBytes = await compute(_renderInIsolate, args);
    if (resultBytes == null) return null;

    final outFile = File(outputPath);
    await outFile.writeAsBytes(resultBytes);
    return outputPath;
  }

  static String? _getFontPath(String fontFamily) {
    // Sesuaikan path dengan struktur assets Anda
    switch (fontFamily) {
      case 'Roboto':
        return 'assets/fonts/Roboto-VariableFont_wdth,wght.ttf';
      case 'Inter':
        return 'assets/fonts/Inter-VariableFont_opsz,wght.ttf';
      case 'Montserrat':
        return 'assets/fonts/Montserrat-VariableFont_wght.ttf';
      case 'Poppins':
        return 'assets/fonts/Poppins-Regular.ttf';
      default:
        return null; // fallback: tidak render teks
    }
  }
}

// ─── Argumen yang dikirim ke isolate ────────────────────────
class _RenderArgs {
  final Uint8List imageBytes;
  final Uint8List? logoBytes;
  final Uint8List? fontBytes;
  final WatermarkSettings settings;
  final ScanEntry entry;
  const _RenderArgs({
    required this.imageBytes,
    this.logoBytes,
    this.fontBytes,
    required this.settings,
    required this.entry,
  });
}

// ─── Fungsi top‑level untuk isolate ─────────────────────────
Uint8List? _renderInIsolate(_RenderArgs args) {
  try {
    // Decode gambar sumber
    final src = img.decodeImage(args.imageBytes);
    if (src == null) return null;

    // Decode logo jika ada
    img.Image? logo;
    if (args.logoBytes != null) {
      logo = img.decodeImage(args.logoBytes!);
      if (logo != null && logo.width > 200) {
        logo = img.copyResize(logo, width: 200);
      }
    }

    // Buat font bitmap dari .ttf
    img.BitmapFont? font;
    if (args.fontBytes != null) {
      font = img.BitmapFont.fromTrueType(
        args.fontBytes!,
        fontSize: args.settings.fontSize.toInt(),
      );
    }

    // Siapkan teks
    final barcode = args.entry.value;
    final operator = args.settings.operatorName;
    final timestamp = args.entry.timestamp.toIso8601String().substring(0, 19);
    final lines = <String>[
      barcode,
      if (operator.isNotEmpty) 'Operator: $operator',
      timestamp,
      if (args.entry.locationName != null) args.entry.locationName!,
    ];

    // Hitung ukuran teks
    int textBlockWidth = 0;
    int lineHeight = 30; // default
    if (font != null) {
      lineHeight = font.lineHeight + 6;
      for (final line in lines) {
        int w = 0;
        for (final ch in line.codeUnits) {
          final glyph = font.glyphs[ch];
          w += glyph?.xadvance ?? 10;
        }
        if (w > textBlockWidth) textBlockWidth = w;
      }
    }
    final textBlockHeight = lines.length * lineHeight;

    // Ukuran logo
    int logoW = 0, logoH = 0;
    if (logo != null) {
      logoW = logo.width;
      logoH = logo.height;
    }

    final padding = 20;
    final spacing = 10;
    final boxW = textBlockWidth + padding * 2 + (logo != null ? logoW + spacing : 0);
    final boxH = (textBlockHeight > logoH ? textBlockHeight : logoH) + padding * 2;

    // Posisi watermark
    final pos = _calcPosition(
      imageW: src.width,
      imageH: src.height,
      boxW: boxW,
      boxH: boxH,
      position: args.settings.position,
      margin: 20,
    );

    // Gambar background semi‑transparan
    final bgAlpha = (args.settings.backgroundOpacity * 255).round();
    img.fillRect(
      src,
      x: pos.dx,
      y: pos.dy,
      width: boxW,
      height: boxH,
      color: img.ColorRgba8(0, 0, 0, bgAlpha),
    );

    // Gambar logo
    int textStartX = pos.dx + padding;
    if (logo != null) {
      final logoY = pos.dy + (boxH - logoH) ~/ 2;
      img.compositeImage(src, logo, dstX: textStartX, dstY: logoY);
      textStartX += logoW + spacing;
    }

    // Gambar teks
    if (font != null) {
      final textColor = img.ColorRgb8(255, 255, 255);
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final textY = pos.dy + padding + i * lineHeight + font.ascent;
        img.drawString(src, line, font: font, x: textStartX, y: textY, color: textColor);
      }
    }

    // Encode hasil
    return img.encodePng(src);
  } catch (e) {
    debugPrint('❌ Isolate error: $e');
    return null;
  }
}

// ─── Helper posisi ──────────────────────────────────────────
class _Pos { final int dx, dy; const _Pos(this.dx, this.dy); }

_Pos _calcPosition({
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
      x = margin; y = margin;
      break;
    case WatermarkPosition.topRight:
      x = imageW - boxW - margin;
      y = margin;
      break;
    case WatermarkPosition.bottomLeft:
      x = margin;
      y = imageH - boxH - margin;
      break;
    case WatermarkPosition.bottomRight:
    default:
      x = imageW - boxW - margin;
      y = imageH - boxH - margin;
  }
  x = x.clamp(0, imageW - boxW);
  y = y.clamp(0, imageH - boxH);
  return _Pos(x, y);
}
