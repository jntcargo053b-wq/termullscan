import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'watermark/watermark_settings.dart';
import 'services/storage_service.dart';
import 'services/watermark/watermark_service.dart';
import 'services/background/video_processing_service.dart';
import 'services/pod_location_service.dart';
import 'models/scan_entry.dart';

void main() {
  // Global error handler untuk async errors
  runZonedGuarded(
    () async {
      final startTime = DateTime.now();
      WidgetsFlutterBinding.ensureInitialized();

      // Flutter error handler
      FlutterError.onError = (FlutterErrorDetails details) {
        debugPrint('❌ Flutter Error: ${details.exception}');
        // Bisa kirim ke analytics
      };

      // Inisialisasi foreground service
      VideoProcessingService.init();

      // ─── 0. Inisialisasi layanan lokasi ──
      unawaited(PodLocationService.instance.init());

      // ─── 1. Muat watermark settings ──────────────────────────
      final watermarkSettings = WatermarkSettings();
      await watermarkSettings.load();

      // ─── 2. Migrasi data JSON lama ke SQLite ────────────────
      final storage = StorageService();
      await _migrateJsonIfExists(storage);

      // ─── 3. Cleanup file lama di background ──────────────────
      unawaited(storage.cleanupOldFilesInBackground(days: 45));

      // ─── 4. Konfigurasi orientasi dan system UI ─────────────
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppTheme.bg,
      ));

      // ─── 5. Jalankan aplikasi ────────────────────────────────
      runApp(
        ChangeNotifierProvider<WatermarkSettings>(
          create: (_) => watermarkSettings,
          child: const TermulScanApp(),
        ),
      );

      // ─── 6. Post-frame setup ─────────────────────────────────
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final elapsed = DateTime.now().difference(startTime).inMilliseconds;
        debugPrint('⏱️ Cold start completed in ${elapsed}ms');

        unawaited(_preloadWatermarkAfterFirstFrame(watermarkSettings));
      });
    },
    (error, stack) {
      debugPrint('❌ Uncaught async error: $error');
      debugPrint(stack.toString());
    },
  );
}

/// Migrasi data JSON lama ke SQLite (jika ada)
Future<void> _migrateJsonIfExists(StorageService storage) async {
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
    debugPrint('⚠️ Migration error: $e');
  }
}

/// Preload watermark (font, logo, layout) + warm-up FFmpeg
/// Dijalankan SETELAH frame pertama tampil, supaya tidak menahan cold-start
Future<void> _preloadWatermarkAfterFirstFrame(WatermarkSettings watermarkSettings) async {
  try {
    await VideoWatermarkService.preload(watermarkSettings);
    debugPrint('✅ Watermark preload selesai');
  } catch (e) {
    debugPrint('⚠️ Watermark preload error: $e');
  }
  unawaited(VideoWatermarkService.warmUp());
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
