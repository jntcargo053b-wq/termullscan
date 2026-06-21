import 'package:flutter/material.dart';

/// Enum untuk posisi watermark
enum WatermarkStyle {
  standard,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// Extension untuk mendapatkan properti dari WatermarkStyle
extension WatermarkStyleExtension on WatermarkStyle {
  double get fontSize {
    switch (this) {
      case WatermarkStyle.standard:
        return 14.0;
      case WatermarkStyle.topLeft:
        return 12.0;
      case WatermarkStyle.topRight:
        return 12.0;
      case WatermarkStyle.bottomLeft:
        return 14.0;
      case WatermarkStyle.bottomRight:
        return 14.0;
    }
  }

  Alignment get alignment {
    switch (this) {
      case WatermarkStyle.standard:
        return Alignment.bottomLeft;
      case WatermarkStyle.topLeft:
        return Alignment.topLeft;
      case WatermarkStyle.topRight:
        return Alignment.topRight;
      case WatermarkStyle.bottomLeft:
        return Alignment.bottomLeft;
      case WatermarkStyle.bottomRight:
        return Alignment.bottomRight;
    }
  }

  String get displayName {
    switch (this) {
      case WatermarkStyle.standard:
        return 'Standard';
      case WatermarkStyle.topLeft:
        return 'Atas Kiri';
      case WatermarkStyle.topRight:
        return 'Atas Kanan';
      case WatermarkStyle.bottomLeft:
        return 'Bawah Kiri';
      case WatermarkStyle.bottomRight:
        return 'Bawah Kanan';
    }
  }

  IconData get icon {
    switch (this) {
      case WatermarkStyle.standard:
        return Icons.format_align_left;
      case WatermarkStyle.topLeft:
        return Icons.vertical_align_top;
      case WatermarkStyle.topRight:
        return Icons.vertical_align_top;
      case WatermarkStyle.bottomLeft:
        return Icons.vertical_align_bottom;
      case WatermarkStyle.bottomRight:
        return Icons.vertical_align_bottom;
    }
  }
}
