import 'dart:ui' as ui;
import '../models/watermark_data.dart';

class WatermarkCanvasSize {
  final double width;
  final double height;
  const WatermarkCanvasSize(this.width, this.height);
}

abstract class WatermarkRenderer {
  String get name;
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  });
  void paint({
    required Canvas canvas,
    required WatermarkCanvasSize canvasSize,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  });
}
