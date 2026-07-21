// lib/watermark/models/watermark_data.dart
// ============================================================
// WATERMARK DATA — Data untuk rendering watermark
// ============================================================

import 'package:intl/intl.dart';
import '../watermark_settings.dart';
import '../../models/scan_entry.dart';
import '../../models/resolved_location.dart';

class WatermarkData {
  final DateTime timestamp;
  final String operatorName;
  final String companyName;
  final String? barcodeValue;
  final String? barcodeFormat;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String? city;
  final String? province;
  final String? country;
  final String? logoPath;
  final WatermarkPosition position;
  final double fontSize;
  final double backgroundOpacity;
  final String fontFamily;

  const WatermarkData({
    required this.timestamp,
    required this.operatorName,
    this.companyName = '',
    this.barcodeValue,
    this.barcodeFormat,
    this.latitude,
    this.longitude,
    this.locationName,
    this.city,
    this.province,
    this.country,
    this.logoPath,
    this.position = WatermarkPosition.bottomRight,
    this.fontSize = 14.0,
    this.backgroundOpacity = 0.55,
    this.fontFamily = 'Roboto',
  });

  // ─── FACTORY ──────────────────────────────────────────────────

  /// Buat WatermarkData dari ScanEntry + WatermarkSettings
  factory WatermarkData.fromScanEntry(
    ScanEntry entry, {
    required WatermarkSettings settings,
    double? fontSize,
  }) {
    return WatermarkData(
      timestamp: entry.timestamp,
      operatorName: settings.operatorName,
      companyName: settings.companyName,
      barcodeValue: entry.value,
      barcodeFormat: entry.barcodeFormat, // ← FIX: pakai getter
      latitude: entry.latitude,
      longitude: entry.longitude,
      locationName: entry.locationName, // ← FIX: hanya locationName
      city: entry.city,
      province: entry.province,
      country: entry.country,
      logoPath: settings.logoPath,
      position: settings.position,
      fontSize: fontSize ?? settings.fontSize,
      backgroundOpacity: settings.backgroundOpacity,
      fontFamily: settings.fontFamily,
    );
  }

  /// Buat WatermarkData dari ResolvedLocation
  factory WatermarkData.fromResolvedLocation(
    ResolvedLocation location, {
    required String operatorName,
    required WatermarkSettings settings,
    required DateTime timestamp,
    String? barcodeValue,
    String? barcodeFormat,
  }) {
    return WatermarkData(
      timestamp: timestamp,
      operatorName: operatorName,
      companyName: settings.companyName,
      barcodeValue: barcodeValue,
      barcodeFormat: barcodeFormat,
      latitude: location.latitude,
      longitude: location.longitude,
      locationName: location.display,
      city: location.city,
      province: location.province,
      country: location.country,
      logoPath: settings.logoPath,
      position: settings.position,
      fontSize: settings.fontSize,
      backgroundOpacity: settings.backgroundOpacity,
      fontFamily: settings.fontFamily,
    );
  }

  // ─── COPYWITH ──────────────────────────────────────────────────

  WatermarkData copyWith({
    DateTime? timestamp,
    String? operatorName,
    String? companyName,
    String? barcodeValue,
    String? barcodeFormat,
    double? latitude,
    double? longitude,
    String? locationName,
    String? city,
    String? province,
    String? country,
    String? logoPath,
    WatermarkPosition? position,
    double? fontSize,
    double? backgroundOpacity,
    String? fontFamily,
  }) {
    return WatermarkData(
      timestamp: timestamp ?? this.timestamp,
      operatorName: operatorName ?? this.operatorName,
      companyName: companyName ?? this.companyName,
      barcodeValue: barcodeValue ?? this.barcodeValue,
      barcodeFormat: barcodeFormat ?? this.barcodeFormat,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationName: locationName ?? this.locationName,
      city: city ?? this.city,
      province: province ?? this.province,
      country: country ?? this.country,
      logoPath: logoPath ?? this.logoPath,
      position: position ?? this.position,
      fontSize: fontSize ?? this.fontSize,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      fontFamily: fontFamily ?? this.fontFamily,
    );
  }

  // ─── GETTERS ──────────────────────────────────────────────────

  bool get hasBarcode => barcodeValue != null && barcodeValue!.isNotEmpty;
  bool get hasOperator => operatorName.isNotEmpty;
  bool get hasCompany => companyName.isNotEmpty;
  bool get hasLocation {
    return (locationName != null && locationName!.isNotEmpty) ||
           (latitude != null && longitude != null);
  }
  bool get isManual => barcodeFormat == 'MANUAL';
  bool get hasLogo => logoPath != null && logoPath!.isNotEmpty;

  String get formattedTimestamp =>
      DateFormat('dd/MM/yyyy HH:mm:ss').format(timestamp);

  /// Display location: prioritaskan locationName, fallback ke koordinat
  String get displayLocation {
    if (locationName != null && locationName!.isNotEmpty) {
      return locationName!;
    }
    if (latitude != null && longitude != null) {
      return '${latitude!.toStringAsFixed(4)}, ${longitude!.toStringAsFixed(4)}';
    }
    return 'Lokasi tidak tersedia';
  }

  /// Short location untuk preview (max 30 karakter)
  String get shortLocation {
    final loc = displayLocation;
    if (loc.length > 30) {
      return '${loc.substring(0, 30)}…';
    }
    return loc;
  }

  /// Koordinat dalam format DMS
  String get coordinatesDMS {
    if (latitude == null || longitude == null) return '';
    
    final latAbs = latitude!.abs();
    final lonAbs = longitude!.abs();
    
    final latDeg = latAbs.floor();
    final latMin = ((latAbs - latDeg) * 60).floor();
    final latSec = ((latAbs - latDeg - latMin / 60) * 3600).toStringAsFixed(1);
    
    final lonDeg = lonAbs.floor();
    final lonMin = ((lonAbs - lonDeg) * 60).floor();
    final lonSec = ((lonAbs - lonDeg - lonMin / 60) * 3600).toStringAsFixed(1);
    
    final latDir = latitude! >= 0 ? 'N' : 'S';
    final lonDir = longitude! >= 0 ? 'E' : 'W';
    
    return '$latDeg°$latMin\'$latSec" $latDir, $lonDeg°$lonMin\'$lonSec" $lonDir';
  }

  /// Koordinat dalam format desimal pendek
  String get shortCoordinates {
    if (latitude == null || longitude == null) return '';
    return '${latitude!.toStringAsFixed(4)}, ${longitude!.toStringAsFixed(4)}';
  }
}
