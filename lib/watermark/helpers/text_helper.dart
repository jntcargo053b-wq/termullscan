import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../utils/text_painter_cache.dart';

class TextHelper {
  // ─── FUNGSI ASLI (DIPERBAIKI DENGAN CACHE) ──────────────────

  static double paintText({
    required Canvas canvas,
    required String text,
    required double x,
    required double y,
    required double maxWidth,
    Color color = Colors.black,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    int maxLines = 1,
    TextAlign textAlign = TextAlign.left,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
    List<Shadow>? shadows,
  }) {
    final style = TextPainterCache.getStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
      shadows: shadows,
    );

    final tp = TextPainterCache.getPainter(
      text: text,
      style: style,
      maxWidth: maxWidth,
      maxLines: maxLines,
      textAlign: textAlign,
    );

    tp.paint(canvas, Offset(x, y));
    return tp.height;
  }

  /// Soft drop-shadow tipis
  static List<Shadow> softShadow({double opacity = 0.55, double blur = 3}) =>
      TextPainterCache.getSoftShadow(opacity: opacity, blur: blur);

  // ─── FUNGSI TAMBAHAN (SEMUA PAKAI CACHE) ─────────────────────

  /// Menggambar teks dengan alignment dan mengembalikan Rect posisi teks
  static Rect paintTextWithRect({
    required Canvas canvas,
    required String text,
    required double x,
    required double y,
    required double maxWidth,
    Color color = Colors.black,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    int maxLines = 1,
    TextAlign textAlign = TextAlign.left,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
    List<Shadow>? shadows,
  }) {
    final style = TextPainterCache.getStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
      shadows: shadows,
    );

    final tp = TextPainterCache.getPainter(
      text: text,
      style: style,
      maxWidth: maxWidth,
      maxLines: maxLines,
      textAlign: textAlign,
    );

    double offsetX = x;
    switch (textAlign) {
      case TextAlign.center:
        offsetX = x + (maxWidth - tp.width) / 2;
        break;
      case TextAlign.right:
        offsetX = x + maxWidth - tp.width;
        break;
      default:
        break;
    }

    tp.paint(canvas, Offset(offsetX, y));
    return Rect.fromLTWH(offsetX, y, tp.width, tp.height);
  }

  /// Mengukur teks tanpa menggambar (menggunakan cache)
  static Size measureText({
    required String text,
    required double maxWidth,
    TextStyle? style,
    Color color = Colors.black,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
    int maxLines = 1,
  }) {
    final effectiveStyle = style ?? TextPainterCache.getStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
    );

    final tp = TextPainterCache.getPainter(
      text: text,
      style: effectiveStyle,
      maxWidth: maxWidth,
      maxLines: maxLines,
    );

    return Size(tp.width, tp.height);
  }

  /// Menggambar teks multi-baris (OPTIMASI: satu TextPainter untuk semua baris)
  static double paintMultilineText({
    required Canvas canvas,
    required String text,
    required double x,
    required double y,
    required double maxWidth,
    Color color = Colors.black,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
    double lineSpacing = 1.4,
    List<Shadow>? shadows,
  }) {
    final style = TextPainterCache.getStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
      shadows: shadows,
    );

    // Gunakan multi-line painter
    final tp = TextPainterCache.getMultiLinePainter(
      text: text,
      style: style,
      maxWidth: maxWidth,
    );

    tp.paint(canvas, Offset(x, y));
    return tp.height;
  }

  /// Menggambar teks dengan stroke outline (menggunakan cache)
  static double paintTextWithStroke({
    required Canvas canvas,
    required String text,
    required double x,
    required double y,
    required double maxWidth,
    Color color = Colors.white,
    Color strokeColor = Colors.black,
    double strokeWidth = 2,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    int maxLines = 1,
    TextAlign textAlign = TextAlign.left,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
  }) {
    // Style untuk stroke
    final strokeStyle = TextPainterCache.getStyle(
      color: strokeColor,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = strokeColor,
    );

    final strokeTp = TextPainterCache.getPainter(
      text: text,
      style: strokeStyle,
      maxWidth: maxWidth,
      maxLines: maxLines,
      textAlign: textAlign,
    );
    strokeTp.paint(canvas, Offset(x, y));

    // Gambar teks fill di atasnya
    return paintText(
      canvas: canvas,
      text: text,
      x: x,
      y: y,
      maxWidth: maxWidth,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      maxLines: maxLines,
      textAlign: textAlign,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
    );
  }

  /// Menggambar teks dengan shadow tebal (menggunakan cache)
  static double paintTextWithHeavyShadow({
    required Canvas canvas,
    required String text,
    required double x,
    required double y,
    required double maxWidth,
    Color color = Colors.white,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    int maxLines = 1,
    TextAlign textAlign = TextAlign.left,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
    double shadowBlur = 8,
    double shadowOpacity = 0.8,
  }) {
    final shadows = TextPainterCache.getHeavyShadow(
      opacity: shadowOpacity,
      blur: shadowBlur,
    );

    return paintText(
      canvas: canvas,
      text: text,
      x: x,
      y: y,
      maxWidth: maxWidth,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      maxLines: maxLines,
      textAlign: textAlign,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
      shadows: shadows,
    );
  }

  /// Menghitung jumlah baris (menggunakan cache)
  static int countLines({
    required String text,
    required double maxWidth,
    TextStyle? style,
    Color color = Colors.black,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
  }) {
    final effectiveStyle = style ?? TextPainterCache.getStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
    );

    return TextPainterCache.countLines(
      text: text,
      style: effectiveStyle,
      maxWidth: maxWidth,
    );
  }

  /// Memotong teks agar muat dalam maxWidth
  static String truncateText({
    required String text,
    required double maxWidth,
    TextStyle? style,
    Color color = Colors.black,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
  }) {
    final effectiveStyle = style ?? TextPainterCache.getStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
    );

    if (text.isEmpty) return text;

    // Coba seluruh teks
    final fullTp = TextPainterCache.getPainter(
      text: text,
      style: effectiveStyle,
      maxWidth: maxWidth,
      maxLines: 1,
    );

    if (fullTp.width <= maxWidth) return text;

    // Binary search untuk menemukan potongan yang pas
    int low = 0;
    int high = text.length;
    int bestLength = 0;

    while (low <= high) {
      final mid = (low + high) ~/ 2;
      if (mid == 0) {
        bestLength = 0;
        break;
      }
      final truncated = text.substring(0, mid);
      
      final tp = TextPainterCache.getPainter(
        text: '$truncated…',
        style: effectiveStyle,
        maxWidth: maxWidth,
        maxLines: 1,
      );

      if (tp.width <= maxWidth) {
        bestLength = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    if (bestLength == 0) return '';
    return '${text.substring(0, bestLength)}…';
  }

  /// Membuat gradient text (menggunakan TextStyle.foreground)
  static double paintGradientText({
    required Canvas canvas,
    required String text,
    required double x,
    required double y,
    required double maxWidth,
    required List<Color> gradientColors,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    int maxLines = 1,
    TextAlign textAlign = TextAlign.left,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
    List<Shadow>? shadows,
  }) {
    // Buat shader untuk gradient
    final shader = ui.Gradient.linear(
      Offset(x, y),
      Offset(x + maxWidth, y + fontSize),
      gradientColors,
    );

    // Buat style dengan foreground shader
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
      shadows: shadows,
      foreground: Paint()..shader = shader,
    );

    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
      textAlign: textAlign,
    )..layout(maxWidth: maxWidth);

    tp.paint(canvas, Offset(x, y));
    return tp.height;
  }

  /// Mendapatkan style dari cache
  static TextStyle getStyle({
    Color color = Colors.black,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
    List<Shadow>? shadows,
  }) {
    return TextPainterCache.getStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
      shadows: shadows,
    );
  }

  /// Soft shadow dengan offset kustom
  static List<Shadow> softShadowWithOffset({
    double opacity = 0.55,
    double blur = 3,
    double dx = 0,
    double dy = 1,
  }) => TextPainterCache.getSoftShadow(
    opacity: opacity,
    blur: blur,
    dx: dx,
    dy: dy,
  );

  /// Heavy shadow untuk kontras tinggi
  static List<Shadow> heavyShadow({
    double opacity = 0.8,
    double blur = 8,
  }) => TextPainterCache.getHeavyShadow(
    opacity: opacity,
    blur: blur,
  );

  /// No shadow
  static List<Shadow> noShadow() => TextPainterCache.getNoShadow();
}

// ─── DEPRECATED: Untuk backward compatibility ─────────────────

/// @deprecated Gunakan TextPainterCache sebagai gantinya
@deprecated
class CachedTextPainter {
  static TextPainter getPainter({
    required String text,
    required TextStyle style,
    double? maxWidth,
    int maxLines = 1,
    TextAlign textAlign = TextAlign.left,
  }) {
    return TextPainterCache.getPainter(
      text: text,
      style: style,
      maxWidth: maxWidth,
      maxLines: maxLines,
      textAlign: textAlign,
    );
  }

  static void clearCache() => TextPainterCache.clearAll();
}
