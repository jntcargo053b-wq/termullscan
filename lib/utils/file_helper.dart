import 'dart:io';
import 'package:path_provider/path_provider.dart';

class FileHelper {
  /// Periksa apakah file berada di direktori temporary/cache.
  /// Aman digunakan untuk menentukan apakah file boleh dihapus.
  static Future<bool> isTemporaryFile(String path) async {
    try {
      // 1. Direktori temporary sistem
      final tempDir = await getTemporaryDirectory();
      if (path.startsWith(tempDir.path)) return true;

      // 2. Cache directory aplikasi
      final cacheDir = await getApplicationCacheDirectory();
      if (path.startsWith(cacheDir.path)) return true;
    } catch (_) {}

    // 3. Fallback: cek substring umum
    final lower = path.toLowerCase();
    return lower.contains('/cache/') ||
        lower.contains('/tmp/') ||
        lower.contains('.cache') ||
        lower.contains('_cache') ||
        lower.contains('compressed_');
  }
}
