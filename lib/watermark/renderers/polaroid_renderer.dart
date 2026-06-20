import 'dart:ui' as ui;
import 'base_renderer.dart';
import '../models/watermark_data.dart';
import '../layouts/polaroid_layout.dart';

class PolaroidRenderer implements WatermarkRenderer {
  final PolaroidLayout _layout = PolaroidLayout();

  @override
  String get name => _layout.displayName;

  @override
  WatermarkCanvasSize computeCanvasSize({
    required double photoWidth,
    required double photoHeight,
    required WatermarkData data,
  }) {
    return _layout.computeCanvasSize(
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      data: data,
    );
  }

  @override
  void paint({
    required Canvas canvas,
    required WatermarkCanvasSize canvasSize,
    required ui.Image srcImage,
    required double photoWidth,
    required double photoHeight,
    required ui.Image? logoImage,
    required WatermarkData data,
  }) {
    final metrics = _layout.computeMetrics(
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      data: data,
    );
    _layout.paintOnCanvas(
      canvas: canvas,
      metrics: metrics,
      srcImage: srcImage,
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      logoImage: logoImage,
      data: data,
    );
  }
}
