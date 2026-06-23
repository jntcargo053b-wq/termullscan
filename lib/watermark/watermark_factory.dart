import 'package:flutter/material.dart';
import 'watermark_style.dart'; // ✅ import yang benar
import 'layouts/base_layout.dart';
import 'layouts/minimal_layout.dart';
import 'layouts/professional_layout.dart';
import 'layouts/stamp_layout.dart';
import 'layouts/polaroid_layout.dart';

export 'layouts/base_layout.dart' show WatermarkLayout;

class WatermarkFactory {
  static WatermarkLayout create(WatermarkStyle style) {
    switch (style) {
      case WatermarkStyle.minimal:
        return MinimalLayout();
      case WatermarkStyle.professional:
        return ProfessionalLayout();
      case WatermarkStyle.polaroid:
        return PolaroidLayout();
      case WatermarkStyle.stamp:
        return StampLayout();
      default:
        return ProfessionalLayout();
    }
  }
}
