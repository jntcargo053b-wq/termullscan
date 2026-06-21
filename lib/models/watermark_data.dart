import 'package:flutter/material.dart';

/// Data untuk watermark
class WatermarkData {
  final DateTime timestamp;
  final String operatorName;
  final String? barcodeValue;
  final String? barcodeFormat;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String? logoPath;

  const WatermarkData({
    required this.timestamp,
    required this.operatorName,
    this.barcodeValue,
    this.barcodeFormat,
    this.latitude,
    this.longitude,
    this.locationName,
    this.logoPath,
  });

  /// Konversi ke map untuk debug
  Map<String, dynamic> toMap() {
    return {
      'timestamp': timestamp.toIso8601String(),
      'operatorName': operatorName,
      'barcodeValue': barcodeValue,
      'barcodeFormat': barcodeFormat,
      'latitude': latitude,
      'longitude': longitude,
      'locationName': locationName,
      'hasLogo': logoPath != null,
    };
  }
}
