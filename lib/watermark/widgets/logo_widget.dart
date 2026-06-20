import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class LogoWidget {
  static void paint({
    required Canvas canvas,
    required ui.Image? logoImage,
    required double x,
    required double y,
    required double maxWidth,
    required double maxHeight,
    double opacity = 1.0,
    BlendMode blendMode = BlendMode.srcOver,
  }) {
    if (logoImage == null) return;

    final logoW = logoImage.width.toDouble();
    final logoH = logoImage.height.toDouble();

    final scaleX = maxWidth / logoW;
    final scaleY = maxHeight / logoH;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final drawW = logoW * scale;
    final drawH = logoH * scale;

    canvas.drawImageRect(
      logoImage,
      Rect.fromLTWH(0, 0, logoW, logoH),
      Rect.fromLTWH(x, y, drawW, drawH),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true
        ..colorFilter = ColorFilter.mode(
          Colors.white.withOpacity(opacity),
          blendMode,
        ),
    );
  }
}
