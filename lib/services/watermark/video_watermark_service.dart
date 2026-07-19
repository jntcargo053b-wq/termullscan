// lib/services/watermark/video_watermark_service.dart
// PRODUCTION READY – DENGAN CANCEL YANG ROBUST DAN OVERLAY OPTIMAL
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show TextPainter, TextSpan, TextStyle, TextDirection;
import 'package:intl/intl.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart' show sha1;
import '../../models/scan_entry.dart';
import '../../watermark/watermark_settings.dart';
import '../../watermark/watermark_renderer.dart';
import 'watermark_cache.dart';

/// Service untuk menambahkan watermark ke video dengan kualitas asli.
class VideoWatermarkService {
  static String? lastError;
  static bool _warmedUp = false;
  static final WatermarkCache _cache = WatermarkCache();

  // Cache overlay (LinkedHashMap untuk LRU)
  static final LinkedHashMap<String, String> _overlayFileCache = LinkedHashMap();
  static const int _maxCacheSize = 50;
  static bool _cacheCleaned = false;

  // ─── SINGLE SESSION ──────────────────────────────────────────
  static bool _isEncoding = false;
  static String? _currentSessionId;
  static FFmpegSession? _currentSession;
  static void Function(double)? _currentProgressCallback;
  static double _currentDuration = 0;
  static bool _isCancelled = false;
  static final _AsyncLock _sessionLock = _AsyncLock();

  // ─── TIMEOUT ──────────────────────────────────────────────────
  static const int _defaultTimeoutSeconds = 300;
  static const int _progressWatchdogInterval = 10;
  static const int _progressWatchdogThreshold = 30;
  static Timer? _watchdogTimer;
  static double _lastProgress = 0;
  static DateTime _lastProgressTime = DateTime.now();

  // ─── PROGRESS THROTTLING ─────────────────────────────────────
  static DateTime _lastCallbackTime = DateTime.now().subtract(const Duration(seconds: 1));
  static double _lastReportedProgress = -1.0;
  static const Duration _progressThrottleInterval = Duration(milliseconds: 150);
  static const double _progressMinDelta = 0.005;

  // ─── HARDWARE ENCODER ────────────────────────────────────────
  static bool? _hwEncoderAvailable;
  static bool? _isEmulator;
  static bool _hwEncoderChecked = false;
  static const int _maxHwFallbackAttempts = 2;

  // ─── PIXEL FORMAT WHITELIST ─────────────────────────────────
  static const Set<String> _supportedPixelFormats = {
    'yuv420p',
    'yuv422p',
    'yuv444p',
    'nv12',
    'nv21',
    'rgb24',
    'bgr24',
  };

  // ─── WARM UP ──────────────────────────────────────────────────
  static Future<void> warmUp() async {
    if (_warmedUp) return;
    try {
      debugPrint('🔥 Memanaskan FFmpeg...');
      final session = await FFmpegKit.execute(
        '-hide_banner -f lavfi -i color -frames:v 1 -f null -',
      );
      final returnCode = await session.getReturnCode();
      if (ReturnCode.isSuccess(returnCode)) {
        debugPrint('✅ FFmpeg warm-up berhasil.');
        _warmedUp = true;
      } else {
        debugPrint('⚠️ FFmpeg warm-up gagal');
        _warmedUp = false;
        throw Exception('FFmpeg warm-up failed');
      }
    } catch (e) {
      debugPrint('❌ FFmpeg warm-up error: $e');
      _warmedUp = false;
      rethrow;
    }
  }

  // ─── PRELOAD ──────────────────────────────────────────────────
  static Future<void> preload(WatermarkSettings settings) async {
    await _cache.initialize(settings);
    unawaited(_detectHardwareEncoder());
    _registerGlobalStatisticsCallback();
    if (!_cacheCleaned) {
      await _cleanOrphanOverlayFiles();
      _cacheCleaned = true;
    }
  }

  // ─── STATISTICS CALLBACK ─────────────────────────────────────
  static void _registerGlobalStatisticsCallback() {
    if (FFmpegKitConfig.getStatisticsCallback() != null) return;

    FFmpegKitConfig.enableStatisticsCallback((statistics) {
      if (_currentSessionId == null || _isCancelled) return;

      final callback = _currentProgressCallback;
      if (callback == null) return;

      final timeMs = statistics.getTime();
      if (timeMs > 0 && _currentDuration > 0) {
        double progress = timeMs / (_currentDuration * 1000);
        if (progress > 1.0) progress = 1.0;

        _lastProgress = progress;
        _lastProgressTime = DateTime.now();

        final now = DateTime.now();
        final elapsed = now.difference(_lastCallbackTime);
        if (elapsed >= _progressThrottleInterval ||
            (progress - _lastReportedProgress).abs() >= _progressMinDelta) {
          _lastCallbackTime = now;
          _lastReportedProgress = progress;
          callback(progress);
        }
      }
    });
  }

  // ─── HARDWARE ENCODER DETECTION ─────────────────────────────
  static Future<void> _detectHardwareEncoder() async {
    if (_hwEncoderChecked) return;

    try {
      debugPrint('🔍 Mendeteksi hardware encoder...');

      final isEmulator = await _checkIsEmulator();
      if (isEmulator) {
        debugPrint('📱 Emulator - hardware encoder dinonaktifkan');
        _hwEncoderAvailable = false;
        _hwEncoderChecked = true;
        return;
      }

      final session = await FFmpegKit.execute('-encoders');
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        final output = await session.getOutput() ?? '';
        _hwEncoderAvailable = output.contains('h264_mediacodec');
        debugPrint(_hwEncoderAvailable!
            ? '✅ Hardware encoder TERSEDIA'
            : 'ℹ️ Hardware encoder TIDAK tersedia');
      } else {
        _hwEncoderAvailable = false;
        debugPrint('⚠️ Gagal mendeteksi encoder');
      }
    } catch (e) {
      _hwEncoderAvailable = false;
      debugPrint('⚠️ Error deteksi encoder: $e');
    } finally {
      _hwEncoderChecked = true;
    }
  }

  static Future<bool> _checkIsEmulator() async {
    if (_isEmulator != null) return _isEmulator!;
    try {
      final session = await FFmpegKit.execute(
        '-loglevel 0 -hide_banner -f android_property -i ro.kernel.qemu -f null -',
      );
      final output = await session.getOutput() ?? '';
      _isEmulator = output.contains('1') || output.contains('true');

      if (!_isEmulator!) {
        final session2 = await FFmpegKit.execute(
          '-loglevel 0 -hide_banner -f android_property -i ro.product.model -f null -',
        );
        final output2 = await session2.getOutput() ?? '';
        _isEmulator = output2.contains('sdk_gphone') ||
            output2.contains('AOSP') ||
            output2.contains('Android SDK');
      }
    } catch (_) {
      _isEmulator = false;
    }
    return _isEmulator!;
  }

  static bool _shouldUseHardwareEncoder() {
    if (!_hwEncoderChecked) return false;
    return _hwEncoderAvailable ?? false;
  }

  // ─── CANCEL ──────────────────────────────────────────────────
  static Future<void> cancel() async {
    await _sessionLock.synchronized(() async {
      if (_currentSessionId == null) {
        debugPrint('⚠️ Tidak ada session aktif');
        return;
      }

      debugPrint('🛑 Cancel encoding...');
      _isCancelled = true;

      _watchdogTimer?.cancel();
      _watchdogTimer = null;

      if (_currentSession != null) {
        try {
          FFmpegKit.cancel(_currentSession!);
          debugPrint('✅ FFmpeg session cancelled');
        } catch (e) {
          debugPrint('⚠️ FFmpegKit.cancel gagal: $e');
          try {
            FFmpegKit.cancel();
            debugPrint('✅ FFmpeg cancelled (global)');
          } catch (e2) {
            debugPrint('⚠️ FFmpegKit.cancel global juga gagal: $e2');
          }
        }
      }

      _currentSession = null;
      _currentSessionId = null;
      _currentProgressCallback = null;
      _isEncoding = false;
    });
  }

  // ─── ADD WATERMARK ────────────────────────────────────────────
  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    bool keepAudio = true,
    int timeoutSeconds = _defaultTimeoutSeconds,
    void Function(double progress)? onProgress,
  }) async {
    if (_isEncoding) {
      throw Exception('Encoding sedang berjalan. Tunggu selesai.');
    }

    lastError = null;
    String? overlayPath;
    int overlayW = 0, overlayH = 0;
    int overlayOffsetX = 0, overlayOffsetY = 0;

    _isCancelled = false;
    _lastProgress = 0;
    _lastProgressTime = DateTime.now();
    _currentDuration = 0;
    _lastReportedProgress = -1.0;
    _lastCallbackTime = DateTime.now().subtract(_progressThrottleInterval);

    try {
      await warmUp();
      await _cache.initialize(settings);

      if (!_hwEncoderChecked) {
        await _detectHardwareEncoder();
      }

      if (!_cacheCleaned) {
        await _cleanOrphanOverlayFiles();
        _cacheCleaned = true;
      }

      // ─── 1. BACA INFO VIDEO ─────────────────────────────────
      final videoInfo = await _getVideoInfo(inputPath);
      if (videoInfo == null) {
        throw Exception('Gagal membaca info video');
      }

      debugPrint('📹 ${videoInfo.width}x${videoInfo.height}, '
          '${videoInfo.fps}fps, '
          '${(videoInfo.bitrate / 1000).round()}kbps, '
          '${videoInfo.pixelFormat}, '
          '${videoInfo.duration}s');
      _currentDuration = videoInfo.duration;

      // ─── 2. HITUNG UKURAN OVERLAY YANG DIPERLUKAN ──────────
      final (needW, needH) = _computeWatermarkSize(settings, entry);
      // Tambahkan padding
      const padding = 20;
      int ovW = needW + padding * 2;
      int ovH = needH + padding * 2;
      // Pastikan genap
      ovW = (ovW ~/ 2) * 2;
      ovH = (ovH ~/ 2) * 2;
      overlayW = ovW;
      overlayH = ovH;

      debugPrint('🎨 Overlay akan dirender pada ${ovW}x${ovH}');

      // ─── 3. RENDER OVERLAY DENGAN UKURAN PAS ──────────────
      final overlayResult = await _renderOverlay(
        outW: ovW,
        outH: ovH,
        settings: settings,
        entry: entry,
      );
      if (overlayResult == null) {
        debugPrint('⚠️ Overlay gagal, beralih ke drawtext...');
        final fallbackResult = await _addWatermarkWithDrawtext(
          inputPath: inputPath,
          outputPath: outputPath,
          entry: entry,
          settings: settings,
          videoInfo: videoInfo,
          onProgress: onProgress,
          timeoutSeconds: timeoutSeconds,
        );
        if (fallbackResult != null) return fallbackResult;
        throw Exception('Gagal membuat watermark');
      }

      overlayPath = overlayResult.$1;
      if (overlayPath == null) throw Exception('Overlay path null');

      // ─── 4. HITUNG POSISI OVERLAY ──────────────────────────
      final pos = settings.position;
      switch (pos) {
        case WatermarkPosition.bottomRight:
          overlayOffsetX = videoInfo.width - ovW - padding;
          overlayOffsetY = videoInfo.height - ovH - padding;
          break;
        case WatermarkPosition.bottomLeft:
          overlayOffsetX = padding;
          overlayOffsetY = videoInfo.height - ovH - padding;
          break;
        case WatermarkPosition.topRight:
          overlayOffsetX = videoInfo.width - ovW - padding;
          overlayOffsetY = padding;
          break;
        case WatermarkPosition.topLeft:
          overlayOffsetX = padding;
          overlayOffsetY = padding;
          break;
      }
      // Pastikan tidak negatif
      overlayOffsetX = max(0, overlayOffsetX);
      overlayOffsetY = max(0, overlayOffsetY);

      debugPrint('🖼️ Overlay PNG siap, posisi ($overlayOffsetX,$overlayOffsetY)');

      await _sessionLock.synchronized(() async {
        _currentProgressCallback = onProgress;
        _isEncoding = true;
        _currentSessionId = DateTime.now().millisecondsSinceEpoch.toString();
      });

      // ─── 5. WATCHDOG ────────────────────────────────────────
      _watchdogTimer?.cancel();
      _watchdogTimer = Timer.periodic(
        Duration(seconds: _progressWatchdogInterval),
        (timer) {
          if (_isCancelled) {
            timer.cancel();
            return;
          }

          final elapsed =
              DateTime.now().difference(_lastProgressTime).inSeconds;
          if (elapsed > _progressWatchdogThreshold && _lastProgress > 0.01) {
            debugPrint('⚠️ WATCHDOG: Tidak ada progress');
            timer.cancel();
            unawaited(cancel());
            lastError = 'Encoding timeout - no progress';
          }
        },
      );

      // ─── 6. BUILD COMMAND ──────────────────────────────────
      final args = _buildFFmpegArguments(
        inputPath: inputPath,
        outputPath: outputPath,
        overlayPath: overlayPath,
        offsetX: overlayOffsetX,
        offsetY: overlayOffsetY,
        videoInfo: videoInfo,
        keepAudio: keepAudio,
      );
      debugPrint('🎬 FFmpeg: ${args.join(' ')}');

      // ─── 7. EXECUTE DENGAN FALLBACK ENCODER ────────────────
      final success = await _executeEncodingWithFallback(
        args: args,
        videoInfo: videoInfo,
        timeoutSeconds: timeoutSeconds,
        attempt: 0,
      );

      _watchdogTimer?.cancel();
      _watchdogTimer = null;

      await _sessionLock.synchronized(() async {
        _isEncoding = false;
        _currentSessionId = null;
        _currentSession = null;
        _currentProgressCallback = null;
      });

      if (_isCancelled) {
        debugPrint('⏹️ Encoding dibatalkan');
        return null;
      }

      if (!success) {
        debugPrint('⚠️ Encoding gagal, coba drawtext...');
        final fallbackResult = await _addWatermarkWithDrawtext(
          inputPath: inputPath,
          outputPath: outputPath,
          entry: entry,
          settings: settings,
          videoInfo: videoInfo,
          onProgress: onProgress,
          timeoutSeconds: timeoutSeconds,
        );
        if (fallbackResult != null) return fallbackResult;
        return null;
      }

      debugPrint('✅ Video watermark berhasil');
      return outputPath;
    } catch (e) {
      debugPrint('❌ Error: $e');
      lastError = diagnoseFailure(e.toString());
      return null;
    } finally {
      _watchdogTimer?.cancel();
      _watchdogTimer = null;

      await _sessionLock.synchronized(() async {
        _isEncoding = false;
        _currentSessionId = null;
        _currentSession = null;
        _currentProgressCallback = null;
      });

      if (overlayPath != null &&
          !_overlayFileCache.containsValue(overlayPath)) {
        try {
          final f = File(overlayPath);
          if (await f.exists()) await f.delete();
        } catch (e) {
          debugPrint('⚠️ Gagal hapus overlay: $e');
        }
      }
    }
  }

  // ─── HITUNG UKURAN WATERMARK (TEKS + LOGO) ──────────────────
  static (int, int) _computeWatermarkSize(WatermarkSettings settings, ScanEntry entry) {
    // Build teks seperti di drawtext
    final operator = settings.operatorName.isNotEmpty ? settings.operatorName : '';
    final company = settings.companyName.isNotEmpty ? '\n${settings.companyName}' : '';
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    final timestamp = dateFormat.format(entry.timestamp);
    final barcode = entry.value ?? 'No Barcode';
    final location = entry.locationName ?? '';

    String text = '$operator$company\n$timestamp\n$barcode';
    if (location.isNotEmpty) text += '\n$location';

    // Gunakan TextPainter untuk mengukur
    final textStyle = TextStyle(
      fontSize: settings.fontSize.toDouble(),
      fontFamily: settings.fontFamily,
      color: const Color(0xFFFFFFFF),
    );
    final textSpan = TextSpan(text: text, style: textStyle);
    final painter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    painter.layout(maxWidth: double.infinity);
    final size = painter.size;

    // Tambahkan padding 20
    const padding = 20.0;
    int w = (size.width + padding * 2).ceil();
    int h = (size.height + padding * 2).ceil();

    // Jika ada logo, tambahkan lebar logo + jarak
    if (settings.hasLogo && settings.logoPath != null) {
      // Asumsikan logo 50x50, sesuaikan nanti
      w += 60;
      h = max(h, 70);
    }

    // Pastikan minimal 100x50
    w = max(w, 100);
    h = max(h, 50);

    // Genapkan
    w = (w ~/ 2) * 2;
    h = (h ~/ 2) * 2;
    return (w, h);
  }

  // ─── 1. BACA INFO VIDEO ──────────────────────────────────────
  static Future<_VideoInfo?> _getVideoInfo(String inputPath) async {
    try {
      final session = await FFprobeKit.getMediaInformation(inputPath)
          .timeout(const Duration(seconds: 10));

      final mediaInfo = session.getMediaInformation();
      if (mediaInfo == null) return null;

      final durationObj = mediaInfo.getDuration();
      final double duration =
          double.tryParse(durationObj?.toString() ?? '') ?? 0.0;

      int width = 0, height = 0;
      int bitrate = 0;
      double fps = 0;
      String pixelFormat = 'yuv420p';

      final streams = mediaInfo.getStreams();
      for (final stream in streams) {
        final w = stream.getWidth();
        final h = stream.getHeight();

        if (w != null && h != null && w > 0 && h > 0) {
          width = w;
          height = h;

          final br = stream.getBitrate();
          if (br != null && br > 0) bitrate = br;

          final avgFrameRate = stream.getAverageFrameRate();
          if (avgFrameRate != null) {
            final parts = avgFrameRate.split('/');
            if (parts.length == 2) {
              final num = double.tryParse(parts[0]);
              final den = double.tryParse(parts[1]);
              if (num != null && den != null && den > 0) {
                fps = num / den;
              }
            }
          }

          final pixFmt = stream.getPixelFormat();
          if (pixFmt != null && pixFmt.isNotEmpty) {
            if (_supportedPixelFormats.contains(pixFmt.toLowerCase())) {
              pixelFormat = pixFmt;
            } else {
              debugPrint(
                  '⚠️ Pixel format $pixFmt tidak didukung, fallback ke yuv420p');
              pixelFormat = 'yuv420p';
            }
          }
          break;
        }
      }

      if (width == 0 || height == 0) {
        debugPrint('⚠️ Tidak ada stream video valid');
        return null;
      }

      if (bitrate == 0 && duration > 0) {
        final fileSize = await File(inputPath).length();
        bitrate = (fileSize * 8 / duration).round();
      }

      width = (width ~/ 2) * 2;
      height = (height ~/ 2) * 2;

      return _VideoInfo(
        width: width,
        height: height,
        duration: duration,
        bitrate: bitrate,
        fps: fps,
        pixelFormat: pixelFormat,
      );
    } on TimeoutException {
      debugPrint('⏱️ FFprobe timeout');
      return null;
    } catch (e) {
      debugPrint('❌ FFprobe error: $e');
      return null;
    }
  }

  // ─── 2. BUILD FFMPEG COMMAND ─────────────────────────────────
  static List<String> _buildFFmpegArguments({
    required String inputPath,
    required String outputPath,
    required String overlayPath,
    required int offsetX,
    required int offsetY,
    required _VideoInfo videoInfo,
    required bool keepAudio,
  }) {
    if (!File(inputPath).existsSync()) {
      throw Exception('Input file not found');
    }
    if (!File(overlayPath).existsSync()) {
      throw Exception('Overlay file not found');
    }

    // Filter: format base video, overlay langsung tanpa scaling
    final filterComplex =
        '[0:v]format=${videoInfo.pixelFormat},setsar=1[base];'
        '[base][1:v]overlay=$offsetX:$offsetY:format=auto:eof_action=pass[outv]';

    final useHw = _shouldUseHardwareEncoder();
    final encoder = useHw ? 'h264_mediacodec' : 'libx264';
    final bitrateK = (videoInfo.bitrate / 1000).round();

    final arguments = <String>[
      '-i', inputPath,
      '-loop', '1',
      '-i', overlayPath,
      '-filter_complex', filterComplex,
      '-map', '[outv]',
      '-c:v', encoder,
      '-b:v', '${bitrateK}k',
      '-pix_fmt', 'yuv420p',
      '-map_metadata', '0',
      '-movflags', '+faststart',
      '-shortest',
      '-y',
      outputPath,
    ];

    if (!useHw) {
      final maxrateK = (videoInfo.bitrate * 1.5 / 1000).round();
      final bufsizeK = (videoInfo.bitrate * 2 / 1000).round();
      arguments.insertAll(arguments.length - 1, [
        '-maxrate', '${maxrateK}k',
        '-bufsize', '${bufsizeK}k',
      ]);
    }

    if (keepAudio) {
      arguments.insertAll(arguments.length - 1, ['-map', '0:a?', '-c:a', 'copy']);
    } else {
      arguments.insertAll(arguments.length - 1, ['-an']);
    }

    return arguments;
  }

  // ─── 3. EXECUTE DENGAN FALLBACK ENCODER ─────────────────────
  static Future<bool> _executeEncodingWithFallback({
    required List<String> args,
    required _VideoInfo videoInfo,
    required int timeoutSeconds,
    required int attempt,
  }) async {
    List<String> effectiveArgs = List.from(args);
    final completer = Completer<bool>();
    Timer? timeoutTimer;
    FFmpegSession? session;
    bool isSoftwareFallback = false;
    bool sessionStarted = false;

    if (attempt > 0) {
      final encoderIndex = effectiveArgs.indexOf('-c:v');
      if (encoderIndex != -1 && encoderIndex + 1 < effectiveArgs.length) {
        if (effectiveArgs[encoderIndex + 1] == 'h264_mediacodec') {
          effectiveArgs[encoderIndex + 1] = 'libx264';
          isSoftwareFallback = true;
          debugPrint('🔄 Fallback ke software encoder (libx264)');

          effectiveArgs.removeWhere((arg) => arg == '-maxrate' || arg == '-bufsize');

          final maxrateK = (videoInfo.bitrate * 1.5 / 1000).round();
          final bufsizeK = (videoInfo.bitrate * 2 / 1000).round();
          final yIndex = effectiveArgs.indexOf('-y');
          if (yIndex != -1) {
            effectiveArgs.insertAll(yIndex, [
              '-maxrate', '${maxrateK}k',
              '-bufsize', '${bufsizeK}k',
            ]);
          }
        }
      }
    }

    // Mulai eksekusi dengan await untuk mendapatkan session
    try {
      // executeWithArguments mengembalikan Future<FFmpegSession>
      session = await FFmpegKit.executeWithArguments(effectiveArgs);
      sessionStarted = true;

      // Simpan session segera untuk cancel
      await _sessionLock.synchronized(() async {
        _currentSession = session;
      });

      // Pasang timeout setelah session didapat
      timeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
        if (!completer.isCompleted) {
          debugPrint('⏱️ TIMEOUT: $timeoutSeconds detik');
          unawaited(cancel());
          lastError = 'Encoding timeout';
          completer.complete(false);
        }
      });

      // Tunggu return code secara asynchronous
      final returnCode = await session!.getReturnCode();
      timeoutTimer.cancel();

      if (completer.isCompleted) {
        return await completer.future;
      }

      if (_isCancelled) {
        completer.complete(false);
        return await completer.future;
      }

      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session!.getAllLogsAsString() ?? '';

        if (!isSoftwareFallback &&
            attempt < _maxHwFallbackAttempts &&
            (logs.contains('encoder not found') ||
                logs.contains('Unknown encoder') ||
                logs.contains('cannot init encoder') ||
                logs.contains('h264_mediacodec'))) {
          debugPrint('⚠️ Hardware encoder gagal, mencoba fallback...');
          final retryResult = await _executeEncodingWithFallback(
            args: effectiveArgs,
            videoInfo: videoInfo,
            timeoutSeconds: timeoutSeconds,
            attempt: attempt + 1,
          );
          if (!completer.isCompleted) completer.complete(retryResult);
          return await completer.future;
        }

        if (logs.toLowerCase().contains('cancelled') ||
            logs.toLowerCase().contains('canceled')) {
          debugPrint('⏹️ Encoding dibatalkan');
          completer.complete(false);
        } else {
          lastError = diagnoseFailure(logs);
          debugPrint('❌ FFmpeg error:\n$logs');
          completer.complete(false);
        }
      } else {
        if (isSoftwareFallback) {
          debugPrint('✅ Encoding berhasil dengan software encoder');
        }
        completer.complete(true);
      }

      return await completer.future;
    } catch (e) {
      debugPrint('❌ Encoding exception: $e');
      timeoutTimer?.cancel();
      unawaited(cancel());
      if (!completer.isCompleted) completer.complete(false);
      return false;
    } finally {
      await _sessionLock.synchronized(() async {
        _currentSession = null;
      });
    }
  }

  // ─── FALLBACK DRAWTEXT ──────────────────────────────────────
  static Future<String?> _addWatermarkWithDrawtext({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    required _VideoInfo videoInfo,
    void Function(double progress)? onProgress,
    int timeoutSeconds = _defaultTimeoutSeconds,
  }) async {
    debugPrint('📝 Drawtext fallback...');

    _isCancelled = false;
    _lastProgress = 0;
    _lastProgressTime = DateTime.now();
    _currentDuration = videoInfo.duration;
    _currentProgressCallback = onProgress;

    try {
      final operator = settings.operatorName.isNotEmpty ? settings.operatorName : '';
      final company = settings.companyName.isNotEmpty ? '\n${settings.companyName}' : '';

      final dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
      final timestamp = dateFormat.format(entry.timestamp);

      final barcode = entry.value ?? 'No Barcode';
      final location = entry.locationName ?? '';

      String text = '$operator$company\n$timestamp\n$barcode';
      if (location.isNotEmpty) text += '\n$location';
      text = _escapeDrawText(text);

      final padding = 20;
      final pos = settings.position;
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

      String drawText =
          "drawtext=text='$text':"
          "fontcolor=white:"
          "fontsize=$fontSize:"
          "box=1:"
          "boxcolor=black@$opacity:"
          "boxborderw=5:"
          "x=$x:y=$y";

      final useHw = _shouldUseHardwareEncoder();
      final encoder = useHw ? 'h264_mediacodec' : 'libx264';
      final bitrateK = (videoInfo.bitrate / 1000).round();

      final commandArgs = <String>[
        '-i', inputPath,
        '-vf', 'format=${videoInfo.pixelFormat},setsar=1,$drawText',
        '-c:a', 'copy',
        '-c:v', encoder,
        '-b:v', '${bitrateK}k',
      ];

      if (!useHw) {
        final maxrateK = (videoInfo.bitrate * 1.5 / 1000).round();
        final bufsizeK = (videoInfo.bitrate * 2 / 1000).round();
        commandArgs.addAll(['-maxrate', '${maxrateK}k', '-bufsize', '${bufsizeK}k']);
      }

      commandArgs.addAll([
        '-pix_fmt', 'yuv420p',
        '-map_metadata', '0',
        '-movflags', '+faststart',
        '-y', outputPath,
      ]);

      debugPrint('🎬 Fallback: ${commandArgs.join(' ')}');

      final completer = Completer<String?>();
      Timer? timeoutTimer;

      // Eksekusi dan simpan session setelah didapat
      FFmpegSession? session;
      try {
        session = await FFmpegKit.executeWithArguments(commandArgs);
        await _sessionLock.synchronized(() async {
          _currentSession = session;
        });

        timeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
          if (!completer.isCompleted) {
            debugPrint('⏱️ TIMEOUT: Fallback drawtext');
            if (_currentSession != null) {
              FFmpegKit.cancel(_currentSession!);
            }
            completer.complete(null);
          }
        });

        final returnCode = await session!.getReturnCode();
        timeoutTimer.cancel();

        await _sessionLock.synchronized(() async {
          _currentSession = null;
        });

        if (_isCancelled || completer.isCompleted) {
          completer.complete(null);
          return await completer.future;
        }

        if (ReturnCode.isSuccess(returnCode)) {
          debugPrint('✅ Fallback drawtext berhasil');
          completer.complete(outputPath);
        } else {
          final logs = await session!.getOutput();
          debugPrint('❌ Fallback drawtext error: $logs');
          lastError = logs;
          completer.complete(null);
        }
      } catch (e) {
        timeoutTimer?.cancel();
        _currentSession = null;
        debugPrint('❌ Fallback exception: $e');
        completer.complete(null);
      }

      return await completer.future;
    } catch (e) {
      debugPrint('❌ Fallback exception: $e');
      return null;
    } finally {
      _currentProgressCallback = null;
    }
  }

  static String _escapeDrawText(String text) {
    return text
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "'\\\\''")
        .replaceAll(':', '\\:')
        .replaceAll(',', '\\,')
        .replaceAll('[', '\\[')
        .replaceAll(']', '\\]')
        .replaceAll('%', '\\%');
  }

  // ─── RENDER OVERLAY ──────────────────────────────────────────
  static Future<(String?, int, int)?> _renderOverlay({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    final key = _getStableCacheKey(outW, outH, settings, entry);

    if (_overlayFileCache.containsKey(key)) {
      final cachedPath = _overlayFileCache[key]!;
      if (await File(cachedPath).exists()) {
        debugPrint('🔄 Menggunakan overlay dari cache (${outW}x${outH})');
        // Update LRU
        _overlayFileCache.remove(key);
        _overlayFileCache[key] = cachedPath;
        return (cachedPath, 0, 0);
      } else {
        _overlayFileCache.remove(key);
      }
    }

    debugPrint('🎨 Membuat overlay PNG ${outW}x${outH}...');
    final Uint8List? overlayBytes = await WatermarkRenderer.renderOverlayPng(
      canvasWidth: outW,
      canvasHeight: outH,
      settings: settings,
      entry: entry,
    );
    if (overlayBytes == null || overlayBytes.isEmpty) {
      debugPrint('❌ renderOverlayPng null');
      return null;
    }
    debugPrint('✅ Overlay PNG berhasil (${overlayBytes.length} bytes)');

    final cacheDir = await _getCacheDirectory();
    final fileName = 'overlay_$key.png';
    final filePath = '${cacheDir.path}/$fileName';
    await File(filePath).writeAsBytes(overlayBytes);

    _overlayFileCache[key] = filePath;
    if (_overlayFileCache.length > _maxCacheSize) _trimCache();

    return (filePath, 0, 0);
  }

  static String _getStableCacheKey(int outW, int outH, WatermarkSettings settings, ScanEntry entry) {
    final parts = [
      outW, outH,
      settings.style.name,
      settings.companyName,
      settings.operatorName,
      settings.position.name,
      settings.fontSize,
      settings.backgroundOpacity,
      settings.fontFamily,
      settings.logoPath ?? '',
      settings.hasLogo,
      entry.timestamp.toIso8601String(),
      entry.value,
      entry.barcodeFormat ?? '',
      entry.locationName ?? '',
      entry.latitude ?? '',
      entry.longitude ?? '',
    ].join('|');

    final bytes = utf8.encode(parts);
    final digest = sha1.convert(bytes);
    return digest.toString().substring(0, 16);
  }

  static Future<Directory> _getCacheDirectory() async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/watermark_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return cacheDir;
  }

  static void _trimCache() {
    if (_overlayFileCache.length <= _maxCacheSize) return;
    final entries = _overlayFileCache.entries.toList();
    final toRemove = entries.take(_overlayFileCache.length - _maxCacheSize);
    for (final entry in toRemove) {
      try { File(entry.value).deleteSync(); } catch (_) {}
      _overlayFileCache.remove(entry.key);
    }
  }

  // ─── PEMBERSIHAN CACHE OVERLAY ──────────────────────────────
  static Future<void> _cleanOrphanOverlayFiles() async {
    try {
      final cacheDir = await _getCacheDirectory();
      final files = cacheDir.listSync();
      final activeFiles = _overlayFileCache.values.toSet();

      int deleted = 0;
      for (final entity in files) {
        if (entity is File) {
          final path = entity.path;
          if (!activeFiles.contains(path)) {
            try {
              await entity.delete();
              deleted++;
            } catch (_) {}
          }
        }
      }
      if (deleted > 0) {
        debugPrint('🧹 Menghapus $deleted file overlay orphan dari disk');
      }
    } catch (e) {
      debugPrint('⚠️ Gagal membersihkan cache overlay: $e');
    }
  }

  // ─── DIAGNOSE ─────────────────────────────────────────────────
  static String diagnoseFailure(String logs) {
    final l = logs.toLowerCase();
    if (l.contains('overlay.png') && (l.contains('no such file') || l.contains('invalid data found'))) {
      return 'Overlay PNG watermark gagal dibuat/dibaca.';
    }
    if (l.contains('unknown encoder') || l.contains('encoder not found')) {
      return 'Encoder tidak tersedia. Coba gunakan software encoder.';
    }
    if (l.contains('invalid argument') && l.contains('overlay')) {
      return 'Argumen filter overlay tidak valid. Periksa ukuran watermark.';
    }
    if (l.contains('permission denied')) {
      return 'Tidak ada izin baca/tulis.';
    }
    if (l.contains('moov atom not found') || l.contains('invalid data found')) {
      return 'File video input korup.';
    }
    if (l.contains('cannot allocate memory')) {
      return 'Memori tidak cukup. Turunkan resolusi atau bitrate.';
    }
    if (l.contains('broken pipe')) {
      return 'Proses encoding terputus.';
    }
    if (l.contains('too many packets buffered')) {
      return 'Buffer FFmpeg penuh. Kurangi thread atau pakai preset lebih lambat.';
    }
    if (l.contains('cannot init encoder')) {
      return 'Encoder gagal diinisialisasi. Coba software encoder.';
    }
    if (l.contains('error while opening encoder')) {
      return 'Gagal membuka encoder. Periksa parameter.';
    }
    if (l.contains('no space left on device')) {
      return 'Ruang penyimpanan tidak cukup.';
    }
    if (l.contains('timeout')) {
      return 'Encoding timeout. Coba gunakan preset lebih cepat.';
    }
    if (l.contains('cancelled') || l.contains('canceled')) {
      return 'Proses encoding dibatalkan.';
    }
    return 'Penyebab tidak dikenal. Cek log lengkap.';
  }
}

// ─── ASYNC LOCK ──────────────────────────────────────────────
class _AsyncLock {
  Future<void>? _lockFuture;

  Future<T> synchronized<T>(Future<T> Function() action) {
    final previousLock = _lockFuture;
    final completer = Completer<T>();

    _lockFuture = (previousLock ?? Future<void>.value()).then((_) {
      return action().then((result) {
        completer.complete(result);
      }).catchError((error) {
        completer.completeError(error);
        return Future.error(error);
      });
    }).catchError((_) {
      // Jika ada error di chain, tetap lanjutkan untuk panggilan selanjutnya
    });

    return completer.future;
  }
}

// ─── VIDEO INFO ──────────────────────────────────────────────
class _VideoInfo {
  final int width;
  final int height;
  final double duration;
  final int bitrate;
  final double fps;
  final String pixelFormat;

  const _VideoInfo({
    required this.width,
    required this.height,
    required this.duration,
    required this.bitrate,
    required this.fps,
    required this.pixelFormat,
  });
}
