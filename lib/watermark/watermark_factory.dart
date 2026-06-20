import 'models/watermark_style.dart';
import 'layouts/base_layout.dart';
import 'layouts/polaroid_layout.dart';
import 'layouts/minimal_layout.dart';
import 'layouts/professional_layout.dart';
import 'layouts/stamp_layout.dart';

class WatermarkFactory {
  // --- RENDERER (untuk renderer di service) ---
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

  // --- LAYOUT (untuk preview) ---
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
