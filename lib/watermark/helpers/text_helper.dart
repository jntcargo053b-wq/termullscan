import 'dart:ui' as ui;
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
  }) {
    final tp = ui.TextPainter(
      text: ui.TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
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
    final tp = ui.TextPainter(
      text: ui.TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontWeight: fontWeight),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    return tp.width;
  }
}
