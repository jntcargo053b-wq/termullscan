import 'package:intl/intl.dart';
import '../watermark_settings.dart';
import '../../models/scan_entry.dart'; // ← untuk factory fromScanEntry

class WatermarkData {
  final DateTime timestamp;
  final String operatorName;
  final String companyName;
  final String? barcodeValue;
  final String? barcodeFormat;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String? address; // ← TAMBAHKAN sebagai alternatif
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
    this.address,
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
      barcodeFormat: entry.type,
      latitude: entry.latitude,
      longitude: entry.longitude,
      locationName: entry.locationName ?? entry.address,
      address: entry.address,
      logoPath: settings.logoPath,
      position: settings.position,
      fontSize: fontSize ?? settings.fontSize,
      backgroundOpacity: settings.backgroundOpacity,
      fontFamily: settings.fontFamily,
    );
  }

  // ─── COPYWITH ─────────────────────────────────────────────────

  WatermarkData copyWith({
    DateTime? timestamp,
    String? operatorName,
    String? companyName,
    String? barcodeValue,
    String? barcodeFormat,
    double? latitude,
    double? longitude,
    String? locationName,
    String? address,
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
      address: address ?? this.address,
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
           (address != null && address!.isNotEmpty) ||
           (latitude != null && longitude != null);
  }
  bool get isManual => barcodeFormat == 'MANUAL';
  bool get hasLogo => logoPath != null && logoPath!.isNotEmpty;

  String get formattedTimestamp =>
      DateFormat('dd/MM/yyyy HH:mm:ss').format(timestamp);

  /// Display location: prioritaskan alamat lengkap, fallback ke koordinat
  String get displayLocation {
    if (locationName != null && locationName!.isNotEmpty) {
      return locationName!;
    }
    if (address != null && address!.isNotEmpty) {
      return address!;
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

  /// Koordinat dalam format DMS (Derajat, Menit, Detik)
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
