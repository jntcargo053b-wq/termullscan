import 'models/watermark_style.dart';
import 'layouts/base_layout.dart';
import 'layouts/polaroid_layout.dart';
import 'layouts/minimal_layout.dart';
import 'layouts/professional_layout.dart';
import 'layouts/stamp_layout.dart';
import 'renderers/base_renderer.dart';
import 'renderers/polaroid_renderer.dart';
import 'renderers/minimal_renderer.dart';
import 'renderers/professional_renderer.dart';
import 'renderers/stamp_renderer.dart';

class WatermarkFactory {
  static WatermarkRenderer createRenderer(WatermarkStyle style) {
    switch (style) {
      case WatermarkStyle.polaroid:
        return PolaroidRenderer();
      case WatermarkStyle.minimal:
        return MinimalRenderer();
      case WatermarkStyle.professional:
        return ProfessionalRenderer();
      case WatermarkStyle.stamp:
        return StampRenderer();
    }
  }

  static WatermarkLayout createLayout(WatermarkStyle style) {
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
