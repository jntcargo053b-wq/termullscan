import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ── Isolate payload ─────────────────────────────────────────────────────
class _WatermarkTask {
  final String imagePath;
  final String outputPath;
  final String? barcodeValue;
  final String? barcodeFormat;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String operatorName;
  final String? logoPath;
  final SendPort replyTo;

  const _WatermarkTask({
    required this.imagePath,
    required this.outputPath,
    required this.barcodeValue,
    required this.barcodeFormat,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.locationName,
    required this.operatorName,
    required this.logoPath,
    required this.replyTo,
  });
}

/// Entry-point isolate — top-level function.
void _watermarkIsolate(_WatermarkTask task) async {
  try {
    final result = await _renderWatermark(task);
    task.replyTo.send(result);
  } catch (e) {
    task.replyTo.send(null);
  }
}

/// Fungsi render watermark (berjalan di isolate terpisah).
Future<String?> _renderWatermark(_WatermarkTask task) async {
  final imageBytes = await File(task.imagePath).readAsBytes();
  final codec = await ui.instantiateImageCodec(imageBytes);
  final frame = await codec.getNextFrame();
  final srcImage = frame.image;

  final width = srcImage.width.toDouble();
  final height = srcImage.height.toDouble();

  // Load logo jika ada
  ui.Image? logoImage;
  if (task.logoPath != null) {
    try {
      final logoFile = File(task.logoPath!);
      if (await logoFile.exists()) {
        final logoBytes = await logoFile.readAsBytes();
        final logoCodec =
            await ui.instantiateImageCodec(logoBytes, targetWidth: 160);
        final logoFrame = await logoCodec.getNextFrame();
        logoImage = logoFrame.image;
      }
    } catch (_) {}
  }

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
  canvas.drawImage(srcImage, Offset.zero, Paint());

  // Teks watermark
  final dateStr = DateFormat('dd/MM/yyyy HH:mm:ss').format(task.timestamp);
  final gpsStr = task.locationName ??
      (task.latitude != null
          ? '${task.latitude!.toStringAsFixed(5)}, ${task.longitude!.toStringAsFixed(5)}'
          : 'tidak tersedia');
  final isManual = task.barcodeFormat == 'MANUAL';

  final lines = <Map<String, dynamic>>[
    if (task.operatorName.isNotEmpty)
      {'text': task.operatorName, 'color': const Color(0xFFFFD700)},
    if (isManual)
      {'text': '[INPUT MANUAL]', 'color': const Color(0xFFFFAA00)},
    if (task.barcodeValue != null && task.barcodeValue!.isNotEmpty)
      {'text': task.barcodeValue!, 'color': Colors.white},
    {'text': dateStr, 'color': const Color(0xFFCCCCCC)},
    {'text': gpsStr, 'color': const Color(0xFFCCCCCC)},
  ];

  final fontSize = width * 0.03;
  final padding = width * 0.04;
  final rowHeight = fontSize * 1.65;
  final logoSize = width * 0.1;
  final bgHeight = (lines.length * rowHeight) + (padding * 2);
  final finalBgHeight = logoImage != null
      ? (bgHeight > logoSize + padding * 2 ? bgHeight : logoSize + padding * 2)
      : bgHeight;

  // Background strip
  canvas.drawRect(
    Rect.fromLTWH(0, height - finalBgHeight, width, finalBgHeight),
    Paint()..color = const Color(0xCC000000),
  );

  // Logo kanan bawah
  if (logoImage != null) {
    final logoW = logoImage.width.toDouble();
    final logoH = logoImage.height.toDouble();
    final scale = logoSize / (logoW > logoH ? logoW : logoH);
    final drawW = logoW * scale;
    final drawH = logoH * scale;
    final logoLeft = width - padding - drawW;
    final logoTop = height - finalBgHeight + (finalBgHeight - drawH) / 2;

    canvas.drawImageRect(
      logoImage,
      Rect.fromLTWH(0, 0, logoW, logoH),
      Rect.fromLTWH(logoLeft, logoTop, drawW, drawH),
      Paint()..filterQuality = FilterQuality.high,
    );
    logoImage.dispose();
  }

  // Teks baris per baris
  final textMaxWidth = logoImage != null
      ? width - (padding * 2) - (logoSize + padding)
      : width - (padding * 2);

  for (int i = 0; i < lines.length; i++) {
    final tp = TextPainter(
      text: TextSpan(
        text: lines[i]['text'] as String,
        style: TextStyle(
          color: lines[i]['color'] as Color,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          shadows: const [Shadow(blurRadius: 2, color: Colors.black)],
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: textMaxWidth);

    tp.paint(
      canvas,
      Offset(
        padding,
        (height - finalBgHeight + padding) + (i * rowHeight),
      ),
    );
  }

  final picture = recorder.endRecording();
  final img = await picture.toImage(width.toInt(), height.toInt());
  srcImage.dispose();

  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();

  final pngBytes = byteData!.buffer.asUint8List();
  await File(task.outputPath).writeAsBytes(pngBytes);
  return task.outputPath;
}

// ═══════════════════════════════════════════════════════════════════════════
/// Service untuk menambahkan watermark pada foto.
///
/// Menggunakan isolate terpisah agar UI tidak freeze saat rendering.
class WatermarkService {
  static final WatermarkService _instance = WatermarkService._();
  factory WatermarkService() => _instance;
  WatermarkService._();

  /// Menambahkan watermark ke [imagePath] dan menyimpan hasilnya ke [outputPath].
  ///
  /// [barcodeFormat] digunakan untuk menandai input manual.
  /// [locationName] jika tersedia akan digunakan sebagai pengganti koordinat mentah.
  ///
  /// Returns path file hasil watermark, atau `null` jika gagal.
  Future<String?> addWatermark({
    required String imagePath,
    required String outputPath,
    required String operatorName,
    String? barcodeValue,
    String? barcodeFormat,
    required DateTime timestamp,
    double? latitude,
    double? longitude,
    String? locationName,
    String? logoPath,
  }) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return null;

      final receivePort = ReceivePort();

      final task = _WatermarkTask(
        imagePath: imagePath,
        outputPath: outputPath,
        barcodeValue: barcodeValue,
        barcodeFormat: barcodeFormat,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        locationName: locationName,
        operatorName: operatorName,
        logoPath: logoPath,
        replyTo: receivePort.sendPort,
      );

      await Isolate.spawn(_watermarkIsolate, task);
      final result = await receivePort.first as String?;
      receivePort.close();

      return result;
    } catch (e) {
      debugPrint('WatermarkService.addWatermark error: $e');
      return null;
    }
  }
}
