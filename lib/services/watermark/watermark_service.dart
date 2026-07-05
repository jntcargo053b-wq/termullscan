import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../../models/scan_entry.dart';
import '../../watermark/watermark_settings.dart';
import '../../watermark/watermark_style.dart';
import 'watermark_utils.dart';
import 'watermark_cache.dart';

/// Service untuk menambahkan watermark ke video
class VideoWatermarkService {
  static String? lastError;
  static bool _warmedUp = false;

  static final WatermarkCache _cache = WatermarkCache();

  /// Pemanasan FFmpeg (opsional)
  static Future<void> warmUp() async {
    if (_warmedUp) return;
    try {
      debugPrint('🔥 Memanaskan FFmpeg...');
      final session = await FFmpegKit.execute('-version');
      final returnCode = await session.getReturnCode();
      if (ReturnCode.isSuccess(returnCode)) {
        debugPrint('✅ FFmpeg warm-up berhasil.');
      } else {
        debugPrint('⚠️ FFmpeg warm-up gagal (rc=${returnCode?.getValue()})');
      }
    } catch (e) {
      debugPrint('❌ FFmpeg warm-up error: $e');
    } finally {
      _warmedUp = true;
    }
  }

  /// Preload font & logo (opsional)
  static Future<void> preload(WatermarkSettings settings) async {
    await _cache.initialize(settings);
  }

  /// Tambahkan watermark ke video
  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    void Function(double progress)? onProgress,
  }) async {
    lastError = null;
    try {
      await _cache.initialize(settings);

      final durationSeconds = await probeVideoDuration(inputPath);
      debugPrint('⏱️ Durasi video: ${durationSeconds}s');

      // ─── 1. Dapatkan dimensi dan rotasi ──────────────────────────
      final srcDim = await probeVideoDimensions(inputPath);
      int outW = srcDim.width;
      int outH = srcDim.height;
      if (outW <= 0 || outH <= 0) {
        outW = 720;
        outH = 1280;
      }

      // Deteksi rotasi dari metadata
      int rotation = await _getVideoRotation(inputPath);
      debugPrint('🔄 Rotasi video: $rotation°');

      // Jika rotasi 90 atau 270, tukar lebar/tinggi agar sesuai
      if (rotation == 90 || rotation == 270) {
        final temp = outW;
        outW = outH;
        outH = temp;
      }

      // ─── 2. Batasi resolusi jika diperlukan ──────────────────────
      int? maxSide;
      switch (settings.videoResolution) {
        case VideoResolution.original:
          maxSide = null;
          break;
        case VideoResolution.res1080p:
          maxSide = 1920;
          break;
        case VideoResolution.res720p:
          maxSide = 1280;
          break;
      }
      if (maxSide != null && (outW > maxSide || outH > maxSide)) {
        if (outW >= outH) {
          outH = (outH * maxSide / outW).round();
          outW = maxSide;
        } else {
          outW = (outW * maxSide / outH).round();
          outH = maxSide;
        }
      }
      outW = (outW ~/ 2) * 2;
      outH = (outH ~/ 2) * 2;

      final double scale = (math.min(outW, outH) / 720.0).clamp(0.6, 1.8);
      debugPrint('📐 Output: ${outW}x$outH | Skala watermark: $scale');

      // ─── 3. Bangun filter scaling dengan handling rotasi ────────
      // Jika ada rotasi, tambahkan transpose terlebih dahulu
      String scaleFilter = '';
      if (rotation == 90) {
        scaleFilter = 'transpose=1,'; // 90° clockwise
      } else if (rotation == 270) {
        scaleFilter = 'transpose=2,'; // 90° counter-clockwise
      } else if (rotation == 180) {
        scaleFilter = 'transpose=2,transpose=2,'; // 180° (hflip+vflip)
      }
      // Tambahkan scale (jika resolusi berubah) atau biarkan iw:ih
      if (outW != srcDim.width || outH != srcDim.height) {
        scaleFilter += 'scale=$outW:$outH,';
      } else {
        scaleFilter += 'scale=iw:ih,';
      }
      scaleFilter += 'setsar=1,format=yuv420p';

      // ─── 4. Dapatkan watermark filters ──────────────────────────
      List<String> watermarkFilters;
      XY logoXY;

      if (settings.style == WatermarkStyle.fullInfo) {
        final precomputed = _cache.getFullInfo(scale, maxHeight: outH);
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
        final maxLineLen = (outW * 0.06).round();
        final precomputed = _cache.getTimestamp(scale, maxHeight: outH);
        final dynamicData = _cache.getTimestampDynamicData(entry, settings, maxLineLen: maxLineLen);
        debugPrint('📋 Timestamp dynamicData: $dynamicData');
        watermarkFilters = precomputed.buildFilters(dynamicData);
        logoXY = precomputed.logoXY;
      } else {
        final precomputed = _cache.getStyle(settings.style, scale);
        final dynamicTexts = _cache.getDynamicTexts(entry, settings);
        watermarkFilters = precomputed.buildFilters(dynamicTexts);
        logoXY = precomputed.logoXY;
      }

      // ─── 5. Gabungkan filter ─────────────────────────────────────
      final String videoFilterChain =
          '[0:v]$scaleFilter,${watermarkFilters.join(',')}';

      // ─── 6. Logo ─────────────────────────────────────────────────
      final logoPath = _cache.logoPath;
      String filterComplex;
      if (logoPath != null) {
        final logoFile = File(logoPath);
        if (await logoFile.exists()) {
          final escapedLogoPath = escapeFFmpegPath(logoPath);
          final logoHeight = (outH * 0.08).round();
          filterComplex =
              "movie='$escapedLogoPath',scale=-1:$logoHeight,format=rgba,colorchannelmixer=aa=0.85[logo]; "
              "$videoFilterChain[base]; [base][logo]overlay=${logoXY.x}:${logoXY.y}:format=auto[outv]";
        } else {
          filterComplex = "$videoFilterChain[outv]";
        }
      } else {
        filterComplex = "$videoFilterChain[outv]";
      }

      final List<String> filterArgs = [
        '-filter_complex', filterComplex,
        '-map', '[outv]',
      ];

      final int bitrate = settings.videoBitrateKbps;
      final String preset = settings.x264Preset;
      debugPrint('🎚️ Video bitrate: ${bitrate}kbps | Preset: $preset | Resolusi: ${settings.videoResolution}');

      final arguments = <String>[
        '-i', inputPath,
        ...filterArgs,
        '-c:v', 'libx264',
        '-preset', preset,
        '-b:v', '${bitrate}k',
        '-maxrate', '${bitrate}k',
        '-bufsize', '${bitrate * 2}k',
        '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart',
        '-y',
        outputPath,
      ];

      // Matikan audio
      arguments.insertAll(arguments.length - 1, ['-an']);

      // ─── 7. Progress callback ──────────────────────────────────
      if (onProgress != null && durationSeconds > 0) {
        FFmpegKitConfig.enableLogCallback((log) {
          final message = log.getMessage();
          if (message.contains('out_time_ms=')) {
            final regex = RegExp(r'out_time_ms=(\d+)');
            final match = regex.firstMatch(message);
            if (match != null) {
              final outTimeMs = int.parse(match.group(1)!);
              double progress = outTimeMs / (durationSeconds * 1000000);
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

      if (!ReturnCode.isSuccess(returnCode)) {
        final output = await session.getOutput();
        final logs = await session.getAllLogsAsString();
        throw Exception('FFmpeg gagal (rc=${returnCode?.getValue()}): $output\n$logs');
      }

      debugPrint('✅ Video watermark berhasil: $outputPath');
      return outputPath;
    } catch (e) {
      FFmpegKitConfig.enableLogCallback(null);
      debugPrint('❌ Error video watermark: $e');
      lastError = 'Exception: $e';
      return null;
    }
  }

  /// Ambil rotasi video dari metadata via FFprobe
  static Future<int> _getVideoRotation(String inputPath) async {
    try {
      final session = await FFprobeKit.getMediaInformation(inputPath);
      final mediaInfo = session.getMediaInformation();
      if (mediaInfo != null) {
        final streams = mediaInfo.getStreams();
        for (final stream in streams) {
          final tags = stream.getTags();
          if (tags != null && tags.containsKey('rotate')) {
            final rotStr = tags['rotate']?.toString() ?? '0';
            return int.tryParse(rotStr) ?? 0;
          }
        }
      }
    } catch (e) {
      debugPrint('⚠️ Gagal membaca rotasi: $e');
    }
    return 0;
  }

  static String diagnoseFailure(String logs) {
    final l = logs.toLowerCase();
    if (l.contains('no such filter') && l.contains('drawtext')) {
      return 'Filter drawtext TIDAK tersedia. Pastikan pubspec.yaml memakai '
          'ffmpeg_kit_flutter (resmi) atau varian yang menyertakan freetype.';
    }
    if (l.contains('cannot find a valid font') ||
        l.contains('could not load font') ||
        l.contains('error loading freetype')) {
      return 'Font gagal dimuat. Coba font statis (mis. Poppins-Regular.ttf).';
    }
    if (l.contains('unknown encoder') || l.contains('encoder not found')) {
      return 'Encoder tidak tersedia. Ganti ke mpeg4.';
    }
    if (l.contains('invalid argument') && l.contains('drawtext')) {
      return 'Syntax filter drawtext tidak valid (karakter khusus belum di-escape).';
    }
    if (l.contains('permission denied')) {
      return 'Tidak ada izin baca/tulis ke file video.';
    }
    if (l.contains('moov atom not found') || l.contains('invalid data found')) {
      return 'File video input korup/tidak lengkap.';
    }
    return 'Penyebab tidak dikenal. Cek log lengkap di atas.';
  }
}
