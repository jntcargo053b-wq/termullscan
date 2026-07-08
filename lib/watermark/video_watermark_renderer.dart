// lib/watermark/video_watermark_renderer.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../models/scan_entry.dart';
import 'watermark_settings.dart';

class VideoWatermarkRenderer {
  /// Render watermark ke video (MP4) menggunakan ffmpeg_kit_flutter_new
  static Future<String?> render({
    required String videoPath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    if (kDebugMode) {
      debugPrint('🎬 VIDEO WATERMARK START');
      debugPrint('  Style: ${settings.style.name}');
    }

    try {
      final file = File(videoPath);
      if (!await file.exists()) {
        debugPrint('❌ Video tidak ditemukan: $videoPath');
        return null;
      }

      // 1. Format teks watermark
      final operator = settings.operatorName.isNotEmpty ? settings.operatorName : 'Operator';
      final company = settings.companyName.isNotEmpty ? '\n${settings.companyName}' : '';
      final timestamp = entry.timestamp.toIso8601String().substring(0, 19).replaceAll('T', ' ');
      final barcode = entry.value ?? 'No Barcode';
      final location = entry.locationName ?? '';

      String text = '$operator$company\n$timestamp\n$barcode';
      if (location.isNotEmpty) text += '\n$location';

      // Escape karakter untuk FFmpeg (single quote, colon, backslash)
      text = text.replaceAll("'", "'\\\\''"); // escape single quote
      text = text.replaceAll(':', '\\:');     // escape colon
      text = text.replaceAll('\\', '\\\\');   // escape backslash

      // 2. Posisi
      final pos = settings.position;
      final padding = 20;
      String x, y;
      switch (pos) {
        case WatermarkPosition.bottomRight:
          x = '(w-tw)-$padding';
          y = '(h-th)-$padding';
          break;
        case WatermarkPosition.bottomLeft:
          x = '$padding';
          y = '(h-th)-$padding';
          break;
        case WatermarkPosition.topRight:
          x = '(w-tw)-$padding';
          y = '$padding';
          break;
        case WatermarkPosition.topLeft:
          x = '$padding';
          y = '$padding';
          break;
      }

      final fontSize = settings.fontSize;
      final opacity = settings.backgroundOpacity;
      final fontColor = 'white';
      final bgColor = 'black@$opacity';

      // 3. Filter drawtext
      String drawText =
          "drawtext=text='$text':"
          "fontcolor=$fontColor:"
          "fontsize=$fontSize:"
          "box=1:"
          "boxcolor=$bgColor:"
          "boxborderw=5:"
          "x=$x:y=$y";

      // 4. Logo (jika ada)
      String overlayFilter = '';
      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        final logoPath = settings.logoPath!;
        // Posisi logo di pojok kiri bawah terpisah dari teks
        final logoX = '$padding';
        final logoY = '(h-th)-$padding';
        // Skala logo agar tidak terlalu besar (lebar 100px)
        overlayFilter =
            "[1:v]scale=100:-1[logo];"
            "[0:v][logo]overlay=$logoX:$logoY";
      }

      // 5. Build command
      String command;
      if (settings.hasLogo && settings.logoPath != null) {
        // Input video + logo
        command =
            "-i '$videoPath' -i '${settings.logoPath}' "
            "-filter_complex \"$overlayFilter, $drawText\" "
            "-c:a copy -c:v libx264 -preset fast -crf 23 "
            "-y '$outputPath'";
      } else {
        command =
            "-i '$videoPath' "
            "-vf \"$drawText\" "
            "-c:a copy -c:v libx264 -preset fast -crf 23 "
            "-y '$outputPath'";
      }

      if (kDebugMode) debugPrint('⚙️ FFmpeg command: $command');

      // 6. Eksekusi (synchronous blocking, bisa pakai async)
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        if (kDebugMode) debugPrint('✅ Video watermark success: $outputPath');
        return outputPath;
      } else if (ReturnCode.isCancel(returnCode)) {
        debugPrint('⚠️ Video processing cancelled');
        return null;
      } else {
        final logs = await session.getOutput();
        debugPrint('❌ FFmpeg error: $logs');
        return null;
      }
    } catch (e, stack) {
      debugPrint('❌ Error processing video: $e\n$stack');
      return null;
    }
  }
}
