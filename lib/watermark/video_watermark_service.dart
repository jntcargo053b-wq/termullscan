// lib/watermark/video_watermark_service.dart
// ============================================================
// VIDEO WATERMARK SERVICE - SIMPLE & STABLE
// ============================================================
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../models/scan_entry.dart';
import 'watermark_settings.dart';

class VideoWatermarkService {
  static String? lastError;

  /// Render watermark ke video menggunakan FFmpeg
  static Future<String?> renderVideo({
    required String videoPath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
    void Function(double progress)? onProgress,
  }) async {
    lastError = null;

    try {
      final file = File(videoPath);
      if (!await file.exists()) {
        lastError = 'Video tidak ditemukan: $videoPath';
        return null;
      }

      // Build teks watermark
      final text = _buildWatermarkText(settings, entry);
      final escapedText = _escapeDrawtext(text);

      // Posisi watermark
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

      final fontSize = settings.fontSize.clamp(12.0, 48.0);
      final opacity = settings.backgroundOpacity.clamp(0.0, 1.0);
      final fontColor = 'white';
      final bgColor = 'black@$opacity';

      // Draw text filter
      final drawText =
          "drawtext=text='$escapedText':"
          "fontcolor=$fontColor:"
          "fontsize=$fontSize:"
          "box=1:"
          "boxcolor=$bgColor:"
          "boxborderw=6:"
          "x=$x:y=$y";

      // Logo jika ada
      String overlayFilter = '';
      bool useLogo = false;
      String? validLogoPath;

      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        final logoFile = File(settings.logoPath!);
        if (await logoFile.exists()) {
          useLogo = true;
          validLogoPath = settings.logoPath;
        }
      }

      if (useLogo && validLogoPath != null) {
        final logoX = '$padding';
        final logoY = '(h-th)-$padding';
        overlayFilter =
            "[1:v]scale=100:-1[logo];"
            "[0:v][logo]overlay=$logoX:$logoY";
      }

      // Build command
      String command;
      if (useLogo && validLogoPath != null) {
        command =
            "-i '$videoPath' -i '$validLogoPath' "
            "-filter_complex \"$overlayFilter, $drawText\" "
            "-c:a copy -c:v libx264 -preset veryfast -crf 23 "
            "-movflags +faststart "
            "-y '$outputPath'";
      } else {
        command =
            "-i '$videoPath' "
            "-vf \"$drawText\" "
            "-c:a copy -c:v libx264 -preset veryfast -crf 23 "
            "-movflags +faststart "
            "-y '$outputPath'";
      }

      if (kDebugMode) {
        final preview = command.length > 200 ? '${command.substring(0, 200)}...' : command;
        debugPrint('⚙️ FFmpeg command: $preview');
      }

      // 🔥 SIMPLE: Gunakan execute (tanpa callback kompleks)
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      // Progress sederhana (simulasi)
      if (onProgress != null) {
        onProgress(0.3);
        await Future.delayed(const Duration(milliseconds: 100));
        onProgress(0.6);
        await Future.delayed(const Duration(milliseconds: 100));
        onProgress(1.0);
      }

      if (ReturnCode.isSuccess(returnCode)) {
        if (kDebugMode) debugPrint('✅ Video watermark success: $outputPath');
        return outputPath;
      } else {
        final logs = await session.getOutput();
        lastError = logs ?? 'Unknown error';
        debugPrint('❌ FFmpeg error: $lastError');
        return null;
      }
    } catch (e) {
      lastError = e.toString();
      debugPrint('❌ Error rendering video: $e');
      return null;
    }
  }

  static String _buildWatermarkText(WatermarkSettings settings, ScanEntry entry) {
    final operator = settings.operatorName.isNotEmpty ? settings.operatorName : 'Operator';
    final company = settings.companyName;
    final timestamp = entry.formattedTimestamp;
    final barcode = entry.value;
    final location = entry.displayLocation;

    final lines = <String>[];
    lines.add(operator);
    if (company.isNotEmpty) lines.add(company);
    lines.add(timestamp);
    lines.add(barcode);
    if (location.isNotEmpty && location != 'Lokasi tidak tersedia') lines.add(location);

    return lines.join('\n');
  }

  static String _escapeDrawtext(String text) {
    return text
        .replaceAll('\\', '\\\\\\\\')
        .replaceAll("'", "'\\\\''")
        .replaceAll(':', '\\:')
        .replaceAll('%', '\\%')
        .replaceAll('=', '\\=')
        .replaceAll(';', '\\;')
        .replaceAll('(', '\\(')
        .replaceAll(')', '\\)');
  }
}
