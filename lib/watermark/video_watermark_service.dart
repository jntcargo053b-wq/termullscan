// lib/watermark/video_watermark_service.dart
// ============================================================
// VIDEO WATERMARK SERVICE
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

      if (kDebugMode) debugPrint('⚙️ FFmpeg command: $command');

      // 🔥 FIX: FFmpegKit.execute hanya menerima 1 parameter
      // Progress callback menggunakan listener terpisah
      final session = await FFmpegKit.execute(command);
      
      // Parse progress dari log menggunakan listener
      FFmpegKit.addSessionListener((session) {
        final logs = session.getAllLogs();
        for (final log in logs) {
          if (onProgress != null) {
            final progress = _parseProgress(log.getMessage());
            if (progress != null) onProgress(progress);
          }
        }
      });

      final returnCode = await session.getReturnCode();

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

  static double? _parseProgress(String message) {
    try {
      final regex = RegExp(r'time=(\d{2}):(\d{2}):(\d{2}\.\d{2})');
      final match = regex.firstMatch(message);
      if (match != null) {
        final hours = int.parse(match.group(1)!);
        final minutes = int.parse(match.group(2)!);
        final seconds = double.parse(match.group(3)!);
        return hours * 3600 + minutes * 60 + seconds;
      }
    } catch (_) {}
    return null;
  }
}
