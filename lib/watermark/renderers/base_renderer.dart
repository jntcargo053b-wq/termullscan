import 'dart:ui' as ui;
import '../models/watermark_data.dart';
// Hapus definisi WatermarkCanvasSize, gunakan dari base_layout
import '../layouts/base_layout.dart' show WatermarkCanvasSize;

abstract class WatermarkRenderer {
  String get name;
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  });
  void paint({
    required ui.Canvas canvas,
    required WatermarkCanvasSize canvasSize,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  });
}
