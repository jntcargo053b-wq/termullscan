import 'package:intl/intl.dart';

enum ScanType { barcode, photo }

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
  });

  bool get hasMultiplePhotos => photoPaths != null && photoPaths!.length > 1;

  String get firstPhotoPath => photoPaths?.isNotEmpty == true ? photoPaths!.first : value;

  String get timestampFormatted =>
      DateFormat('dd-MM-yyyy HH:mm:ss').format(timestamp);

  String get timestampShort =>
      DateFormat('dd/MM HH:mm').format(timestamp);

  String get coordinatesString {
    if (latitude == null || longitude == null) return 'tidak tersedia';
    return '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}';
  }

  bool get isBarcode => type == ScanType.barcode;
  bool get isPhoto => type == ScanType.photo;

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
  };

  factory ScanEntry.fromJson(Map<String, dynamic> j) => ScanEntry(
    id: j['id'],
    type: (() {
      final v = j['type'];
      for (final e in ScanType.values) {
        if (e.name == v) return e;
      }
      return ScanType.photo;
    })(),
    value: j['value'],
    barcodeFormat: j['barcodeFormat'],
    timestamp: DateTime.parse(j['timestamp']),
    latitude: (j['latitude'] as num?)?.toDouble(),
    longitude: (j['longitude'] as num?)?.toDouble(),
    locationName: j['locationName'],
    note: j['note'],
    photoPaths: (j['photoPaths'] as List?)?.cast<String>(),
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
  };

  // ✅ Perbaikan: tambahkan orElse agar tidak crash jika type tidak dikenal
  factory ScanEntry.fromMap(Map<String, dynamic> map) => ScanEntry(
    id: map['id'],
    type: ScanType.values.firstWhere(
      (e) => e.name == map['type'],
      orElse: () => ScanType.photo, // ← aman jika type null atau tidak dikenal
    ),
    value: map['value'],
    barcodeFormat: map['barcodeFormat'],
    timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp']),
    latitude: map['latitude'] as double?,
    longitude: map['longitude'] as double?,
    locationName: map['locationName'],
    note: map['note'],
    photoPaths: (map['photoPaths'] as String?)?.split(',').where((s) => s.isNotEmpty).toList(),
  );

  // ─── Copy ────────────────────────────────────────────────
  ScanEntry copyWith({
    String? value,
    double? latitude,
    double? longitude,
    String? locationName,
    String? note,
    List<String>? photoPaths,
  }) => ScanEntry(
    id: id,
    type: type,
    value: value ?? this.value,
    barcodeFormat: barcodeFormat,
    timestamp: timestamp,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    locationName: locationName ?? this.locationName,
    note: note ?? this.note,
    photoPaths: photoPaths ?? this.photoPaths,
  );
}
