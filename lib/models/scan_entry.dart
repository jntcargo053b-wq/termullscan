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
  final String? locationName;
  final String? address;
  final String? city;
  final String? province;
  final String? country;
  final String? postalCode;
  final int? videoDuration; // ← TAMBAHKAN
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
    this.address,
    this.city,
    this.province,
    this.country,
    this.postalCode,
    this.videoDuration,
    this.isManual = false,
    this.isSynced = false,
  });

  // ─── FACTORY ──────────────────────────────────────────────────

  factory ScanEntry.fromJson(Map<String, dynamic> json) {
    return ScanEntry(
      id: json['id'] as String,
      value: json['value'] as String,
      type: ScanType.values[json['type'] as int],
      imagePath: json['imagePath'] as String?,
      videoPath: json['videoPath'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      operatorName: json['operatorName'] as String,
      companyName: json['companyName'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      locationName: json['locationName'] as String?,
      address: json['address'] as String?,
      city: json['city'] as String?,
      province: json['province'] as String?,
      country: json['country'] as String?,
      postalCode: json['postalCode'] as String?,
      videoDuration: json['videoDuration'] as int?,
      isManual: json['isManual'] as bool? ?? false,
      isSynced: json['isSynced'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
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
      'address': address,
      'city': city,
      'province': province,
      'country': country,
      'postalCode': postalCode,
      'videoDuration': videoDuration,
      'isManual': isManual,
      'isSynced': isSynced,
    };
  }

  // ─── GETTERS ──────────────────────────────────────────────────

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

  bool get hasLocation {
    return (locationName != null && locationName!.isNotEmpty) ||
           (address != null && address!.isNotEmpty) ||
           (latitude != null && longitude != null);
  }

  String get formattedTimestamp {
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');
    return dateFormat.format(timestamp);
  }

  String get barcodeFormat => type == ScanType.manual ? 'MANUAL' : type.name.toUpperCase();

  List<String> get photoPaths {
    final paths = <String>[];
    if (imagePath != null && imagePath!.isNotEmpty) {
      // Jika ada multiple foto, split
      if (imagePath!.contains(',')) {
        paths.addAll(imagePath!.split(',').where((p) => p.isNotEmpty));
      } else {
        paths.add(imagePath!);
      }
    }
    return paths;
  }

  String? get videoThumbnail {
    // Jika videoPath ada, thumbnail biasanya di folder yang sama
    if (videoPath != null && videoPath!.isNotEmpty) {
      final dir = videoPath!.substring(0, videoPath!.lastIndexOf('.'));
      return '$dir_thumb.jpg';
    }
    return null;
  }

  String get timestampFormatted => formattedTimestamp;

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
    String? address,
    String? city,
    String? province,
    String? country,
    String? postalCode,
    int? videoDuration,
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
      address: address ?? this.address,
      city: city ?? this.city,
      province: province ?? this.province,
      country: country ?? this.country,
      postalCode: postalCode ?? this.postalCode,
      videoDuration: videoDuration ?? this.videoDuration,
      isManual: isManual ?? this.isManual,
      isSynced: isSynced ?? this.isSynced,
    );
  }
}
