// lib/models/video_job.dart
import 'package:sqflite/sqflite.dart';

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
      'settings': settings.toString(), // Simpan JSON
    };
  }

  factory VideoJob.fromMap(Map<String, dynamic> map) {
    return VideoJob(
      id: map['id'],
      inputPath: map['inputPath'],
      outputPath: map['outputPath'],
      originalFilename: map['originalFilename'],
      status: JobStatus.values[map['status']],
      progress: map['progress']?.toDouble() ?? 0.0,
      errorMessage: map['errorMessage'] ?? '',
      createdAt: DateTime.parse(map['createdAt']),
      updatedAt: map['updatedAt'] != null ? DateTime.parse(map['updatedAt']) : null,
      settings: Map<String, dynamic>.from(map['settings']), // Parsing JSON
    );
  }
}
