import 'package:flutter/material.dart';
import 'watermark_style.dart';
import 'layouts/base_layout.dart';
import 'layouts/minimal_layout.dart';
import 'layouts/professional_layout.dart';
import 'layouts/stamp_layout.dart';
import 'layouts/polaroid_layout.dart';
import 'layouts/timestamp_layout.dart';

export 'layouts/base_layout.dart' show WatermarkLayout;

class WatermarkFactory {
  static WatermarkLayout create(WatermarkStyle style) {
    debugPrint('🏭 WatermarkFactory.create() called with style: ${style.name}');
    
    switch (style) {
      case WatermarkStyle.minimal:
        debugPrint('   → Returning MinimalLayout');
        return MinimalLayout();
      case WatermarkStyle.professional:
        debugPrint('   → Returning ProfessionalLayout');
        return ProfessionalLayout();
      case WatermarkStyle.polaroid:
        debugPrint('   → Returning PolaroidLayout');
        return PolaroidLayout();
      case WatermarkStyle.stamp:
        debugPrint('   → Returning StampLayout');
        return StampLayout();
      case WatermarkStyle.timestamp:
        debugPrint('   → Returning TimestampLayout');
        return TimestampLayout();
      default:
        debugPrint('   → FALLBACK: Returning ProfessionalLayout');
        return ProfessionalLayout();
    }
  }
}
