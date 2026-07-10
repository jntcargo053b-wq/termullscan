import 'dart:async'; // ← untuk unawaited
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart'; // ← TAMBAHKAN
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'watermark/watermark_settings.dart';
import 'services/storage_service.dart';
import 'services/watermark/watermark_service.dart';
import 'services/background/video_processing_service.dart';
import 'services/pod_location_service.dart';
import 'models/scan_entry.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inisialisasi foreground service
  VideoProcessingService.init();

  // ─── 0. Inisialisasi layanan lokasi (idle, load cache lokal) ──
  // GPS TIDAK langsung aktif di sini — hanya memuat koordinat +
  // alamat sesi terakhir dari SharedPreferences agar watermark GPS
  // punya fallback instan sebelum acquireForCapture() dipanggil di
  // layar kamera/scan.
  unawaited(PodLocationService.instance.init());

  // ─── 1. Muat watermark settings ──────────────────────────
  final watermarkSettings = WatermarkSettings();
  await watermarkSettings.load();

  // ─── 2. Preload watermark (font, logo, layout) ──────────
  await VideoWatermarkService.preload(watermarkSettings);
  debugPrint('✅ Watermark preload selesai');

  // ─── 3. Warm-up FFmpeg (background) ──────────────────────
  unawaited(VideoWatermarkService.warmUp());

  // ─── 4. Migrasi data JSON ke SQLite ──────────────────────
  final storage = StorageService();
  try {
    final dir = await getApplicationDocumentsDirectory();
    final jsonFile = File('${dir.path}/scan_log.json');
    if (await jsonFile.exists()) {
      final content = await jsonFile.readAsString();
      if (content.isNotEmpty) {
        final decoded = json.decode(content);
        if (decoded is List) {
          final entries = decoded.map((e) => ScanEntry.fromJson(e)).toList();
          await storage.migrateFromJson(entries);
          await jsonFile.rename('${jsonFile.path}.migrated');
          debugPrint('✅ Migrated ${entries.length} entries from JSON to SQLite');
        }
      }
    }
  } catch (e) {
    debugPrint('⚠️ Migration error: $e (maybe no JSON data)');
  }

  // ─── 5. Cleanup file lama di background ──────────────────
  unawaited(storage.cleanupOldFilesInBackground(days: 45));

  // ─── 6. Konfigurasi orientasi dan system UI ─────────────
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.bg,
  ));

  // ─── 7. Jalankan aplikasi dengan Provider ────────────────
  runApp(
    ChangeNotifierProvider<WatermarkSettings>(
      create: (_) => watermarkSettings, // ← pakai instance yang sudah di-load
      child: const TermulScanApp(),
    ),
  );
}

class TermulScanApp extends StatelessWidget {
  const TermulScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TermulScan',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const HomeScreen(),
    );
  }
}
