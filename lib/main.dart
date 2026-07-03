import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'watermark/watermark_settings.dart';
import 'services/storage_service.dart';
import 'services/video_watermark_service.dart'; // untuk warmUp()
import 'services/watermark_cache.dart'; // jika kita ekspor cache-nya
import 'models/scan_entry.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ─── 1. Muat watermark settings ──────────────────────────
  final watermarkSettings = WatermarkSettings();
  await watermarkSettings.load();

  // ─── 2. Preload watermark (font, logo, layout) ──────────
  // Asumsikan kita memiliki WatermarkCache singleton yang bisa diinisialisasi
  final cache = WatermarkCache();
  await cache.initialize(watermarkSettings);
  debugPrint('✅ Watermark cache siap (font, logo, layout)');

  // ─── 3. Warm-up FFmpeg (agar panggilan pertama cepat) ──
  // Jalankan di background agar tidak menghambat startup
  unawaited(VideoWatermarkService.warmUp());

  // ─── 4. Inisialisasi database dan migrasi dari JSON ────
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
  // Tidak blocking UI
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

  // ─── 7. Jalankan aplikasi ────────────────────────────────
  runApp(const WHScannerApp());
}

class WHScannerApp extends StatelessWidget {
  const WHScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WH Scanner',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const HomeScreen(),
    );
  }
}
