// ============================================================
// video_watermark_service.dart (dengan bitrate dari settings)
// ============================================================

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/watermark_style.dart';
import '../models/scan_entry.dart';

// ─── Semua fungsi utilitas dan kelas pembantu DI BAWAH INI TETAP SAMA ──
// (Saya tidak tulis ulang seluruhnya agar jawaban tetap ringkas,
//  tetapi pastikan file Anda memiliki semua fungsi seperti _escapeFFmpegText,
//  _probeVideoDuration, _WatermarkCache, dll. sesuai kode sebelumnya.
//  Yang diubah hanya bagian VideoWatermarkService.addWatermark di bawah.)

// ─── HANYA BAGIAN INI YANG DIPERBARUI ──────────────────────

class VideoWatermarkService {
  static String? lastError;
  static bool _warmedUp = false;

  static Future<void> warmUp() async { /* ... sama seperti sebelumnya ... */ }

  static final _WatermarkCache _cache = _WatermarkCache();

  static Future<void> preload(WatermarkSettings settings) async {
    await _cache.initialize(settings);
  }

  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    bool includeAudio = false,
    void Function(double progress)? onProgress,
  }) async {
    lastError = null;
    try {
      await _cache.initialize(settings);

      final durationSeconds = await _probeVideoDuration(inputPath);
      debugPrint('⏱️ Durasi video: ${durationSeconds}s');

      const double scale = 720.0 / 1920.0;
      debugPrint('📐 Skala watermark (fixed 720p): $scale');

      // 1. Siapkan filter watermark
      final List<String> watermarkFilters;
      final _XY logoXY;

      if (settings.style == WatermarkStyle.fullInfo) {
        final precomputed = _cache.getFullInfo(scale);
        final data = _cache.getFullInfoData(entry, settings);
        watermarkFilters = precomputed.buildFilters(
          barcode: data[0],
          date: data[1],
          time: data[2],
          operator: data[3],
          company: data[4],
          gpsText: data[5],
          location: data[6],
          code: data[7],
        );
        logoXY = precomputed.logoXY;
      } else if (settings.style == WatermarkStyle.timestamp) {
        final precomputed = _cache.getTimestamp(scale);
        final dynamicData = _cache.getTimestampDynamicData(entry, settings);
        watermarkFilters = precomputed.buildFilters(dynamicData);
        logoXY = precomputed.logoXY;
      } else {
        final precomputed = _cache.getStyle(settings.style, scale);
        final dynamicTexts = _cache.getDynamicTexts(entry, settings);
        watermarkFilters = precomputed.buildFilters(dynamicTexts);
        logoXY = precomputed.logoXY;
      }

      // 2. Scaling ke 720p
      const String scaleFilter =
          'scale=1280:720:force_original_aspect_ratio=decrease,'
          'pad=1280:720:(ow-iw)/2:(oh-ih)/2';

      final String videoFilterChain =
          '[0:v]$scaleFilter,${watermarkFilters.join(',')}';

      // 3. Logo overlay
      final logoPath = _cache.logoPath;
      final List<String> filterArgs;
      if (logoPath != null) {
        final escapedLogoPath = _escapeFFmpegPath(logoPath);
        final buffer = StringBuffer();
        buffer.write("movie='$escapedLogoPath'[logo];");
        buffer.write('$videoFilterChain[base];');
        buffer.write('[base][logo]overlay=${logoXY.x}:${logoXY.y}:format=auto[outv]');
        filterArgs = [
          '-filter_complex', buffer.toString(),
          '-map', '[outv]',
          '-map', '0:a?',
        ];
      } else {
        filterArgs = [
          '-vf', videoFilterChain,
        ];
      }

      // ─── 4. Ambil bitrate dari settings ─────────────────────
      final int bitrate = settings.videoBitrateKbps;
      debugPrint('🎚️ Video bitrate: ${bitrate}kbps');

      // 5. Argumen FFmpeg
      final arguments = <String>[
        '-i', inputPath,
        ...filterArgs,
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-b:v', '${bitrate}k',
        '-maxrate', '${bitrate}k',
        '-bufsize', '${bitrate * 2}k',
        '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart',
        '-y',
        outputPath,
      ];

      if (!includeAudio) {
        arguments.insertAll(arguments.length - 1, ['-an']);
      } else {
        arguments.insertAll(arguments.length - 1, [
          '-c:a', 'aac',
          '-b:a', '128k',
        ]);
      }

      // ─── Progress callback ──────────────────────────────────
      if (onProgress != null && durationSeconds > 0) {
        FFmpegKitConfig.enableLogCallback((log) {
          final message = log.getMessage();
          if (message.contains('out_time_ms=')) {
            final regex = RegExp(r'out_time_ms=(\d+)');
            final match = regex.firstMatch(message);
            if (match != null) {
              final outTimeMs = int.parse(match.group(1)!);
              double progress = outTimeMs / (durationSeconds * 1000);
              if (progress > 1.0) progress = 1.0;
              onProgress(progress);
            }
          }
        });
      }

      debugPrint('🎬 FFmpeg arguments: $arguments');

      final session = await FFmpegKit.executeWithArguments(arguments);
      final returnCode = await session.getReturnCode();

      FFmpegKitConfig.enableLogCallback(null);

      debugPrint('🔢 ReturnCode = ${returnCode?.getValue()}');
      final output = await session.getOutput();
      if (output != null && output.isNotEmpty) {
        debugPrint('📤 Output: $output');
      }
      final logs = await session.getAllLogsAsString();
      debugPrint('📜 Full logs: $logs');

      if (returnCode?.isValueSuccess() == true) {
        debugPrint('✅ Video watermark berhasil: $outputPath');
        return outputPath;
      } else {
        final diagnosis = _diagnoseFailure(logs ?? '');
        debugPrint('❌ FFmpeg gagal. Diagnosis: $diagnosis');
        final fullLog = logs ?? '';
        final tail = fullLog.length > 1500 ? fullLog.substring(fullLog.length - 1500) : fullLog;
        lastError = 'rc=${returnCode?.getValue()} | $diagnosis\n'
            '---arguments---\n${arguments.join(' ')}\n'
            '---log tail---\n$tail';
        return null;
      }
    } catch (e) {
      FFmpegKitConfig.enableLogCallback(null);
      debugPrint('❌ Error video watermark: $e');
      lastError = 'Exception: $e';
      return null;
    }
  }

  static String _diagnoseFailure(String logs) { /* ... sama seperti sebelumnya ... */ }
}
