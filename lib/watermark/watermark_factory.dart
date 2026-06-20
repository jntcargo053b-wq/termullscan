import 'models/watermark_style.dart';
import 'renderers/base_renderer.dart';
import 'renderers/minimal_renderer.dart';
import 'renderers/polaroid_renderer.dart';
import 'renderers/professional_renderer.dart';
import 'renderers/stamp_renderer.dart';

/// Membuat instance [WatermarkRenderer] yang sesuai untuk sebuah
/// [WatermarkStyle]. Satu-satunya tempat yang perlu diubah ketika
/// menambah gaya watermark baru di masa depan.
class WatermarkFactory {
  WatermarkFactory._();

  static WatermarkRenderer create(WatermarkStyle style) {
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
}
