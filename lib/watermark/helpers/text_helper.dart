import 'package:flutter/material.dart';
// Tidak perlu import dart:ui, karena TextPainter tersedia di material.

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
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
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

  static double measureTextWidth({
    required String text,
    required double fontSize,
    FontWeight fontWeight = FontWeight.normal,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontWeight: fontWeight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }
}
