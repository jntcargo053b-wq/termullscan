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
  final int? videoDuration;
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
      type: ScanType.values[_parseInt(json['type']) ?? 0],
      imagePath: json['imagePath'] as String?,
      videoPath: json['videoPath'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(_parseInt(json['timestamp']) ?? 0),
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
      videoDuration: _parseInt(json['videoDuration']),
      isManual: _parseBool(json['isManual']),
      isSynced: _parseBool(json['isSynced']),
    );
  }

  /// sqflite mengembalikan INTEGER (0/1), sedangkan backup JSON lama
  /// bisa saja menyimpan bool asli — terima keduanya supaya tidak crash
  /// saat membaca ulang data dari database.
  static bool _parseBool(dynamic value) {
    if (value is bool) return value;
    if (value is int) return value != 0;
    return false;
  }

  /// ✅ FIX: kolom `type` di skema sqlite dideklarasikan sebagai TEXT,
  /// sementara toJson() menyimpan `type.index` (int). Karena kolom TEXT
  /// punya "type affinity" di SQLite, nilai integer yang di-insert
  /// otomatis dikonversi/tersimpan sebagai teks — jadi saat dibaca
  /// kembali, sqflite bisa mengembalikan String, bukan int. Cast paksa
  /// `as int` pada nilai itu menyebabkan crash
  /// "type 'String' is not a subtype of type 'int' in type cast" saat
  /// aplikasi mencoba update entry lama (mis. menambah path foto baru)
  /// yang datanya sudah kadung tersimpan dalam bentuk teks. Parser ini
  /// menerima int, String angka, maupun num generik supaya proses baca
  /// tidak pernah crash karena perbedaan tipe penyimpanan.
  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Alias untuk fromJson (kompatibilitas dengan database_helper)
  factory ScanEntry.fromMap(Map<String, dynamic> json) => ScanEntry.fromJson(json);

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
      'isManual': isManual ? 1 : 0,
      'isSynced': isSynced ? 1 : 0,
    };
  }

  /// Alias untuk toJson (kompatibilitas dengan database_helper)
  Map<String, dynamic> toMap() => toJson();

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

  /// Alias untuk formattedTimestamp (kompatibilitas)
  String get timestampFormatted => formattedTimestamp;

  String get barcodeFormat => isManual ? 'MANUAL' : type.name.toUpperCase();

  List<String> get photoPaths {
    final paths = <String>[];
    if (imagePath != null && imagePath!.isNotEmpty) {
      if (imagePath!.contains(',')) {
        paths.addAll(imagePath!.split(',').where((p) => p.isNotEmpty));
      } else {
        paths.add(imagePath!);
      }
    }
    return paths;
  }

  String? get videoThumbnail {
    if (videoPath != null && videoPath!.isNotEmpty) {
      final dir = videoPath!.substring(0, videoPath!.lastIndexOf('.'));
      return '${dir}_thumb.jpg';
    }
    return null;
  }

  bool get hasVideo => videoPath != null && videoPath!.isNotEmpty;

  /// Menandakan apakah record ini sudah jadi "satu paket bukti
  /// pengiriman" yang lengkap: ada kode (barcode/manual), ada
  /// dokumentasi visual (foto atau video), dan ada lokasi GPS.
  /// Tidak melibatkan tanda tangan/OTP — hanya elemen yang sudah
  /// ditangkap aplikasi ini.
  bool get isProofComplete =>
      value.isNotEmpty && (photoPaths.isNotEmpty || hasVideo) && hasLocation;

  String get videoDurationFormatted {
    if (videoDuration == null) return '--:--';
    final seconds = videoDuration!;
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

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
