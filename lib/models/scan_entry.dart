// ============================================================
// lib/models/scan_entry.dart (FINAL - VIDEO SUPPORT)
// ============================================================
import 'dart:convert';
import 'package:intl/intl.dart';

enum ScanType { barcode, photo, video }

class ScanEntry {
  final String id;
  final ScanType type;
  final String value;
  final String? barcodeFormat;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String? note;
  final List<String>? photoPaths;

  // ─── VIDEO FIELDS ────────────────────────────────────
  final String? videoPath;
  final int? videoDuration; // dalam detik
  final String? videoThumbnail;

  ScanEntry({
    required this.id,
    required this.type,
    required this.value,
    this.barcodeFormat,
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.locationName,
    this.note,
    this.photoPaths,
    this.videoPath,
    this.videoDuration,
    this.videoThumbnail,
  });

  // ─── GETTERS ─────────────────────────────────────────
  bool get hasMultiplePhotos => photoPaths != null && photoPaths!.length > 1;
  bool get hasPhotos => photoPaths != null && photoPaths!.isNotEmpty;
  bool get hasVideo => videoPath != null && videoPath!.isNotEmpty;
  bool get isVideo => type == ScanType.video;
  bool get isBarcode => type == ScanType.barcode;
  bool get isPhoto => type == ScanType.photo;

  String get firstPhotoPath => photoPaths?.isNotEmpty == true
      ? photoPaths!.first
      : value;

  String get timestampFormatted =>
      DateFormat('dd-MM-yyyy HH:mm:ss').format(timestamp);

  String get timestampShort =>
      DateFormat('dd/MM HH:mm').format(timestamp);

  String get coordinatesString {
    if (latitude == null || longitude == null) return 'tidak tersedia';
    return '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}';
  }

  String get videoDurationFormatted {
    if (videoDuration == null) return '';
    final min = videoDuration! ~/ 60;
    final sec = videoDuration! % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  // ─── JSON ──────────────────────────────────────────────
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'value': value,
    'barcodeFormat': barcodeFormat,
    'timestamp': timestamp.toIso8601String(),
    'latitude': latitude,
    'longitude': longitude,
    'locationName': locationName,
    'note': note,
    'photoPaths': photoPaths,
    'videoPath': videoPath,
    'videoDuration': videoDuration,
    'videoThumbnail': videoThumbnail,
  };

  factory ScanEntry.fromJson(Map<String, dynamic> j) => ScanEntry(
    id: j['id'] as String,
    type: _parseType(j['type'] as String?),
    value: j['value'] as String,
    barcodeFormat: j['barcodeFormat'] as String?,
    timestamp: DateTime.parse(j['timestamp'] as String),
    latitude: (j['latitude'] as num?)?.toDouble(),
    longitude: (j['longitude'] as num?)?.toDouble(),
    locationName: j['locationName'] as String?,
    note: j['note'] as String?,
    photoPaths: (j['photoPaths'] as List<dynamic>?)?.cast<String>(),
    videoPath: j['videoPath'] as String?,
    videoDuration: j['videoDuration'] as int?,
    videoThumbnail: j['videoThumbnail'] as String?,
  );

  // ─── SQLite ──────────────────────────────────────────────
  Map<String, dynamic> toMap() => {
    'id': id,
    'type': type.name,
    'value': value,
    'barcodeFormat': barcodeFormat,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'latitude': latitude,
    'longitude': longitude,
    'locationName': locationName,
    'note': note,
    'photoPaths': photoPaths?.join(','),
    'videoPath': videoPath,
    'videoDuration': videoDuration,
    'videoThumbnail': videoThumbnail,
  };

  factory ScanEntry.fromMap(Map<String, dynamic> map) => ScanEntry(
    id: map['id'] as String,
    type: _parseType(map['type'] as String?),
    value: map['value'] as String,
    barcodeFormat: map['barcodeFormat'] as String?,
    timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
    latitude: (map['latitude'] as num?)?.toDouble(),
    longitude: (map['longitude'] as num?)?.toDouble(),
    locationName: map['locationName'] as String?,
    note: map['note'] as String?,
    photoPaths: (map['photoPaths'] as String?)
        ?.split(',')
        .where((s) => s.isNotEmpty)
        .toList(),
    videoPath: map['videoPath'] as String?,
    videoDuration: map['videoDuration'] as int?,
    videoThumbnail: map['videoThumbnail'] as String?,
  );

  // ─── Copy ────────────────────────────────────────────────
  ScanEntry copyWith({
    String? id,
    ScanType? type,
    String? value,
    String? barcodeFormat,
    DateTime? timestamp,
    double? latitude,
    double? longitude,
    String? locationName,
    String? note,
    List<String>? photoPaths,
    String? videoPath,
    int? videoDuration,
    String? videoThumbnail,
  }) =>
      ScanEntry(
        id: id ?? this.id,
        type: type ?? this.type,
        value: value ?? this.value,
        barcodeFormat: barcodeFormat ?? this.barcodeFormat,
        timestamp: timestamp ?? this.timestamp,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        locationName: locationName ?? this.locationName,
        note: note ?? this.note,
        photoPaths: photoPaths ?? this.photoPaths,
        videoPath: videoPath ?? this.videoPath,
        videoDuration: videoDuration ?? this.videoDuration,
        videoThumbnail: videoThumbnail ?? this.videoThumbnail,
      );

  // ─── Helper ────────────────────────────────────────────
  static ScanType _parseType(String? name) {
    if (name == null) return ScanType.photo;
    return ScanType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => ScanType.photo,
    );
  }
}
