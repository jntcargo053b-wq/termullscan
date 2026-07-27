// lib/models/video_job.dart
import 'dart:convert';

enum JobStatus { pending, processing, paused, completed, failed, cancelled }

class VideoJob {
  int? id;
  final String inputPath;
  final String outputPath;
  final String originalFilename;
  final JobStatus status;
  final double progress; // 0.0 - 1.0
  final String errorMessage;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final Map<String, dynamic> settings; // Simpan WatermarkSettings sebagai JSON

  VideoJob({
    this.id,
    required this.inputPath,
    required this.outputPath,
    required this.originalFilename,
    this.status = JobStatus.pending,
    this.progress = 0.0,
    this.errorMessage = '',
    required this.createdAt,
    this.updatedAt,
    required this.settings,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'inputPath': inputPath,
      'outputPath': outputPath,
      'originalFilename': originalFilename,
      'status': status.index,
      'progress': progress,
      'errorMessage': errorMessage,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
      'settings': jsonEncode(settings),
    };
  }

  factory VideoJob.fromMap(Map<String, dynamic> map) {
    final rawSettings = map['settings'];
    Map<String, dynamic> parsedSettings = <String, dynamic>{};
    if (rawSettings is String && rawSettings.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSettings);
        if (decoded is Map) {
          parsedSettings = Map<String, dynamic>.from(decoded);
        }
      } on FormatException {
        // Versi lama menyimpan Map.toString(), yang bukan JSON valid.
        parsedSettings = <String, dynamic>{};
      }
    } else if (rawSettings is Map) {
      parsedSettings = Map<String, dynamic>.from(rawSettings);
    }

    return VideoJob(
      id: map['id'] as int?,
      inputPath: map['inputPath'] as String,
      outputPath: map['outputPath'] as String,
      originalFilename: map['originalFilename'] as String,
      status: JobStatus.values[map['status'] as int],
      progress: map['progress']?.toDouble() ?? 0.0,
      errorMessage: map['errorMessage'] as String? ?? '',
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: map['updatedAt'] != null
          ? DateTime.parse(map['updatedAt'] as String)
          : null,
      settings: parsedSettings,
    );
  }

  VideoJob copyWith({
    int? id,
    String? inputPath,
    String? outputPath,
    String? originalFilename,
    JobStatus? status,
    double? progress,
    String? errorMessage,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? settings,
  }) {
    return VideoJob(
      id: id ?? this.id,
      inputPath: inputPath ?? this.inputPath,
      outputPath: outputPath ?? this.outputPath,
      originalFilename: originalFilename ?? this.originalFilename,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      settings: settings ?? this.settings,
    );
  }
}
