// lib/services/queue/job_queue_manager.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../models/video_job.dart';
import '../database/job_database.dart';

class JobQueueManager extends ChangeNotifier {
  static final JobQueueManager _instance = JobQueueManager._internal();
  factory JobQueueManager() => _instance;
  JobQueueManager._internal();

  final JobDatabase _db = JobDatabase();
  List<VideoJob> _jobs = [];
  bool _isProcessing = false;
  StreamSubscription? _progressSubscription;

  List<VideoJob> get jobs => _jobs;
  List<VideoJob> get pendingJobs => _jobs.where((j) => j.status == JobStatus.pending).toList();
  List<VideoJob> get processingJobs => _jobs.where((j) => j.status == JobStatus.processing).toList();
  int get totalJobs => _jobs.length;
  int get completedJobs => _jobs.where((j) => j.status == JobStatus.completed).toList().length;

  // Load jobs from DB on startup
  Future<void> loadJobs() async {
    _jobs = await _db.getJobs();
    notifyListeners();
  }

  // Add job to queue
  Future<void> addJob(VideoJob job) async {
    final id = await _db.insertJob(job);
    job.id = id;
    _jobs.add(job);
    notifyListeners();
    _processNext(); // Try to process immediately
  }

  // Start processing
  void _processNext() async {
    if (_isProcessing) return;
    final nextJob = _jobs.firstWhere(
      (j) => j.status == JobStatus.pending,
      orElse: () => throw StateError('No pending jobs'),
    );
    _isProcessing = true;
    // Kirim job ke Background Service
    // Kita panggil method static yang akan dijalankan di isolate terpisah
    // (Lihat bagian 4 untuk implementasi background)
    await _startProcessingJob(nextJob);
  }

  Future<void> _startProcessingJob(VideoJob job) async {
    // Update status
    job.status = JobStatus.processing;
    await _db.updateJob(job);
    notifyListeners();

    // Panggil VideoProcessingService di background
    // (Isolate/foreground service logic)
    try {
      // Simulasi/actual processing
      // VideoProcessingService.processJob(job, (progress) => updateProgress(job, progress));
    } catch (e) {
      job.status = JobStatus.failed;
      job.errorMessage = e.toString();
      await _db.updateJob(job);
      notifyListeners();
    } finally {
      _isProcessing = false;
      _processNext(); // Process next pending
    }
  }

  Future<void> updateProgress(VideoJob job, double progress) async {
    job.progress = progress;
    await _db.updateJob(job);
    notifyListeners();
  }

  // Pause (mark as pending, but don't process)
  Future<void> pauseJob(int id) async {
    final job = _jobs.firstWhere((j) => j.id == id);
    job.status = JobStatus.paused;
    await _db.updateJob(job);
    notifyListeners();
    // If currently processing this job? We need to interrupt the isolate.
    // For now, we just don't pick it up next loop.
  }

  Future<void> resumeJob(int id) async {
    final job = _jobs.firstWhere((j) => j.id == id);
    job.status = JobStatus.pending;
    await _db.updateJob(job);
    notifyListeners();
    _processNext();
  }

  Future<void> cancelJob(int id) async {
    final job = _jobs.firstWhere((j) => j.id == id);
    job.status = JobStatus.cancelled;
    await _db.updateJob(job);
    notifyListeners();
  }

  Future<void> retryJob(int id) async {
    final job = _jobs.firstWhere((j) => j.id == id);
    job.status = JobStatus.pending;
    job.progress = 0.0;
    job.errorMessage = '';
    await _db.updateJob(job);
    notifyListeners();
    _processNext();
  }

  Future<void> clearCompleted() async {
    await _db.clearCompleted();
    _jobs.removeWhere((j) => j.status == JobStatus.completed || j.status == JobStatus.cancelled);
    notifyListeners();
  }
}
