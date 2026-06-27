// ============================================================
// lib/utils/image_compressor.dart (FINAL - resize + kompresi)
// ============================================================
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';

class ImageCompressor {
  static const int maxSizeBytes = AppConfig.maxImageSizeMB * 1024 * 1024; // 5MB
  static const int targetSizeBytes = AppConfig.targetImageSizeKB * 1024; // 1MB
  static const int maxDimension = 1920; // ✅ batas maksimal lebar/tinggi

  /// Resize dan kompres gambar ke ukuran optimal.
  /// Mengembalikan path file hasil (atau path asli jika tidak perlu).
  static Future<String> compressIfNeeded(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return imagePath;

      final size = await file.length();
      if (size <= maxSizeBytes) {
        debugPrint('✅ Ukuran file $size bytes, tidak perlu kompresi');
        return imagePath;
      }

      debugPrint('⚠️ Ukuran file $size bytes (>${AppConfig.maxImageSizeMB}MB), mulai kompresi...');

      // Baca gambar
      final bytes = await file.readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) return imagePath;

      // ✅ STEP 1: Resize jika dimensi > maxDimension
      if (image.width > maxDimension || image.height > maxDimension) {
        double scale = maxDimension / (image.width > image.height ? image.width : image.height);
        int newWidth = (image.width * scale).toInt();
        int newHeight = (image.height * scale).toInt();
        image = img.copyResize(image, width: newWidth, height: newHeight);
        debugPrint('  Resize ke ${newWidth}x${newHeight}');
      }

      // ✅ STEP 2: Kompresi dengan kualitas adaptif
      int quality = 75;
      List<int> compressedBytes = img.encodeJpg(image, quality: quality);
      int compressedSize = compressedBytes.length;

      // Turunkan kualitas sampai target atau quality 20
      while (compressedSize > targetSizeBytes * 2 && quality > 20) {
        quality -= 10;
        compressedBytes = img.encodeJpg(image, quality: quality);
        compressedSize = compressedBytes.length;
        debugPrint('  Kualitas $quality% → ukuran ${compressedSize ~/ 1024}KB');
      }

      // Jika masih terlalu besar, turunkan resolusi lagi
      if (compressedSize > targetSizeBytes * 3) {
        double scale = (targetSizeBytes * 2) / compressedSize;
        scale = scale.clamp(0.3, 0.9);
        final newWidth = (image.width * scale).toInt();
        final newHeight = (image.height * scale).toInt();
        final resized = img.copyResize(image, width: newWidth, height: newHeight);
        final finalBytes = img.encodeJpg(resized, quality: quality);
        compressedSize = finalBytes.length;
        debugPrint('  Resize kedua ke ${newWidth}x${newHeight}, ukuran ${compressedSize ~/ 1024}KB');
        compressedBytes = finalBytes;
      }

      // Simpan hasil kompresi
      final dir = file.parent.path;
      final filename = 'compressed_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final compressedPath = '$dir/$filename';
      await File(compressedPath).writeAsBytes(compressedBytes);

      debugPrint('✅ Kompresi selesai: ${compressedSize ~/ 1024}KB (target ~${AppConfig.targetImageSizeKB}KB)');
      return compressedPath;
    } catch (e) {
      debugPrint('⚠️ Gagal kompresi: $e, menggunakan file asli');
      return imagePath;
    }
  }
}
