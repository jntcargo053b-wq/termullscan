import 'package:intl/intl.dart';
import 'watermark_settings.dart';

class WatermarkData {
  final DateTime timestamp;
  final String operatorName;
  final String? barcodeValue;
  final String? barcodeFormat;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String? logoPath;
  final WatermarkPosition position;
  final double fontSize;
  final double backgroundOpacity;

  const WatermarkData({
    required this.timestamp,
    required this.operatorName,
    this.barcodeValue,
    this.barcodeFormat,
    this.latitude,
    this.longitude,
    this.locationName,
    this.logoPath,
    this.position = WatermarkPosition.bottomRight,
    this.fontSize = 14.0,
    this.backgroundOpacity = 0.55,
  });

  bool get hasBarcode => barcodeValue != null && barcodeValue!.isNotEmpty;
  bool get hasOperator => operatorName.isNotEmpty;
  bool get hasLocation => locationName != null && locationName!.isNotEmpty;
  bool get isManual => barcodeFormat == 'MANUAL';
  bool get hasLogo => logoPath != null && logoPath!.isNotEmpty;

  String get formattedTimestamp => DateFormat('dd/MM/yyyy HH:mm:ss').format(timestamp);

  String get displayLocation {
    if (locationName != null && locationName!.isNotEmpty) return locationName!;
    if (latitude != null && longitude != null) {
      return '${latitude!.toStringAsFixed(4)}, ${longitude!.toStringAsFixed(4)}';
    }
    return 'Lokasi tidak tersedia';
  }
}
