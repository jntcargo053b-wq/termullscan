// lib/utils/image_compressor.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class ImageCompressor {
  static Future<Uint8List> compressInIsolate({
    required ui.Image image,
    int quality = 85,
  }) async {
    // Ambil byte data dari ui.Image (PNG)
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final pngBytes = byteData!.buffer.asUint8List();

    // Kirim ke isolate
    final result = await compute(_compressIsolate, _CompressArgs(
      pngBytes: pngBytes,
      quality: quality,
      maxDimension: 1920,
    ));
    return result;
  }
}

class _CompressArgs {
  final Uint8List pngBytes;
  final int quality;
  final int maxDimension;
  _CompressArgs({required this.pngBytes, required this.quality, required this.maxDimension});
}

Uint8List _compressIsolate(_CompressArgs args) {
  final image = img.decodeImage(args.pngBytes);
  if (image == null) return args.pngBytes;

  // Resize jika perlu
  img.Image? processed = image;
  if (image.width > args.maxDimension || image.height > args.maxDimension) {
    double scale = args.maxDimension / (image.width > image.height ? image.width : image.height);
    processed = img.copyResize(image, width: (image.width * scale).toInt(), height: (image.height * scale).toInt());
  }

  // Encode ke JPEG
  final jpegBytes = img.encodeJpg(processed, quality: args.quality);
  return Uint8List.fromList(jpegBytes);
}
