// lib/services/background/video_processing_service.dart
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../queue/job_queue_manager.dart';
import '../../watermark/watermark_service.dart';
import '../../models/video_job.dart';

class VideoProcessingService {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  static Future<void> startService() async {
    await FlutterForegroundTask.startService(
      notificationTitle: 'TermullScan',
      notificationText: 'Mempersiapkan rendering...',
      callback: _startCallback,
    );
  }

  static Future<void> stopService() async {
    await FlutterForegroundTask.stopService();
  }

  @pragma('vm:entry-point')
  static void _startCallback() {
    FlutterForegroundTask.setTaskHandler(_TaskHandler());
  }
}

class _TaskHandler extends TaskHandler {
  final JobQueueManager _queue = JobQueueManager();
  bool _isRunning = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _isRunning = true;
    await _processLoop();
  }

  @override
  Future<void> onEvent(DateTime timestamp, TaskStarter starter) async {
    // Called every 15 seconds, check if we need to process
    if (!_isRunning) {
      _isRunning = true;
      await _processLoop();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, TaskStarter starter) async {
    _isRunning = false;
    // Stop service? 
    FlutterForegroundTask.stopService();
  }

  @override
  void onButtonPressed(String id) {
    // Handle pause/cancel button from notification
    if (id == 'cancel') {
      // Implement cancel logic
    }
  }

  Future<void> _processLoop() async {
    while (_isRunning) {
      // Ambil job pending dari DB (bukan dari manager UI agar tetap terpisah)
      // Idealnya kita punya akses ke database langsung di sini.
      // Untuk contoh sederhana, kita anggap ada static function getNextPending.
      
      // Simulasi proses:
      // var job = await JobDatabase().getNextPending();
      // if (job == null) break;
      
      // Update notification progress
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Rendering Video',
        notificationText: 'Memproses 1/5...',
      );

      // Panggil VideoWatermarkService.addWatermark dengan progress callback
      // Update progress ke notifikasi setiap 5%.
      
      // Jika selesai, update DB status, kirim notifikasi lokal "Selesai".
    }
  }
}
