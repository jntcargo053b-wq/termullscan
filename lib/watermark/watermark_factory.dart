import 'package:flutter/material.dart';
import 'models/watermark_style.dart';
import 'models/watermark_data.dart';
import 'layouts/base_layout.dart';
import 'layouts/standard_layout.dart';
import 'layouts/polaroid_layout.dart';
import 'layouts/minimal_layout.dart';
import 'layouts/professional_layout.dart';
import 'layouts/stamp_layout.dart';
import 'layouts/top_left_layout.dart';
import 'layouts/top_right_layout.dart';
import 'layouts/bottom_left_layout.dart';
import 'layouts/bottom_right_layout.dart';

export 'layouts/base_layout.dart' show WatermarkLayout;

class WatermarkFactory {
  static WatermarkLayout create(WatermarkStyle style) {
    switch (style) {
      case WatermarkStyle.standard:
        return StandardLayout(); // ✅ HAPUS const
      case WatermarkStyle.polaroid:
        return PolaroidLayout(); // ✅ HAPUS const
      case WatermarkStyle.minimal:
        return MinimalLayout(); // ✅ HAPUS const
      case WatermarkStyle.professional:
        return ProfessionalLayout(); // ✅ HAPUS const
      case WatermarkStyle.stamp:
        return StampLayout(); // ✅ HAPUS const
      case WatermarkStyle.topLeft:
        return TopLeftLayout(); // ✅ HAPUS const
      case WatermarkStyle.topRight:
        return TopRightLayout(); // ✅ HAPUS const
      case WatermarkStyle.bottomLeft:
        return BottomLeftLayout(); // ✅ HAPUS const
      case WatermarkStyle.bottomRight:
        return BottomRightLayout(); // ✅ HAPUS const
    }
  }
}
