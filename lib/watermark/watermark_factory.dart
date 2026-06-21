import 'package:flutter/material.dart';
import 'models/watermark_style.dart';
import 'models/watermark_data.dart';
import 'layouts/standard_layout.dart';
import 'layouts/polaroid_layout.dart';
import 'layouts/minimal_layout.dart';
import 'layouts/professional_layout.dart';
import 'layouts/stamp_layout.dart';
import 'layouts/top_left_layout.dart';
import 'layouts/top_right_layout.dart';
import 'layouts/bottom_left_layout.dart';
import 'layouts/bottom_right_layout.dart';

class WatermarkFactory {
  static WatermarkLayout create(WatermarkStyle style) {
    switch (style) {
      case WatermarkStyle.standard:
        return const StandardLayout();
      case WatermarkStyle.polaroid:
        return const PolaroidLayout();
      case WatermarkStyle.minimal:
        return const MinimalLayout();
      case WatermarkStyle.professional:
        return const ProfessionalLayout();
      case WatermarkStyle.stamp:
        return const StampLayout();
      case WatermarkStyle.topLeft:
        return const TopLeftLayout();
      case WatermarkStyle.topRight:
        return const TopRightLayout();
      case WatermarkStyle.bottomLeft:
        return const BottomLeftLayout();
      case WatermarkStyle.bottomRight:
        return const BottomRightLayout();
    }
  }
}

abstract class WatermarkLayout {
  const WatermarkLayout();
  String get displayName;
  Widget buildPreview({
    required WatermarkData previewData,
    required bool hasLogo,
    required String? logoPath,
  });
}
