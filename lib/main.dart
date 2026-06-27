// ============================================================
// lib/main.dart (load watermark settings sekali)
// ============================================================
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'watermark/watermark_settings.dart';
import 'services/permission_service.dart';
import 'services/storage_service.dart';
import 'models/scan_entry.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ─── Load watermark settings (sekali) ──────────────────────
  final watermarkSettings = WatermarkSettings();
  await watermarkSettings.load();

  // ─── Migrasi JSON → SQLite ──────────────────────────────────
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

  // ─── Cleanup old photos (45 days) ──────────────────────────
  await storage.cleanupOldFiles(days: 45);

  // ─── Izin ────────────────────────────────────────────────────
  await PermissionService.requestAllPermissions();

  // ─── Orientasi ──────────────────────────────────────────────
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.bg,
  ));

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
