import 'dart:io';
import 'package:path_provider/path_provider.dart';

class FileHelper {
  /// Periksa apakah file berada di direktori temporary/cache.
  static Future<bool> isTemporaryFile(String path) async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (path.startsWith(tempDir.path)) return true;
      final cacheDir = await getApplicationCacheDirectory();
      if (path.startsWith(cacheDir.path)) return true;
    } catch (_) {
      // Ignore
    }
    final lower = path.toLowerCase();
    return lower.contains('/cache/') ||
        lower.contains('/tmp/') ||
        lower.contains('.cache') ||
        lower.contains('_cache') ||
        lower.contains('compressed_');
  }

  /// Hapus file jika ada (tidak error).
  static Future<void> deleteIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Ignore
    }
  }

  /// Hapus semua file di temporary yang mengandung pola tertentu.
  static Future<void> cleanTempFiles({String contains = 'wm_'}) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final files = await tempDir.list().where((e) => e is File && e.path.contains(contains)).toList();
      for (final f in files) {
        try {
          await File(f.path).delete();
        } catch (_) {
          // Ignore
        }
      }
    } catch (_) {
      // Ignore
    }
  }

  /// Periksa apakah file berada di direktori Documents (internal aplikasi).
  static Future<bool> isInternalFile(String path) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      return path.startsWith(appDir.path);
    } catch (_) {
      return false;
    }
  }
}
