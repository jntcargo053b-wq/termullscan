import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../watermark_settings.dart';
import 'text_painter_cache.dart'; // ← TAMBAHKAN

/// Hasil resolusi posisi overlay strip (dipakai minimal & professional layout)
/// supaya logika switch-case posisi tidak diduplikasi di setiap layout.
class OverlayPlacement {
  final double top;
  final TextAlign textAlign;
  final bool atBottom;

  const OverlayPlacement({
    required this.top,
    required this.textAlign,
    required this.atBottom,
  });
}

/// Safe area untuk layout (support device dengan notch)
class SafeArea {
  final double top;
  final double bottom;
  final double left;
  final double right;

  const SafeArea({
    this.top = 0,
    this.bottom = 0,
    this.left = 0,
    this.right = 0,
  });

  Rect apply(Rect rect) {
    return Rect.fromLTRB(
      rect.left + left,
      rect.top + top,
      rect.right - right,
      rect.bottom - bottom,
    );
  }
}

/// Hasil perhitungan posisi teks
class TextPosition {
  final double x;
  final double y;
  final double availableWidth;
  final TextAlign alignment;

  const TextPosition({
    required this.x,
    required this.y,
    required this.availableWidth,
    this.alignment = TextAlign.left,
  });
}

/// Opsi gradient untuk background strip
enum StripGradientType {
  solid,
  linear,
  radial,
}

/// LayoutHelper - Utility untuk berbagai layout watermark
class LayoutHelper {
  // ─── FUNGSI ASLI (TIDAK DIUBAH) ──────────────────────────────
  
  static double getBaseSize(double photoWidth, double photoHeight) =>
      math.min(photoWidth, photoHeight);

  static double padding(double baseSize, {double ratio = 0.04}) =>
      baseSize * ratio;

  static double fontSize(double baseSize, {double ratio = 0.038}) =>
      baseSize * ratio;

  static double lineHeight(double baseSize, {double ratio = 0.055}) =>
      baseSize * ratio;

  static double logoSize(double baseSize, {double ratio = 0.15}) =>
      baseSize * ratio;

  static OverlayPlacement resolvePlacement({
    required WatermarkPosition position,
    required double photoHeight,
    required double overlayHeight,
  }) {
    switch (position) {
      case WatermarkPosition.bottomRight:
        return OverlayPlacement(
          top: photoHeight - overlayHeight,
          textAlign: TextAlign.right,
          atBottom: true,
        );
      case WatermarkPosition.bottomLeft:
        return OverlayPlacement(
          top: photoHeight - overlayHeight,
          textAlign: TextAlign.left,
          atBottom: true,
        );
      case WatermarkPosition.topRight:
        return OverlayPlacement(
          top: 0,
          textAlign: TextAlign.right,
          atBottom: false,
        );
      case WatermarkPosition.topLeft:
        return OverlayPlacement(
          top: 0,
          textAlign: TextAlign.left,
          atBottom: false,
        );
    }
  }

  static void paintElevatedRRect({
    required Canvas canvas,
    required RRect rrect,
    required Color color,
    double elevation = 6,
    Color shadowColor = Colors.black,
    double shadowOpacity = 0.35,
  }) {
    canvas.drawShadow(
      Path()..addRRect(rrect),
      shadowColor.withOpacity(shadowOpacity),
      elevation,
      false,
    );
    canvas.drawRRect(rrect, Paint()..color = color);
  }

  // ─── FUNGSI TAMBAHAN (BARU) ──────────────────────────────────

  static void validateDimensions(double width, double height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Width dan height harus > 0');
    }
  }

  static double responsiveSize({
    required double baseSize,
    required double factor,
    double min = 0,
    double max = double.infinity,
  }) {
    final size = baseSize * factor;
    return size.clamp(min, max);
  }

  static double responsiveFontSize({
    required double baseSize,
    required double factor,
    double minSize = 8,
    double maxSize = 32,
  }) {
    return responsiveSize(
      baseSize: baseSize,
      factor: factor,
      min: minSize,
      max: maxSize,
    );
  }

  static TextPosition calculateTextPosition({
    required double photoWidth,
    required double photoHeight,
    required double baseSize,
    required double textWidth,
    required double textHeight,
    required WatermarkPosition position,
    double horizontalPadding = 0,
    double verticalPadding = 0,
    TextAlign alignment = TextAlign.left,
  }) {
    final pad = padding(baseSize);
    final effectiveHPad = horizontalPadding > 0 ? horizontalPadding : pad;
    final effectiveVPad = verticalPadding > 0 ? verticalPadding : pad;

    double x;
    double y;

    switch (position) {
      case WatermarkPosition.topLeft:
        x = effectiveHPad;
        y = effectiveVPad;
        break;
      case WatermarkPosition.topRight:
        x = photoWidth - textWidth - effectiveHPad;
        y = effectiveVPad;
        break;
      case WatermarkPosition.bottomLeft:
        x = effectiveHPad;
        y = photoHeight - textHeight - effectiveVPad;
        break;
      case WatermarkPosition.bottomRight:
        x = photoWidth - textWidth - effectiveHPad;
        y = photoHeight - textHeight - effectiveVPad;
        break;
    }

    return TextPosition(
      x: x,
      y: y,
      availableWidth: photoWidth - effectiveHPad * 2,
      alignment: alignment,
    );
  }

  static Rect getSafeRect({
    required double photoWidth,
    required double photoHeight,
    required double baseSize,
    SafeArea safeArea = const SafeArea(),
  }) {
    final pad = padding(baseSize);
    return Rect.fromLTRB(
      pad + safeArea.left,
      pad + safeArea.top,
      photoWidth - pad - safeArea.right,
      photoHeight - pad - safeArea.bottom,
    );
  }

  static void drawStripBackground({
    required Canvas canvas,
    required Rect rect,
    required Color color,
    double opacity = 0.85,
    StripGradientType gradientType = StripGradientType.solid,
    List<Color>? gradientColors,
  }) {
    final Paint paint = Paint();
    
    switch (gradientType) {
      case StripGradientType.solid:
        paint.color = color.withOpacity(opacity);
        canvas.drawRect(rect, paint);
        break;
        
      case StripGradientType.linear:
        if (gradientColors == null || gradientColors.length < 2) {
          paint.color = color.withOpacity(opacity);
          canvas.drawRect(rect, paint);
          return;
        }
        final shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          gradientColors.map((c) => c.withOpacity(opacity)).toList(),
        );
        paint.shader = shader;
        canvas.drawRect(rect, paint);
        break;
        
      case StripGradientType.radial:
        if (gradientColors == null || gradientColors.length < 2) {
          paint.color = color.withOpacity(opacity);
          canvas.drawRect(rect, paint);
          return;
        }
        final center = rect.center;
        final radius = math.max(rect.width, rect.height) / 2;
        final shader = ui.Gradient.radial(
          center,
          radius,
          gradientColors.map((c) => c.withOpacity(opacity)).toList(),
        );
        paint.shader = shader;
        canvas.drawRect(rect, paint);
        break;
    }
  }

  static double calculateTextBlockHeight({
    required int lineCount,
    required double fontSize,
    required double lineSpacing,
  }) {
    if (lineCount <= 0) return 0;
    return (fontSize * lineSpacing) * lineCount;
  }

  static double estimateTextWidth({
    required String text,
    required double fontSize,
  }) {
    return text.length * fontSize * 0.6;
  }

  static void drawEmoji({
    required Canvas canvas,
    required String emoji,
    required double x,
    required double y,
    required double size,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: emoji,
        style: TextStyle(
          fontSize: size,
          fontFamily: 'Emoji',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(x, y));
  }

  // ─── DEBUG UTILITIES ──────────────────────────────────────────

  static void drawDebugGrid({
    required Canvas canvas,
    required double width,
    required double height,
    int columns = 4,
    int rows = 4,
  }) {
    if (width <= 0 || height <= 0) return;

    final paint = Paint()
      ..color = Colors.red.withOpacity(0.3)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    for (int i = 0; i <= columns; i++) {
      final x = width * i / columns;
      canvas.drawLine(Offset(x, 0), Offset(x, height), paint);
    }

    for (int i = 0; i <= rows; i++) {
      final y = height * i / rows;
      canvas.drawLine(Offset(0, y), Offset(width, y), paint);
    }
  }

  static void drawBoundingBox({
    required Canvas canvas,
    required Rect rect,
    Color color = Colors.yellow,
    double strokeWidth = 2,
  }) {
    final paint = Paint()
      ..color = color.withOpacity(0.8)
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, paint);
  }

  // ─── CLEAR CACHE ──────────────────────────────────────────────

  /// Membersihkan semua cache (dipanggil saat aplikasi dimatikan atau memory warning)
  static void clearCache() {
    TextPainterCache.clearAll();
  }
}
