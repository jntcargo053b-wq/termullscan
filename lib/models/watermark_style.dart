import 'package:flutter/material.dart';

enum WatermarkStyle {
  standard,
  polaroid,
  minimal,
  professional,
  stamp,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

extension WatermarkStyleExtension on WatermarkStyle {
  double get fontSize {
    switch (this) {
      case WatermarkStyle.standard:
        return 14.0;
      case WatermarkStyle.polaroid:
        return 16.0;
      case WatermarkStyle.minimal:
        return 12.0;
      case WatermarkStyle.professional:
        return 14.0;
      case WatermarkStyle.stamp:
        return 18.0;
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

  String get displayName {
    switch (this) {
      case WatermarkStyle.standard:
        return 'Standard';
      case WatermarkStyle.polaroid:
        return 'Polaroid';
      case WatermarkStyle.minimal:
        return 'Minimal';
      case WatermarkStyle.professional:
        return 'Professional';
      case WatermarkStyle.stamp:
        return 'Stamp';
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
      case WatermarkStyle.polaroid:
        return Icons.photo_library;
      case WatermarkStyle.minimal:
        return Icons.minimize;
      case WatermarkStyle.professional:
        return Icons.work;
      case WatermarkStyle.stamp:
        return Icons.stamp;
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

  bool get isPositioned {
    switch (this) {
      case WatermarkStyle.topLeft:
      case WatermarkStyle.topRight:
      case WatermarkStyle.bottomLeft:
      case WatermarkStyle.bottomRight:
        return true;
      default:
        return false;
    }
  }
}
