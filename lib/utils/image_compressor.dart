// ============================================================
// lib/utils/image_compressor.dart (FINAL - dengan Isolate)
// ============================================================
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';

/// Argumen untuk dikirim ke isolate
class _CompressArgs {
  final String imagePath;
  final int maxSizeBytes;
  final int targetSizeBytes;
  final int maxDimension;

  _CompressArgs({
    required this.imagePath,
    required this.maxSizeBytes,
    required this.targetSizeBytes,
    required this.maxDimension,
  });
}

class ImageCompressor {
  static const int maxSizeBytes = AppConfig.maxImageSizeMB * 1024 * 1024; // 5MB
  static const int targetSizeBytes = AppConfig.targetImageSizeKB * 1024; // 1MB
  static const int maxDimension = 1920;

  /// Kompres gambar di isolate terpisah agar UI tidak freeze.
  /// Mengembalikan path file hasil (atau path asli jika tidak perlu).
  static Future<String> compressIfNeeded(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return imagePath;

      final size = await file.length();
      // Jika ukuran sudah <= batas, tidak perlu kompresi
      if (size <= maxSizeBytes) {
        debugPrint('✅ Ukuran file $size bytes, tidak perlu kompresi');
        return imagePath;
      }

      debugPrint('⚠️ Ukuran file $size bytes (>${AppConfig.maxImageSizeMB}MB), mulai kompresi di isolate...');

      // Kirim ke isolate
      final args = _CompressArgs(
        imagePath: imagePath,
        maxSizeBytes: maxSizeBytes,
        targetSizeBytes: targetSizeBytes,
        maxDimension: maxDimension,
      );

      final result = await compute(_compressInIsolate, args);
      return result;
    } catch (e) {
      debugPrint('⚠️ Gagal kompresi: $e, menggunakan file asli');
      return imagePath;
    }
  }
}

/// Fungsi yang berjalan di isolate.
/// Tidak boleh mengakses variabel global atau context UI.
String _compressInIsolate(_CompressArgs args) {
  try {
    final file = File(args.imagePath);
    if (!file.existsSync()) return args.imagePath;

    // Baca gambar
    final bytes = file.readAsBytesSync();
    img.Image? image = img.decodeImage(bytes);
    if (image == null) return args.imagePath;

    // STEP 1: Resize jika dimensi > maxDimension
    if (image.width > args.maxDimension || image.height > args.maxDimension) {
      double scale = args.maxDimension / (image.width > image.height ? image.width : image.height);
      int newWidth = (image.width * scale).toInt();
      int newHeight = (image.height * scale).toInt();
      image = img.copyResize(image, width: newWidth, height: newHeight);
    }

    // STEP 2: Kompresi dengan kualitas adaptif
    int quality = 75;
    List<int> compressedBytes = img.encodeJpg(image, quality: quality);
    int compressedSize = compressedBytes.length;

    // Turunkan kualitas sampai target atau quality 20
    while (compressedSize > args.targetSizeBytes * 2 && quality > 20) {
      quality -= 10;
      compressedBytes = img.encodeJpg(image, quality: quality);
      compressedSize = compressedBytes.length;
    }

    // Jika masih terlalu besar, turunkan resolusi lagi
    if (compressedSize > args.targetSizeBytes * 3) {
      double scale = (args.targetSizeBytes * 2) / compressedSize;
      scale = scale.clamp(0.3, 0.9);
      final newWidth = (image.width * scale).toInt();
      final newHeight = (image.height * scale).toInt();
      final resized = img.copyResize(image, width: newWidth, height: newHeight);
      final finalBytes = img.encodeJpg(resized, quality: quality);
      compressedSize = finalBytes.length;
      compressedBytes = finalBytes;
    }

    // Simpan hasil kompresi
    final dir = file.parent.path;
    final filename = 'compressed_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final compressedPath = '$dir/$filename';
    File(compressedPath).writeAsBytesSync(compressedBytes);

    debugPrint('✅ Kompresi selesai di isolate: ${compressedSize ~/ 1024}KB (target ~${args.targetSizeBytes ~/ 1024}KB)');
    return compressedPath;
  } catch (e) {
    debugPrint('⚠️ Gagal kompresi di isolate: $e');
    return args.imagePath;
  }
}
