import 'storage_service.dart';

/// API kompatibilitas untuk pemanggil lama.
///
/// Implementasi backup/restore hanya berada di [StorageService] agar tidak ada
/// dua format ZIP dengan perilaku restore yang berbeda.
class BackupService {
  BackupService._();

  static final StorageService _storage = StorageService();

  static Future<String> backup() => _storage.backup();

  static Future<bool> restore(String zipPath) => _storage.restore(zipPath);

  static Future<void> shareBackup(String zipPath) =>
      _storage.shareBackup(zipPath);
}
