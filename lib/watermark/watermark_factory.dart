import 'models/watermark_style.dart';
import 'layouts/base_layout.dart';
import 'layouts/polaroid_layout.dart';
import 'layouts/minimal_layout.dart';
import 'layouts/professional_layout.dart';
import 'layouts/stamp_layout.dart';

class WatermarkFactory {
  static WatermarkLayout create(WatermarkStyle style) {
    switch (style) {
      case WatermarkStyle.polaroid:
        return PolaroidLayout();
      case WatermarkStyle.minimal:
        return MinimalLayout();
      case WatermarkStyle.professional:
        return ProfessionalLayout();
      case WatermarkStyle.stamp:
        return StampLayout();
    }
  }
}
