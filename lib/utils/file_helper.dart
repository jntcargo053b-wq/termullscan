import 'dart:io';
import 'package:path_provider/path_provider.dart';

class FileHelper {
  // ... isTemporaryFile() sudah ada ...

  /// Hapus file jika ada dan tidak error.
  static Future<void> deleteIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Hapus semua file di direktori temporary yang mengandung pola tertentu.
  static Future<void> cleanTempFiles({String contains = 'wm_'}) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final files = await tempDir.list().where((e) => e is File && e.path.contains(contains)).toList();
      for (final f in files) {
        try { await File(f.path).delete(); } catch (_) {}
      }
    } catch (_) {}
  }

  /// Periksa apakah file berada di direktori Documents (internal aplikasi).
  static Future<bool> isInternalFile(String path) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      return path.startsWith(appDir.path);
    } catch (_) => false;
  }
}
