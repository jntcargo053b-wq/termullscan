import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/foundation.dart';

class BackupService {
  /// Export database + folder foto & video menjadi file ZIP.
  /// Kembalikan path ZIP yang dibuat.
  static Future<String> backup() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dbFile = File(join(appDir.path, 'scan_log.db'));
    final photosDir = Directory(join(appDir.path, 'photos'));
    final videosDir = Directory(join(appDir.path, 'videos'));

    final archive = Archive();

    // Tambahkan file database
    if (await dbFile.exists()) {
      archive.addFile(ArchiveFile('scan_log.db', await dbFile.length(), dbFile.openRead()));
    }

    // Tambahkan foto
    if (await photosDir.exists()) {
      await for (final entity in photosDir.list()) {
        if (entity is File) {
          final bytes = await entity.readAsBytes();
          archive.addFile(ArchiveFile('photos/${entity.path.split('/').last}', bytes.length, Stream.value(bytes)));
        }
      }
    }

    // Tambahkan video
    if (await videosDir.exists()) {
      await for (final entity in videosDir.list()) {
        if (entity is File) {
          final bytes = await entity.readAsBytes();
          archive.addFile(ArchiveFile('videos/${entity.path.split('/').last}', bytes.length, Stream.value(bytes)));
        }
      }
    }

    // Encode ZIP
    final zipData = ZipEncoder().encode(archive);
    final backupDir = await getExternalStorageDirectory(); // atau Downloads
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final zipPath = '${backupDir!.path}/termulscan_backup_$timestamp.zip';
    await File(zipPath).writeAsBytes(zipData);

    debugPrint('✅ Backup berhasil: $zipPath');
    return zipPath;
  }

  /// Restore dari file ZIP.
  static Future<bool> restore(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final appDir = await getApplicationDocumentsDirectory();

      for (final file in archive) {
        if (file.isFile) {
          final filePath = join(appDir.path, file.name);
          await File(filePath).parent.create(recursive: true);
          await File(filePath).writeAsBytes(file.content as List<int>);
        }
      }

      debugPrint('✅ Restore berhasil dari $zipPath');
      return true;
    } catch (e) {
      debugPrint('❌ Restore gagal: $e');
      return false;
    }
  }

  /// Bagikan file backup.
  static Future<void> shareBackup(String zipPath) async {
    await Share.shareXFiles([XFile(zipPath)], text: 'Backup TermulScan');
  }
}
