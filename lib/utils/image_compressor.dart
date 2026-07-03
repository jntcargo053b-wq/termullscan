import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';

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
  static const int maxSizeBytes = AppConfig.maxImageSizeMB * 1024 * 1024;
  static const int targetSizeBytes = AppConfig.targetImageSizeKB * 1024;
  static const int maxDimension = 1920;

  static Future<String> compressIfNeeded(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return imagePath;

      final size = await file.length();
      if (size <= maxSizeBytes) {
        debugPrint('✅ Ukuran file $size bytes, tidak perlu kompresi');
        return imagePath;
      }

      debugPrint('⚠️ Ukuran $size bytes, mulai kompresi di isolate...');

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

// Fungsi top-level yang dijalankan di isolate
Future<String> _compressInIsolate(_CompressArgs args) async {
  try {
    final file = File(args.imagePath);
    if (!file.existsSync()) return args.imagePath;

    final bytes = file.readAsBytesSync();
    img.Image? image = img.decodeImage(bytes);
    if (image == null) return args.imagePath;

    if (image.width > args.maxDimension || image.height > args.maxDimension) {
      double scale = args.maxDimension / (image.width > image.height ? image.width : image.height);
      image = img.copyResize(image, width: (image.width * scale).toInt(), height: (image.height * scale).toInt());
    }

    int quality = 85;
    List<int> compressedBytes = img.encodeJpg(image, quality: quality);
    int compressedSize = compressedBytes.length;

    while (compressedSize > args.targetSizeBytes * 2 && quality > 20) {
      quality -= 10;
      compressedBytes = img.encodeJpg(image, quality: quality);
      compressedSize = compressedBytes.length;
    }

    if (compressedSize > args.targetSizeBytes * 3) {
      double scale = (args.targetSizeBytes * 2) / compressedSize;
      scale = scale.clamp(0.3, 0.9);
      final resized = img.copyResize(image, width: (image.width * scale).toInt(), height: (image.height * scale).toInt());
      compressedBytes = img.encodeJpg(resized, quality: quality);
      compressedSize = compressedBytes.length;
    }

    if (compressedSize > args.maxSizeBytes) {
      final scale = 0.7;
      final smaller = img.copyResize(image, width: (image.width * scale).toInt(), height: (image.height * scale).toInt());
      compressedBytes = img.encodeJpg(smaller, quality: 70);
    }

    final dir = file.parent.path;
    final originalName = file.path.split('/').last;
    final baseName = originalName.split('.').first;
    final compressedPath = '$dir/${baseName}_compressed.jpg';
    await File(compressedPath).writeAsBytes(compressedBytes);

    debugPrint('✅ Kompresi selesai: ${compressedSize ~/ 1024}KB (target ~${args.targetSizeBytes ~/ 1024}KB)');
    return compressedPath;
  } catch (e) {
    debugPrint('⚠️ Gagal kompresi di isolate: $e');
    return args.imagePath;
  }
}
