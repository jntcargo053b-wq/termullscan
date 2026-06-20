import 'package:intl/intl.dart';

class WatermarkData {
  final String? barcodeValue;
  final String? barcodeFormat;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String operatorName;
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

  bool get isManual => barcodeFormat == 'MANUAL';
  bool get hasBarcode => barcodeValue != null && barcodeValue!.isNotEmpty;
  bool get hasOperator => operatorName.isNotEmpty;
  bool get hasCoordinates => latitude != null && longitude != null;
  bool get hasLogoPath => logoPath != null && logoPath!.isNotEmpty;

  String get displayLocation {
    if (locationName != null && locationName!.isNotEmpty) {
      return locationName!;
    }
    if (hasCoordinates) {
      final latDir = latitude! >= 0 ? 'N' : 'S';
      final lonDir = longitude! >= 0 ? 'E' : 'W';
      return '${latitude!.abs().toStringAsFixed(4)}° $latDir, '
          '${longitude!.abs().toStringAsFixed(4)}° $lonDir';
    }
    return 'No location data';
  }

  // 🔥 GETTER BARU
  String get formattedTimestamp =>
      DateFormat('dd/MM/yyyy HH:mm:ss').format(timestamp);
}
