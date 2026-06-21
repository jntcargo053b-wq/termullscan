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
}
