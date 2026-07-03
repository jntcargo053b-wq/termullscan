import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class VideoTask {
  final String id;
  final String inputPath;
  final String outputPath;
  final String barcode;
  final String operatorName;
  final String companyName;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final DateTime timestamp;
  final int maxDurationSeconds;
  final bool compress;
  VideoStatus status;
  String? hash;
  double progress; // 0.0 - 1.0
  String? errorMessage;
  int retryCount;

  VideoTask({
    required this.id,
    required this.inputPath,
    required this.outputPath,
    required this.barcode,
    required this.operatorName,
    required this.companyName,
    this.latitude,
    this.longitude,
    this.locationName,
    required this.timestamp,
    this.maxDurationSeconds = 30,
    this.compress = true,
    this.status = VideoStatus.pending,
    this.hash,
    this.progress = 0.0,
    this.errorMessage,
    this.retryCount = 0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'inputPath': inputPath,
    'outputPath': outputPath,
    'barcode': barcode,
    'operatorName': operatorName,
    'companyName': companyName,
    'latitude': latitude,
    'longitude': longitude,
    'locationName': locationName,
    'timestamp': timestamp.toIso8601String(),
    'maxDurationSeconds': maxDurationSeconds,
    'compress': compress,
    'status': status.index,
    'hash': hash,
    'progress': progress,
    'errorMessage': errorMessage,
    'retryCount': retryCount,
  };

  factory VideoTask.fromJson(Map<String, dynamic> json) => VideoTask(
    id: json['id'],
    inputPath: json['inputPath'],
    outputPath: json['outputPath'],
    barcode: json['barcode'],
    operatorName: json['operatorName'],
    companyName: json['companyName'],
    latitude: json['latitude'],
    longitude: json['longitude'],
    locationName: json['locationName'],
    timestamp: DateTime.parse(json['timestamp']),
    maxDurationSeconds: json['maxDurationSeconds'],
    compress: json['compress'],
    status: VideoStatus.values[json['status']],
    hash: json['hash'],
    progress: json['progress'],
    errorMessage: json['errorMessage'],
    retryCount: json['retryCount'],
  );

  // Hitung SHA-256 hash dari file
  static Future<String> computeHash(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}

enum VideoStatus {
  pending,
  processing,
  compressing,
  watermarking,
  done,
  failed,
  cancelled,
}
