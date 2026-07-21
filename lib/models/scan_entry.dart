// lib/models/scan_entry.dart
// ============================================================
// SCAN ENTRY — Model untuk hasil scan
// ============================================================

import 'package:intl/intl.dart';

enum ScanType {
  barcode,
  qr,
  manual,
  image,
  video,
}

class ScanEntry {
  final String id;
  final String value;
  final ScanType type;
  final String? imagePath;
  final String? videoPath;
  final DateTime timestamp;
  final String operatorName;
  final String? companyName;
  final double? latitude;
  final double? longitude;
  final String? locationName;   // ← ALAMAT LENGKAP (cukup satu field)
  final String? city;
  final String? province;
  final String? country;
  final String? postalCode;
  final bool isManual;
  final bool isSynced;

  ScanEntry({
    required this.id,
    required this.value,
    required this.type,
    this.imagePath,
    this.videoPath,
    required this.timestamp,
    required this.operatorName,
    this.companyName,
    this.latitude,
    this.longitude,
    this.locationName,
    this.city,
    this.province,
    this.country,
    this.postalCode,
    this.isManual = false,
    this.isSynced = false,
  });

  // ─── FACTORY ──────────────────────────────────────────────────

  factory ScanEntry.fromMap(Map<String, dynamic> map) {
    return ScanEntry(
      id: map['id'] as String,
      value: map['value'] as String,
      type: ScanType.values[map['type'] as int],
      imagePath: map['imagePath'] as String?,
      videoPath: map['videoPath'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      operatorName: map['operatorName'] as String,
      companyName: map['companyName'] as String?,
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      locationName: map['locationName'] as String?,
      city: map['city'] as String?,
      province: map['province'] as String?,
      country: map['country'] as String?,
      postalCode: map['postalCode'] as String?,
      isManual: map['isManual'] as bool? ?? false,
      isSynced: map['isSynced'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'value': value,
      'type': type.index,
      'imagePath': imagePath,
      'videoPath': videoPath,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'operatorName': operatorName,
      'companyName': companyName,
      'latitude': latitude,
      'longitude': longitude,
      'locationName': locationName,
      'city': city,
      'province': province,
      'country': country,
      'postalCode': postalCode,
      'isManual': isManual,
      'isSynced': isSynced,
    };
  }

  // ─── GETTERS ──────────────────────────────────────────────────

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

  bool get hasLocation {
    return (locationName != null && locationName!.isNotEmpty) ||
           (latitude != null && longitude != null);
  }

  /// Format timestamp untuk display
  String get formattedTimestamp {
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');
    return dateFormat.format(timestamp);
  }

  String get barcodeFormat => type == ScanType.manual ? 'MANUAL' : type.name.toUpperCase();

  // ─── COPYWITH ──────────────────────────────────────────────────

  ScanEntry copyWith({
    String? id,
    String? value,
    ScanType? type,
    String? imagePath,
    String? videoPath,
    DateTime? timestamp,
    String? operatorName,
    String? companyName,
    double? latitude,
    double? longitude,
    String? locationName,
    String? city,
    String? province,
    String? country,
    String? postalCode,
    bool? isManual,
    bool? isSynced,
  }) {
    return ScanEntry(
      id: id ?? this.id,
      value: value ?? this.value,
      type: type ?? this.type,
      imagePath: imagePath ?? this.imagePath,
      videoPath: videoPath ?? this.videoPath,
      timestamp: timestamp ?? this.timestamp,
      operatorName: operatorName ?? this.operatorName,
      companyName: companyName ?? this.companyName,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationName: locationName ?? this.locationName,
      city: city ?? this.city,
      province: province ?? this.province,
      country: country ?? this.country,
      postalCode: postalCode ?? this.postalCode,
      isManual: isManual ?? this.isManual,
      isSynced: isSynced ?? this.isSynced,
    );
  }
}
