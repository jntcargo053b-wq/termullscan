// lib/services/storage_service.dart (tambahkan di bagian atas)
import 'package:saver_gallery/saver_gallery.dart';
import 'package:permission_handler/permission_handler.dart';

// ─── Save to Gallery (PUBLIC) ──────────────────────────────

/// Simpan video ke galeri publik (Android: Movies/TermulScan, iOS: Photo Library)
Future<bool> saveVideoToGallery(String filePath, {String? fileName}) async {
  try {
    final file = File(filePath);
    if (!await file.exists()) {
      debugPrint('❌ File not found: $filePath');
      return false;
    }

    final size = await file.length();
    if (size == 0) {
      debugPrint('❌ File is empty: $filePath');
      return false;
    }

    // 1. Periksa izin
    bool hasPermission = await Permission.storage.isGranted ||
                         await Permission.manageExternalStorage.isGranted;
    if (!hasPermission) {
      hasPermission = await Permission.storage.request().isGranted ||
                      await Permission.manageExternalStorage.request().isGranted;
    }
    if (!hasPermission) {
      debugPrint('❌ Storage permission denied');
      return false;
    }

    // 2. Gunakan SaverGallery untuk menyimpan ke galeri publik
    final saved = await SaverGallery.saveFile(
      file: file,
      name: fileName ?? 'watermarked_${DateTime.now().millisecondsSinceEpoch}.mp4',
      androidRelativePath: 'Movies/TermulScan', // folder publik
    );

    if (saved == true) {
      debugPrint('✅ Video saved to gallery: $filePath');
      return true;
    } else {
      debugPrint('❌ SaverGallery.saveFile returned: $saved');
      return false;
    }
  } catch (e, stack) {
    debugPrint('❌ Error saving video to gallery: $e\n$stack');
    return false;
  }
}

/// Simpan foto ke galeri publik (opsional)
Future<bool> savePhotoToGallery(String filePath, {String? fileName}) async {
  try {
    final file = File(filePath);
    if (!await file.exists()) return false;

    bool hasPermission = await Permission.storage.isGranted ||
                         await Permission.manageExternalStorage.isGranted;
    if (!hasPermission) {
      hasPermission = await Permission.storage.request().isGranted ||
                      await Permission.manageExternalStorage.request().isGranted;
    }
    if (!hasPermission) return false;

    final saved = await SaverGallery.saveImage(
      filePath,
      name: fileName ?? 'watermarked_${DateTime.now().millisecondsSinceEpoch}.jpg',
      androidRelativePath: 'Pictures/TermulScan',
    );

    return saved == true;
  } catch (e) {
    debugPrint('❌ Error saving photo to gallery: $e');
    return false;
  }
}
