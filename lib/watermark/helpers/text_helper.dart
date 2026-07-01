import 'package:flutter/material.dart';

class TextHelper {
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
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontFamily: fontFamily,
          letterSpacing: letterSpacing,
          shadows: shadows,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
      textAlign: textAlign,
    )..layout(maxWidth: maxWidth);

    tp.paint(canvas, Offset(x, y));
    return tp.height;
  }

  /// Soft drop-shadow tipis di belakang teks agar tetap terbaca di atas foto
  /// apa pun (terang/kompleks) tanpa terlihat kasar — sentuhan modern & rapi.
  static List<Shadow> softShadow({double opacity = 0.55, double blur = 3}) => [
        Shadow(
          color: Colors.black.withOpacity(opacity),
          blurRadius: blur,
          offset: const Offset(0, 1),
        ),
      ];
}
