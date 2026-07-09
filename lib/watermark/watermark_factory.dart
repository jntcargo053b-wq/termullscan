// lib/watermark/watermark_factory.dart
import 'layouts/minimal_layout.dart';
import 'layouts/professional_layout.dart';
import 'layouts/polaroid_layout.dart';
import 'layouts/stamp_layout.dart';
import 'layouts/timestamp_layout.dart'; // ✅ PASTIKAN ADA
import 'layouts/base_layout.dart';
import 'watermark_style.dart';

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
      case WatermarkStyle.timestamp:
        return TimestampLayout();
      default:
        return ProfessionalLayout();
    }
  }
}
