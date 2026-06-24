// ============================================================
// 5. lib/main.dart (minta izin di awal)
// ============================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'watermark/watermark_settings.dart';
import 'services/permission_service.dart'; // import

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load settings
  final watermarkSettings = WatermarkSettings();
  await watermarkSettings.load();

  // Minta izin di awal
  await PermissionService.requestAllPermissions();

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
