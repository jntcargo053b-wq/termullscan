import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import '../../models/scan_entry.dart';
import '../../watermark/watermark_settings.dart';
import '../../watermark/watermark_renderer.dart';
import '../../watermark/watermark_style.dart';
import 'watermark_cache.dart';

/// Service untuk menambahkan watermark ke video
class VideoWatermarkService {
  static String? lastError;
  static bool _warmedUp = false;
  static final WatermarkCache _cache = WatermarkCache();

  static final Map<String, String> _overlayFileCache = {};
  static const int _maxCacheSize = 20;

  /// Pemanasan FFmpeg (ringan)
  static Future<void> warmUp() async {
    if (_warmedUp) return;
    try {
      debugPrint('🔥 Memanaskan FFmpeg...');
      final session = await FFmpegKit.execute('-loglevel 0 -version');
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
    bool keepAudio = false,
    void Function(double progress)? onProgress,
  }) async {
    lastError = null;
    String? overlayPngPath;
    try {
      await _cache.initialize(settings);

      // ─── 1. Baca SEMUA metadata dalam SATU panggilan FFprobe ──
      final mediaInfoSession = await FFprobeKit.getMediaInformation(inputPath);
      final mediaInfo = mediaInfoSession.getMediaInformation();

      if (mediaInfo == null) {
        throw Exception('Gagal membaca metadata video (mediaInfo null)');
      }

      // Perbaiki: getDuration() mengembalikan Object?, cast dengan aman
      final durationObj = mediaInfo.getDuration();
      final double durationSeconds = (durationObj != null && durationObj is double)
          ? durationObj as double
          : 0.0;

      int srcW = 720;
      int srcH = 1280;
      int rotation = 0;

      final streams = mediaInfo.getStreams();
      for (final stream in streams) {
        // Deteksi stream video: coba ambil dimensi, jika > 0 maka video
        final w = stream.getWidth();
        final h = stream.getHeight();
        if (w != null && h != null && w > 0 && h > 0) {
          srcW = w;
          srcH = h;
          // Ambil rotasi dari tags
          final tags = stream.getTags();
          if (tags != null && tags.containsKey('rotate')) {
            final rotStr = tags['rotate']?.toString() ?? '0';
            rotation = int.tryParse(rotStr) ?? 0;
          }
          break; // kita temukan stream video
        }
      }

      if (srcW <= 0 || srcH <= 0) {
        srcW = 720;
        srcH = 1280;
      }

      debugPrint('⏱️ Durasi: ${durationSeconds}s | Dimensi asli: ${srcW}x$srcH | Rotasi: $rotation°');

      // ─── 2. Tentukan dimensi output ──────────────────────────
      int outW = srcW;
      int outH = srcH;

      if (rotation == 90 || rotation == 270) {
        final temp = outW;
        outW = outH;
        outH = temp;
        debugPrint('↕️ Dimensi ditukar karena rotasi → ${outW}x$outH');
      }

      // ─── 3. Batasi resolusi jika diperlukan ──────────────────
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

      debugPrint('📐 Output: ${outW}x$outH');

      // ─── 4. Bangun filter scaling (tanpa scale=iw:ih) ──────
      String scaleFilter = '';

      if (rotation == 90) {
        scaleFilter += 'transpose=1,';
      } else if (rotation == 270) {
        scaleFilter += 'transpose=2,';
      } else if (rotation == 180) {
        scaleFilter += 'transpose=2,transpose=2,';
      }

      final bool needScale = (settings.videoResolution != VideoResolution.original) &&
          (outW != srcW || outH != srcH);

      if (needScale) {
        scaleFilter += 'scale=$outW:$outH:force_original_aspect_ratio=decrease,';
        scaleFilter += 'pad=$outW:$outH:(ow-iw)/2:(oh-ih)/2,';
      }
      // ❌ Jika tidak perlu scale: TIDAK ADA filter scale=iw:ih

      scaleFilter += 'setsar=1';

      debugPrint('🔧 Scale filter: $scaleFilter');

      // ─── 5. Render overlay PNG (HANYA area watermark) ──────
      final overlayResult = await WatermarkRenderer.renderVideoOverlaySmallPng(
        outW: outW,
        outH: outH,
        settings: settings,
        entry: entry,
      );

      if (overlayResult == null) {
        throw Exception('Gagal membuat overlay watermark PNG untuk video');
      }

      final overlayBytes = overlayResult.$1;
      final offsetX = overlayResult.$2;
      final offsetY = overlayResult.$3;

      if (overlayBytes == null) {
        throw Exception('Overlay PNG bytes null');
      }

      overlayPngPath = '$outputPath.overlay.png';
      final overlayFile = File(overlayPngPath);
      await overlayFile.writeAsBytes(overlayBytes);
      debugPrint('🖼️ Overlay PNG watermark dibuat: ${overlayBytes.length} bytes, posisi: ($offsetX, $offsetY)');

      // ─── 6. Filter complex (format=yuv420p di akhir) ──────
      final String filterComplex =
          '[0:v]$scaleFilter[base];'
          '[base][1:v]overlay=$offsetX:$offsetY:format=auto[outv];'
          '[outv]format=yuv420p[out]';

      final List<String> filterArgs = [
        '-filter_complex', filterComplex,
        '-map', '[out]',
      ];

      // ─── 7. Encoding (hardware + fallback + threads) ──────
      final int bitrate = settings.videoBitrateKbps;
      final int crf = settings.videoCrf;
      final String preset = settings.x264Preset;
      final bool useHwEncoder = await _shouldUseHardwareEncoder();
      debugPrint('🎚️ CRF: $crf | Cap: ${bitrate}kbps | Preset: $preset | '
          'Resolusi: ${settings.videoResolution} | HW encoder: $useHwEncoder');

      final List<String> encoderArgs;
      if (useHwEncoder) {
        encoderArgs = [
          '-c:v', 'h264_mediacodec',
          '-b:v', '${bitrate}k',
          '-maxrate', '${bitrate}k',
          '-bufsize', '${bitrate * 2}k',
        ];
      } else {
        encoderArgs = [
          '-c:v', 'libx264',
          '-preset', preset,
          '-crf', '$crf',
          '-maxrate', '${bitrate}k',
          '-bufsize', '${bitrate * 2}k',
          '-threads', '2',
        ];
      }

      final arguments = <String>[
        '-i', inputPath,
        '-i', overlayPngPath,
        ...filterArgs,
        ...encoderArgs,
        '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart',
        '-y',
        outputPath,
      ];

      // ─── 8. Audio ──────────────────────────────────────────────
      if (keepAudio) {
        arguments.insertAll(arguments.length - 1, ['-map', '0:a?', '-c:a', 'copy']);
      } else {
        arguments.insertAll(arguments.length - 1, ['-an']);
      }

      // ─── 9. Progress callback (StatisticsCallback) ──────────
      if (onProgress != null && durationSeconds > 0) {
        FFmpegKitConfig.enableStatisticsCallback((statistics) {
          final timeMicros = statistics.getTime();
          if (timeMicros > 0) {
            double progress = timeMicros / (durationSeconds * 1000000);
            if (progress > 1.0) progress = 1.0;
            onProgress(progress);
          }
        });
      }

      debugPrint('🎬 FFmpeg arguments: $arguments');

      var session = await FFmpegKit.executeWithArguments(arguments);
      var returnCode = await session.getReturnCode();

      // Fallback jika hardware encoder gagal
      if (useHwEncoder && !ReturnCode.isSuccess(returnCode)) {
        debugPrint('⚠️ h264_mediacodec gagal (rc=${returnCode?.getValue()}), fallback ke libx264...');
        final swEncoderArgs = [
          '-c:v', 'libx264',
          '-preset', preset,
          '-crf', '$crf',
          '-maxrate', '${bitrate}k',
          '-bufsize', '${bitrate * 2}k',
          '-threads', '2',
        ];
        final swArguments = <String>[
          '-i', inputPath,
          '-i', overlayPngPath,
          ...filterArgs,
          ...swEncoderArgs,
          '-pix_fmt', 'yuv420p',
          '-movflags', '+faststart',
          '-y',
          outputPath,
        ];
        if (keepAudio) {
          swArguments.insertAll(swArguments.length - 1, ['-map', '0:a?', '-c:a', 'copy']);
        } else {
          swArguments.insertAll(swArguments.length - 1, ['-an']);
        }
        session = await FFmpegKit.executeWithArguments(swArguments);
        returnCode = await session.getReturnCode();
      }

      // Matikan callback setelah selesai
      FFmpegKitConfig.enableStatisticsCallback(null);
      FFmpegKitConfig.enableLogCallback(null);

      if (!ReturnCode.isSuccess(returnCode)) {
        final output = await session.getOutput();
        final logs = await session.getAllLogsAsString();
        debugPrint('❌ FFmpeg error log:\n$logs');
        throw Exception('FFmpeg gagal (rc=${returnCode?.getValue()}): $output\n$logs');
      }

      debugPrint('✅ Video watermark berhasil: $outputPath');
      return outputPath;
    } catch (e) {
      FFmpegKitConfig.enableStatisticsCallback(null);
      FFmpegKitConfig.enableLogCallback(null);
      debugPrint('❌ Error video watermark: $e');
      lastError = 'Exception: $e';
      return null;
    } finally {
      if (overlayPngPath != null) {
        try {
          final f = File(overlayPngPath);
          if (await f.exists()) await f.delete();
        } catch (e) {
          debugPrint('⚠️ Gagal menghapus overlay PNG sementara: $e');
        }
      }
    }
  }

  static bool? _hwEncoderAvailable;
  static bool? _isEmulator;

  static Future<bool> _checkIsEmulator() async {
    if (_isEmulator != null) return _isEmulator!;
    try {
      final session = await FFmpegKit.execute(
        '-loglevel 0 -hide_banner -f android_property -i ro.kernel.qemu -f null -',
      );
      final output = await session.getOutput() ?? '';
      _isEmulator = output.contains('1') || output.contains('true');
      debugPrint(_isEmulator! ? '📱 Detected Android Emulator' : '📱 Detected Real Device');
    } catch (_) {
      _isEmulator = false;
    }
    return _isEmulator!;
  }

  static Future<bool> _shouldUseHardwareEncoder() async {
    if (Platform.isAndroid) {
      final isEmu = await _checkIsEmulator();
      if (isEmu) {
        debugPrint('ℹ️ Emulator terdeteksi, skip hardware encoder');
        return false;
      }
    }

    if (_hwEncoderAvailable != null) return _hwEncoderAvailable!;
    try {
      final session = await FFmpegKit.execute('-loglevel 0 -encoders');
      final output = await session.getOutput() ?? '';
      _hwEncoderAvailable = output.contains('h264_mediacodec');
      debugPrint(_hwEncoderAvailable!
          ? '✅ h264_mediacodec tersedia'
          : 'ℹ️ h264_mediacodec tidak tersedia, pakai libx264');
    } catch (e) {
      debugPrint('⚠️ Gagal cek h264_mediacodec: $e');
      _hwEncoderAvailable = false;
    }
    return _hwEncoderAvailable!;
  }

  static String diagnoseFailure(String logs) {
    final l = logs.toLowerCase();
    if (l.contains('overlay.png') &&
        (l.contains('no such file') || l.contains('invalid data found'))) {
      return 'Overlay PNG watermark gagal dibuat/dibaca. Cek WatermarkRenderer.';
    }
    if (l.contains('unknown encoder') || l.contains('encoder not found')) {
      return 'Encoder tidak tersedia. Ganti ke mpeg4.';
    }
    if (l.contains('invalid argument') && l.contains('overlay')) {
      return 'Argumen filter overlay tidak valid (kemungkinan ukuran PNG tidak cocok).';
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
