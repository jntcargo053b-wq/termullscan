import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'base_renderer.dart';
import '../models/watermark_data.dart';
import '../models/watermark_style.dart';
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
    _layout.paintOnCanvas(
      canvas: canvas,
      canvasSize: canvasSize,
      srcImage: srcImage,
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      logoImage: logoImage,
      data: data,
    );
  }
}
