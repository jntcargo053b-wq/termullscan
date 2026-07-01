import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../watermark_settings.dart';

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

class LayoutHelper {
  static double getBaseSize(double photoWidth, double photoHeight) =>
      math.min(photoWidth, photoHeight);

  static double padding(double baseSize, {double ratio = 0.04}) =>
      baseSize * ratio;

  // 🔥 FONT LEBIH BESAR (dari 0.028 → 0.038)
  static double fontSize(double baseSize, {double ratio = 0.038}) =>
      baseSize * ratio;

  // 🔥 SPASI LEBIH LEGA (dari 0.045 → 0.055)
  static double lineHeight(double baseSize, {double ratio = 0.055}) =>
      baseSize * ratio;

  static double logoSize(double baseSize, {double ratio = 0.15}) =>
      baseSize * ratio;

  /// Menghitung posisi & alignment overlay strip berdasarkan [WatermarkPosition].
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

  /// Menggambar RRect dengan soft drop-shadow di baliknya sehingga elemen
  /// (logo card, accent bar, badge) terasa "mengambang" — sentuhan modern.
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
}
