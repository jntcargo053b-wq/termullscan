// ============================================================
// 1. lib/config/app_config.dart (FIX - ubah maxWidth menjadi double)
// ============================================================
class AppConfig {
  static const bool enableGps = false;

  // Kompresi foto
  static const int maxImageSizeMB = 5;          // Maksimal sebelum kompresi (5MB)
  static const int targetImageSizeKB = 1024;    // Target ukuran setelah kompresi (~1MB)
  static const int imageQuality = 80;           // Kualitas default
  static const double maxWidth = 1600.0;        // Lebar maksimal (HARUS double)
}
