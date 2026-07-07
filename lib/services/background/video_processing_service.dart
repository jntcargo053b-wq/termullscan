// lib/services/background/video_processing_service.dart
//
// Wrapper tipis di atas flutter_foreground_task.
//
// Tujuannya BUKAN memindahkan eksekusi FFmpeg ke isolate terpisah — proses
// native FFmpeg (via ffmpeg_kit) sudah berjalan di thread native-nya sendiri
// terlepas dari isolate Dart mana yang memanggilnya. Tujuan service ini
// murni untuk menjaga PROSES aplikasi tetap hidup (dengan notifikasi
// foreground) selama TaskQueue sedang merender/mengekspor video, sehingga
// Android tidak membekukan/mematikan proses saat aplikasi di-background.
//
// Dipanggil dari video_scan_screen.dart (dan bisa dipakai screen lain nanti):
//   - VideoProcessingService.init()              -> sekali, saat app start
//   - VideoProcessingService.requestPermissions() -> sekali, sebelum start pertama
//   - VideoProcessingService.startService(...)    -> saat mulai memproses
//   - VideoProcessingService.updateProgress(...)  -> tiap progress berubah
//   - VideoProcessingService.stopService()        -> saat queue benar-benar kosong

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class VideoProcessingService {
  VideoProcessingService._();

  static bool _initialized = false;

  /// Panggil sekali di main(), sebelum runApp().
  static void init() {
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.initCommunicationPort();

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'termulscan_video_export',
        channelName: 'Ekspor Video',
        channelDescription:
            'Menampilkan progres saat TERMULScan sedang merender watermark video.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Minta izin notifikasi (Android 13+) dan battery optimization exemption.
  /// Aman dipanggil berkali-kali; sebaiknya dipanggil sebelum startService
  /// pertama kali (mis. di initState layar rekam video).
  static Future<void> requestPermissions() async {
    final NotificationPermission notifPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notifPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (Platform.isAndroid) {
      // Supaya service tidak langsung dibunuh sistem di beberapa pabrikan
      // (Xiaomi/MIUI, dll) saat aplikasi di-background dalam waktu lama.
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  // ─── Penghitung task aktif bersama (lintas TaskQueue/layar) ──────────
  // TaskQueue di tiap layar hanya tahu status dirinya sendiri. Kalau dua
  // TaskQueue (mis. video + foto) sama-sama memanggil startService/
  // stopService langsung, salah satu bisa mematikan notifikasi padahal
  // TaskQueue lain masih bekerja. Counter statis ini jadi satu-satunya
  // sumber kebenaran: service hanya benar-benar berhenti saat counter-nya
  // kembali ke 0.
  static int _activeCount = 0;

  /// Panggil dari TaskQueue.onActiveStart. Aman dipanggil dari beberapa
  /// TaskQueue sekaligus.
  static Future<void> markBusy({
    String title = 'TERMULScan',
    String text = 'Memproses...',
  }) async {
    _activeCount++;
    if (_activeCount == 1) {
      await startService(title: title, text: text);
    }
  }

  /// Panggil dari TaskQueue.onActiveEnd. Service baru benar-benar dihentikan
  /// saat semua TaskQueue yang memanggil markBusy() sudah selesai.
  static Future<void> markIdle() async {
    if (_activeCount > 0) _activeCount--;
    if (_activeCount == 0) {
      await stopService();
    }
  }

  /// Mulai (atau lanjutkan) foreground service dengan notifikasi berjalan.
  static Future<void> startService({
    String title = 'TERMULScan',
    String text = 'Memproses video...',
  }) async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
        return;
      }

      await FlutterForegroundTask.startService(
        serviceId: 401,
        notificationTitle: title,
        notificationText: text,
        callback: _startCallback,
      );
    } catch (e) {
      // Foreground service gagal start tidak boleh menggagalkan proses
      // rendering video itu sendiri — cukup catat, video tetap lanjut
      // diproses tanpa perlindungan foreground service.
      debugPrint('⚠️ Gagal memulai foreground service: $e');
    }
  }

  /// Perbarui teks notifikasi (mis. persentase progres FFmpeg).
  static Future<void> updateProgress({
    required String title,
    required String text,
  }) async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      }
    } catch (e) {
      debugPrint('⚠️ Gagal update notifikasi foreground service: $e');
    }
  }

  /// Hentikan service. Panggil hanya ketika TaskQueue benar-benar kosong
  /// (tidak ada task pending/running lain yang masih butuh perlindungan ini).
  static Future<void> stopService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('⚠️ Gagal menghentikan foreground service: $e');
    }
  }
}

// Callback top-level wajib untuk flutter_foreground_task (dijalankan di
// isolate service saat pertama kali start).
@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_VideoExportTaskHandler());
}

/// TaskHandler ini sengaja minimal / pasif: pekerjaan FFmpeg yang sebenarnya
/// tetap berjalan di isolate utama lewat TaskQueue seperti sebelumnya.
/// Handler ini hanya menjaga siklus hidup notifikasi foreground service.
class _VideoExportTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('🎬 Foreground service ekspor video dimulai (${starter.name})');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Tidak ada pekerjaan periodik yang perlu dilakukan di sini — teks
    // notifikasi sudah diperbarui langsung dari isolate utama lewat
    // VideoProcessingService.updateProgress().
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('🛑 Foreground service ekspor video berhenti (timeout: $isTimeout)');
  }

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationDismissed() {}
}
