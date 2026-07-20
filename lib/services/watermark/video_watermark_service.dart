// lib/services/watermark/video_watermark_service.dart
// Versi Final Production - Dengan perbaikan storage check
// Kompatibel dengan ffmpeg_kit_flutter_new 4.5.1

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show TextPainter, TextSpan, TextStyle;
import 'package:intl/intl.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart' show sha1;
import '../../models/scan_entry.dart';
import '../../watermark/watermark_settings.dart';
import '../../watermark/watermark_renderer.dart';
import 'watermark_cache.dart';

class VideoWatermarkService {
  // ===================== STATIC VARIABLES =====================
  
  static String? lastError;
  static bool _warmedUp = false;
  static final WatermarkCache _cache = WatermarkCache();

  static final LinkedHashMap<String, String> _overlayFileCache = LinkedHashMap();
  static const int _maxCacheSize = 50;
  static bool _cacheCleaned = false;

  static bool _isEncoding = false;
  static String? _currentSessionId;
  static dynamic _currentSession;
  static void Function(double)? _currentProgressCallback;
  static double _currentDuration = 0;
  static bool _isCancelled = false;
  static final _AsyncLock _sessionLock = _AsyncLock();

  static const int _defaultTimeoutSeconds = 300;

  // Preset libx264 (dipakai saat hw encoder tidak tersedia/gagal).
  // 'veryfast' = keseimbangan render speed vs ukuran/kualitas file.
  static const String _x264Preset = 'veryfast';
  static const int _progressWatchdogInterval = 10;
  static const int _progressWatchdogThreshold = 30;
  static Timer? _watchdogTimer;
  static double _lastProgress = 0;
  static DateTime _lastProgressTime = DateTime.now();

  static DateTime _lastCallbackTime = DateTime.now().subtract(const Duration(seconds: 1));
  static double _lastReportedProgress = -1.0;
  static const Duration _progressThrottleInterval = Duration(milliseconds: 150);
  static const double _progressMinDelta = 0.005;

  static bool? _hwEncoderAvailable;
  static bool? _isEmulator;
  static bool _hwEncoderChecked = false;
  static const int _maxHwFallbackAttempts = 2;

  static const Set<String> _supportedPixelFormats = {
    'yuv420p', 'yuv422p', 'yuv444p', 'nv12', 'nv21', 'rgb24', 'bgr24',
  };
  
  static int _lastMemoryCheck = 0;
  static const int _memoryCheckInterval = 30;

  // ===================== KONSTANTA PADDING & MARGIN =====================
  
  // Internal padding: jarak antara konten watermark dengan tepi overlay
  static const double _internalPadding = 20.0;
  
  // Step-based margin ke tepi video
  // Menggunakan nilai bulat yang konsisten untuk resolusi standar
  static const Map<int, int> _marginByResolution = {
    480: 16,   // SD
    720: 18,   // 720p
    1080: 24,  // 1080p
    1440: 32,  // 1440p (2K)
    2160: 48,  // 2160p (4K)
  };
  static const int _defaultMargin = 64; // Untuk >4K

  // ===================== INISIALISASI =====================

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

  static Future<void> preload(WatermarkSettings settings) async {
    await _cache.initialize(settings);
    unawaited(_detectHardwareEncoder());
    _registerGlobalStatisticsCallback();
    if (!_cacheCleaned) {
      await _cleanOrphanOverlayFiles();
      _cacheCleaned = true;
    }
  }

  static void _registerGlobalStatisticsCallback() {
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

  // ===================== COMPUTE EDGE MARGIN =====================
  
  /// Menghitung margin edge berdasarkan resolusi video
  /// Menggunakan step-based approach untuk konsistensi di resolusi standar
  static int computeEdgeMargin(int videoWidth, int videoHeight) {
    final shortSide = min(videoWidth, videoHeight);
    
    // Cari margin berdasarkan resolusi terdekat (ke atas)
    int margin = _defaultMargin;
    for (final entry in _marginByResolution.entries) {
      if (shortSide <= entry.key) {
        margin = entry.value;
        break;
      }
    }
    
    return margin;
  }

  // ===================== DETEKSI HARDWARE ENCODER =====================

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

  // ===================== MANAJEMEN MEMORI =====================

  static Future<void> _handleMemoryPressure() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (now - _lastMemoryCheck < _memoryCheckInterval) return;
    _lastMemoryCheck = now;
    
    try {
      if (Platform.isAndroid) {
        final result = await Process.run('dumpsys', ['meminfo', '${pid}']);
        final output = result.stdout.toString();
        
        final nativeHeapMatch = RegExp(r'Native Heap\s+(\d+)').firstMatch(output);
        if (nativeHeapMatch != null) {
          final nativeHeap = int.tryParse(nativeHeapMatch.group(1) ?? '0') ?? 0;
          if (nativeHeap > 200 * 1024) {
            debugPrint('⚠️ Memory pressure detected (Native Heap: ${nativeHeap ~/ 1024}MB)');
            _trimOverlayCache(force: true);
            await Future.delayed(Duration.zero);
          }
        }
      }
    } catch (_) {}
  }

  // ===================== MANAJEMEN CACHE OVERLAY =====================

  static void _trimOverlayCache({bool force = false}) {
    if (!force && _overlayFileCache.length <= _maxCacheSize) return;
    
    final entries = _overlayFileCache.entries.toList();
    final toRemove = force ? 
        entries.take(max(0, _overlayFileCache.length - 10)) : 
        entries.take(max(0, _overlayFileCache.length - _maxCacheSize));
    
    int deleted = 0;
    for (final entry in toRemove) {
      try { 
        final file = File(entry.value);
        if (file.existsSync()) {
          file.deleteSync();
          deleted++;
        }
      } catch (_) {}
      _overlayFileCache.remove(entry.key);
    }
    
    if (deleted > 0) {
      debugPrint('🧹 Cache trimmed: $deleted files deleted');
    }
  }

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
      if (deleted > 0) debugPrint('🧹 Menghapus $deleted file overlay orphan dari disk');
    } catch (e) {
      debugPrint('⚠️ Gagal membersihkan cache overlay: $e');
    }
  }

  static Future<Directory> _getCacheDirectory() async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/watermark_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return cacheDir;
  }

  // ===================== CEK STORAGE =====================

  static Future<bool> _hasSufficientSpace(String outputPath, int inputSize) async {
    try {
      // Cek sisa storage dengan cara yang lebih sederhana
      // Di Android, kita bisa gunakan StatFS atau cek available space di directory
      final dir = Directory(File(outputPath).parent.path);
      
      // Untuk Android, kita bisa menggunakan getTotalSpace dan getFreeSpace
      // Tapi karena API ini tidak tersedia di Dart, kita gunakan pendekatan alternatif
      // Coba tulis file test kecil untuk cek apakah ada space
      final testFile = File('${dir.path}/.space_test.tmp');
      try {
        await testFile.writeAsBytes(List.filled(1024, 0)); // Tulis 1KB
        await testFile.delete();
        return true;
      } catch (e) {
        // Jika gagal menulis, kemungkinan storage penuh
        debugPrint('⚠️ Storage penuh atau tidak dapat diakses: $e');
        return false;
      }
    } catch (_) {
      // Jika tidak bisa menentukan, proceed dengan hati-hati
      return true;
    }
  }

  // ===================== FUNGSI UTAMA =====================

  static Future<void> cancel({bool force = false}) async {
    await _sessionLock.synchronized(() async {
      if (_currentSessionId == null) {
        debugPrint('⚠️ Tidak ada session aktif');
        return;
      }
      debugPrint('🛑 Cancel encoding${force ? " (force)" : ""}...');
      _isCancelled = true;
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      
      if (_currentSession != null) {
        try {
          // Gunakan cancel dengan session
          FFmpegKit.cancel(_currentSession);
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

  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    bool keepAudio = true,
    int timeoutSeconds = _defaultTimeoutSeconds,
    void Function(double progress)? onProgress,
  }) async {
    // VALIDASI AWAL
    if (_isEncoding) {
      throw Exception('Encoding sedang berjalan. Tunggu selesai.');
    }
    
    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      lastError = 'File input tidak ditemukan';
      throw Exception(lastError);
    }
    
    final inputSize = await inputFile.length();
    if (!await _hasSufficientSpace(outputPath, inputSize)) {
      lastError = 'Ruang penyimpanan tidak cukup';
      throw Exception(lastError);
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
      // INISIALISASI
      await warmUp();
      await _cache.initialize(settings);
      if (!_hwEncoderChecked) {
        await _detectHardwareEncoder();
      }
      if (!_cacheCleaned) {
        await _cleanOrphanOverlayFiles();
        _cacheCleaned = true;
      }

      // DAPATKAN INFO VIDEO
      final videoInfo = await _getVideoInfo(inputPath);
      if (videoInfo == null) {
        throw Exception('Gagal membaca info video');
      }
      
      // Gunakan dimensi yang sudah disesuaikan dengan orientasi
      final displayWidth = videoInfo.displayWidth;
      final displayHeight = videoInfo.displayHeight;
      
      debugPrint('📹 ${videoInfo.width}x${videoInfo.height}, '
          'Display: ${displayWidth}x${displayHeight}, '
          '${videoInfo.fps.toStringAsFixed(2)}fps, '
          '${(videoInfo.bitrate / 1000).round()}kbps, '
          '${videoInfo.pixelFormat}, '
          '${videoInfo.duration.toStringAsFixed(1)}s');
      
      if (videoInfo.rotation != 0) {
        debugPrint('🔄 Rotasi terdeteksi: ${videoInfo.rotation}°');
      }

      // HITUNG EDGE MARGIN (step-based)
      final edgeMargin = computeEdgeMargin(displayWidth, displayHeight);
      debugPrint('📏 Edge margin: ${edgeMargin}px '
          '(shortSide: ${min(displayWidth, displayHeight)}px)');

      _currentDuration = videoInfo.duration;

      // KOMPUTASI UKURAN WATERMARK
      final (needW, needH) = _computeWatermarkSize(settings, entry);
      
      // Overlay size = watermark size + internal padding
      int ovW = needW + (_internalPadding * 2).ceil();
      int ovH = needH + (_internalPadding * 2).ceil();
      ovW = (ovW ~/ 2) * 2;
      ovH = (ovH ~/ 2) * 2;
      overlayW = ovW;
      overlayH = ovH;
      debugPrint('🎨 Overlay akan dirender pada ${ovW}x${ovH} '
          '(internal padding: ${_internalPadding}px)');

      // RENDER OVERLAY
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

      // KOMPUTASI POSISI menggunakan edge margin yang sudah dihitung
      switch (settings.position) {
        case WatermarkPosition.bottomRight:
          overlayOffsetX = displayWidth - ovW - edgeMargin;
          overlayOffsetY = displayHeight - ovH - edgeMargin;
          break;
        case WatermarkPosition.bottomLeft:
          overlayOffsetX = edgeMargin;
          overlayOffsetY = displayHeight - ovH - edgeMargin;
          break;
        case WatermarkPosition.topRight:
          overlayOffsetX = displayWidth - ovW - edgeMargin;
          overlayOffsetY = edgeMargin;
          break;
        case WatermarkPosition.topLeft:
          overlayOffsetX = edgeMargin;
          overlayOffsetY = edgeMargin;
          break;
      }
      
      // CLAMP POSISI (mencegah offset negatif)
      overlayOffsetX = max(0, overlayOffsetX);
      overlayOffsetY = max(0, overlayOffsetY);
      
      debugPrint('🖼️ Overlay PNG siap, posisi ($overlayOffsetX,$overlayOffsetY) '
          'dengan edge margin ${edgeMargin}px');

      // SETUP SESSION
      await _sessionLock.synchronized(() async {
        _currentProgressCallback = onProgress;
        _isEncoding = true;
        _currentSessionId = DateTime.now().millisecondsSinceEpoch.toString();
      });

      // WATCHDOG TIMER
      _watchdogTimer?.cancel();
      _watchdogTimer = Timer.periodic(
        Duration(seconds: _progressWatchdogInterval),
        (timer) {
          if (_isCancelled) {
            timer.cancel();
            return;
          }
          final elapsed = DateTime.now().difference(_lastProgressTime).inSeconds;
          if (elapsed > _progressWatchdogThreshold && _lastProgress > 0.01) {
            debugPrint('⚠️ WATCHDOG: Tidak ada progress selama $elapsed detik');
            timer.cancel();
            unawaited(cancel());
            lastError = 'Encoding timeout - no progress';
          }
        },
      );

      // BUILD FFMPEG ARGUMENTS
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

      // EKSEKUSI ENCODING
      final success = await _executeEncodingWithFallback(
        args: args,
        videoInfo: videoInfo,
        timeoutSeconds: timeoutSeconds,
        attempt: 0,
      );

      // CLEANUP
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
      if (overlayPath != null && !_overlayFileCache.containsValue(overlayPath)) {
        try {
          final f = File(overlayPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  // ===================== KOMPUTASI UKURAN WATERMARK =====================

  static (int, int) _computeWatermarkSize(WatermarkSettings settings, ScanEntry entry) {
    final operator = settings.operatorName.isNotEmpty ? settings.operatorName : '';
    final company = settings.companyName.isNotEmpty ? '\n${settings.companyName}' : '';
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    final timestamp = dateFormat.format(entry.timestamp);
    final barcode = entry.value ?? 'No Barcode';
    final location = entry.locationName ?? '';

    String text = '$operator$company\n$timestamp\n$barcode';
    if (location.isNotEmpty) text += '\n$location';

    final textStyle = TextStyle(
      fontSize: settings.fontSize.toDouble(),
      fontFamily: settings.fontFamily,
      color: const ui.Color(0xFFFFFFFF),
    );
    final textSpan = TextSpan(text: text, style: textStyle);
    final painter = TextPainter(
      text: textSpan,
      textDirection: ui.TextDirection.ltr,
    );
    painter.layout(maxWidth: double.infinity);
    final size = painter.size;

    // Hanya ukuran konten, padding akan ditambahkan di overlay
    int w = size.width.ceil();
    int h = size.height.ceil();
    
    if (settings.hasLogo && settings.logoPath != null) {
      w += 60;
      h = max(h, 70);
    }
    
    // Minimal ukuran agar tidak terlalu kecil
    w = max(w, 100);
    h = max(h, 50);
    w = (w ~/ 2) * 2;
    h = (h ~/ 2) * 2;
    return (w, h);
  }

  // ===================== GET VIDEO INFO =====================

  static Future<_VideoInfo?> _getVideoInfo(String inputPath) async {
    try {
      final session = await FFprobeKit.getMediaInformation(inputPath)
          .timeout(const Duration(seconds: 10));
      final mediaInfo = session.getMediaInformation();
      if (mediaInfo == null) return null;

      final durationObj = mediaInfo.getDuration();
      final double duration = double.tryParse(durationObj?.toString() ?? '') ?? 0.0;

      int width = 0, height = 0;
      int bitrate = 0;
      double fps = 0;
      String pixelFormat = 'yuv420p';
      int rotation = 0;
      int displayWidth = 0;
      int displayHeight = 0;

      final streams = mediaInfo.getStreams();
      for (final stream in streams) {
        final w = stream.getWidth();
        final h = stream.getHeight();
        if (w != null && h != null && w > 0 && h > 0) {
          width = w;
          height = h;
          displayWidth = w;
          displayHeight = h;

          // Baca rotasi dari tag
          final tags = stream.getTags();
          if (tags != null) {
            final rotateTag = tags['rotate'];
            if (rotateTag != null) {
              final rotValue = int.tryParse(rotateTag.toString());
              if (rotValue != null) {
                rotation = rotValue % 360;
                if (rotation < 0) rotation += 360;
              }
            }
          }

          // Sesuaikan display dimensions berdasarkan rotasi
          if (rotation == 90 || rotation == 270) {
            displayWidth = h;
            displayHeight = w;
          }

          final brStr = stream.getBitrate();
          if (brStr != null) {
            final parsed = int.tryParse(brStr);
            if (parsed != null && parsed > 0) bitrate = parsed;
          }

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
      
      // Pastikan dimensi genap untuk codec
      width = (width ~/ 2) * 2;
      height = (height ~/ 2) * 2;
      displayWidth = (displayWidth ~/ 2) * 2;
      displayHeight = (displayHeight ~/ 2) * 2;

      return _VideoInfo(
        width: width,
        height: height,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        duration: duration,
        bitrate: bitrate,
        fps: fps,
        pixelFormat: pixelFormat,
        rotation: rotation,
      );
    } on TimeoutException {
      debugPrint('⏱️ FFprobe timeout');
      return null;
    } catch (e) {
      debugPrint('❌ FFprobe error: $e');
      return null;
    }
  }

  // ===================== BUILD FFMPEG ARGUMENTS =====================

  static List<String> _buildFFmpegArguments({
    required String inputPath,
    required String outputPath,
    required String overlayPath,
    required int offsetX,
    required int offsetY,
    required _VideoInfo videoInfo,
    required bool keepAudio,
  }) {
    if (!File(inputPath).existsSync()) throw Exception('Input file not found');
    if (!File(overlayPath).existsSync()) throw Exception('Overlay file not found');

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
        '-preset', _x264Preset,
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

  // ===================== EKSEKUSI ENCODING DENGAN FALLBACK =====================

  static Future<bool> _executeEncodingWithFallback({
    required List<String> args,
    required _VideoInfo videoInfo,
    required int timeoutSeconds,
    required int attempt,
  }) async {
    List<String> effectiveArgs = List.from(args);
    final completer = Completer<bool>();
    Timer? timeoutTimer;
    dynamic session;
    bool isSoftwareFallback = false;

    await _handleMemoryPressure();

    if (attempt > 0) {
      final encoderIndex = effectiveArgs.indexOf('-c:v');
      if (encoderIndex != -1 && encoderIndex + 1 < effectiveArgs.length) {
        if (effectiveArgs[encoderIndex + 1] == 'h264_mediacodec') {
          effectiveArgs[encoderIndex + 1] = 'libx264';
          isSoftwareFallback = true;
          debugPrint('🔄 Fallback ke software encoder (libx264)');
          // Hapus flag -maxrate/-bufsize/-preset BESERTA value-nya (pasangan),
          // bukan cuma nama flag-nya (sebelumnya value nyangkut jadi arg liar).
          for (final flag in ['-maxrate', '-bufsize', '-preset']) {
            final idx = effectiveArgs.indexOf(flag);
            if (idx != -1 && idx + 1 < effectiveArgs.length) {
              effectiveArgs.removeRange(idx, idx + 2);
            }
          }
          final maxrateK = (videoInfo.bitrate * 1.5 / 1000).round();
          final bufsizeK = (videoInfo.bitrate * 2 / 1000).round();
          final yIndex = effectiveArgs.indexOf('-y');
          if (yIndex != -1) {
            effectiveArgs.insertAll(yIndex, [
              '-preset', _x264Preset,
              '-maxrate', '${maxrateK}k',
              '-bufsize', '${bufsizeK}k',
            ]);
          }
        }
      }
    }

    if (attempt == 2) {
      debugPrint('🔄 Mencoba dengan pixel format yuv420p...');
      final pixFmtIndex = effectiveArgs.indexOf('-pix_fmt');
      if (pixFmtIndex != -1 && pixFmtIndex + 1 < effectiveArgs.length) {
        effectiveArgs[pixFmtIndex + 1] = 'yuv420p';
      }
    }

    if (attempt == 3) {
      debugPrint('🔄 Mencoba dengan bitrate lebih rendah...');
      final bitrateIndex = effectiveArgs.indexOf('-b:v');
      if (bitrateIndex != -1 && bitrateIndex + 1 < effectiveArgs.length) {
        final currentBitrate = effectiveArgs[bitrateIndex + 1];
        if (currentBitrate.endsWith('k')) {
          final bitrateValue = int.tryParse(currentBitrate.replaceAll('k', ''));
          if (bitrateValue != null && bitrateValue > 300) {
            effectiveArgs[bitrateIndex + 1] = '${(bitrateValue * 0.7).round()}k';
            debugPrint('📉 Bitrate dikurangi menjadi ${effectiveArgs[bitrateIndex + 1]}');
          }
        }
      }
    }

    try {
      session = await FFmpegKit.executeWithArguments(effectiveArgs);
      await _sessionLock.synchronized(() async {
        _currentSession = session;
      });
      
      timeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
        if (!completer.isCompleted) {
          debugPrint('⏱️ TIMEOUT: $timeoutSeconds detik');
          unawaited(cancel());
          lastError = 'Encoding timeout';
          completer.complete(false);
        }
      });

      final returnCode = await session.getReturnCode();
      timeoutTimer.cancel();

      if (completer.isCompleted) return await completer.future;
      if (_isCancelled) {
        completer.complete(false);
        return await completer.future;
      }

      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getAllLogsAsString() ?? '';
        final logsLower = logs.toLowerCase();
        
        if (!isSoftwareFallback &&
            attempt < _maxHwFallbackAttempts &&
            (logsLower.contains('encoder not found') ||
                logsLower.contains('unknown encoder') ||
                logsLower.contains('cannot init encoder') ||
                logsLower.contains('h264_mediacodec'))) {
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
        
        if (attempt < 3 && logsLower.contains('pixel format')) {
          debugPrint('⚠️ Pixel format error, mencoba fallback...');
          final retryResult = await _executeEncodingWithFallback(
            args: effectiveArgs,
            videoInfo: videoInfo,
            timeoutSeconds: timeoutSeconds,
            attempt: attempt + 1,
          );
          if (!completer.isCompleted) completer.complete(retryResult);
          return await completer.future;
        }
        
        if (attempt < 4 && (logsLower.contains('cannot allocate memory') ||
            logsLower.contains('out of memory'))) {
          debugPrint('⚠️ Memory error, mencoba dengan pengaturan lebih rendah...');
          await _handleMemoryPressure();
          final retryResult = await _executeEncodingWithFallback(
            args: effectiveArgs,
            videoInfo: videoInfo,
            timeoutSeconds: timeoutSeconds,
            attempt: attempt + 1,
          );
          if (!completer.isCompleted) completer.complete(retryResult);
          return await completer.future;
        }
        
        if (logsLower.contains('cancelled') || logsLower.contains('canceled')) {
          debugPrint('⏹️ Encoding dibatalkan');
          completer.complete(false);
        } else {
          lastError = diagnoseFailure(logs);
          debugPrint('❌ FFmpeg error:\n$logs');
          completer.complete(false);
        }
      } else {
        if (isSoftwareFallback) debugPrint('✅ Encoding berhasil dengan software encoder');
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

  // ===================== FALLBACK DRAWTEXT =====================

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

      // Gunakan step-based margin untuk drawtext juga
      final edgeMargin = computeEdgeMargin(
        videoInfo.displayWidth, 
        videoInfo.displayHeight
      );
      
      final pos = settings.position;
      String x, y;
      switch (pos) {
        case WatermarkPosition.bottomRight:
          x = '(w-tw)-$edgeMargin';
          y = '(h-th)-$edgeMargin';
          break;
        case WatermarkPosition.bottomLeft:
          x = '$edgeMargin';
          y = '(h-th)-$edgeMargin';
          break;
        case WatermarkPosition.topRight:
          x = '(w-tw)-$edgeMargin';
          y = '$edgeMargin';
          break;
        case WatermarkPosition.topLeft:
          x = '$edgeMargin';
          y = '$edgeMargin';
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
        commandArgs.addAll(['-preset', _x264Preset, '-maxrate', '${maxrateK}k', '-bufsize', '${bufsizeK}k']);
      }
      commandArgs.addAll([
        '-pix_fmt', 'yuv420p',
        '-map_metadata', '0',
        '-movflags', '+faststart',
        '-y', outputPath,
      ]);

      debugPrint('🎬 Fallback drawtext dengan edge margin ${edgeMargin}px');

      final completer = Completer<String?>();
      Timer? timeoutTimer;
      dynamic session;
      
      final callback = onProgress;
      Timer? progressTimer;
      if (callback != null) {
        int progressCount = 0;
        progressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
          if (_isCancelled || completer.isCompleted) {
            timer.cancel();
            return;
          }
          progressCount++;
          final simulatedProgress = min(0.1 + (progressCount * 0.01), 0.95);
          callback(simulatedProgress);
          if (simulatedProgress >= 0.95) {
            timer.cancel();
          }
        });
      }
      
      try {
        session = await FFmpegKit.executeWithArguments(commandArgs);
        await _sessionLock.synchronized(() async {
          _currentSession = session;
        });
        timeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
          if (!completer.isCompleted) {
            debugPrint('⏱️ TIMEOUT: Fallback drawtext');
            if (_currentSession != null) FFmpegKit.cancel(_currentSession);
            completer.complete(null);
          }
        });

        final returnCode = await session.getReturnCode();
        timeoutTimer.cancel();
        progressTimer?.cancel();
        
        await _sessionLock.synchronized(() async {
          _currentSession = null;
        });

        if (_isCancelled || completer.isCompleted) {
          completer.complete(null);
          return await completer.future;
        }
        
        if (ReturnCode.isSuccess(returnCode)) {
          debugPrint('✅ Fallback drawtext berhasil');
          if (callback != null) callback(1.0);
          completer.complete(outputPath);
        } else {
          final logs = await session.getOutput();
          debugPrint('❌ Fallback drawtext error: $logs');
          lastError = logs;
          completer.complete(null);
        }
      } catch (e) {
        timeoutTimer?.cancel();
        progressTimer?.cancel();
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

  // ===================== RENDER OVERLAY =====================

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
        _overlayFileCache.remove(key);
        _overlayFileCache[key] = cachedPath;
        return (cachedPath, 0, 0);
      } else {
        _overlayFileCache.remove(key);
      }
    }

    debugPrint('🎨 Membuat overlay PNG ${outW}x${outH}...');
    
    try {
      final Uint8List? overlayBytes = await WatermarkRenderer.renderOverlayPng(
        canvasWidth: outW,
        canvasHeight: outH,
        settings: settings,
        entry: entry,
      );
      
      if (overlayBytes == null || overlayBytes.isEmpty) {
        debugPrint('❌ renderOverlayPng null atau kosong');
        return null;
      }
      
      if (overlayBytes.length < 8 || 
          overlayBytes[0] != 0x89 || 
          overlayBytes[1] != 0x50 || 
          overlayBytes[2] != 0x4E || 
          overlayBytes[3] != 0x47) {
        debugPrint('❌ Data PNG tidak valid (header tidak sesuai)');
        return null;
      }
      
      debugPrint('✅ Overlay PNG berhasil (${overlayBytes.length} bytes)');

      final cacheDir = await _getCacheDirectory();
      final fileName = 'overlay_$key.png';
      final filePath = '${cacheDir.path}/$fileName';
      await File(filePath).writeAsBytes(overlayBytes);

      _overlayFileCache[key] = filePath;
      if (_overlayFileCache.length > _maxCacheSize) _trimOverlayCache();
      return (filePath, 0, 0);
      
    } catch (e) {
      debugPrint('❌ Error rendering overlay: $e');
      return null;
    }
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

  // ===================== DIAGNOSIS ERROR =====================

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
    if (l.contains('permission denied')) return 'Tidak ada izin baca/tulis.';
    if (l.contains('moov atom not found') || l.contains('invalid data found')) return 'File video input korup.';
    if (l.contains('cannot allocate memory')) return 'Memori tidak cukup. Turunkan resolusi atau bitrate.';
    if (l.contains('broken pipe')) return 'Proses encoding terputus.';
    if (l.contains('too many packets buffered')) return 'Buffer FFmpeg penuh. Kurangi thread atau pakai preset lebih lambat.';
    if (l.contains('cannot init encoder')) return 'Encoder gagal diinisialisasi. Coba software encoder.';
    if (l.contains('error while opening encoder')) return 'Gagal membuka encoder. Periksa parameter.';
    if (l.contains('no space left on device')) return 'Ruang penyimpanan tidak cukup.';
    if (l.contains('timeout')) return 'Encoding timeout. Coba gunakan preset lebih cepat.';
    if (l.contains('cancelled') || l.contains('canceled')) return 'Proses encoding dibatalkan.';
    if (l.contains('pixel format')) return 'Format pixel tidak didukung. Coba yuv420p.';
    return 'Penyebab tidak dikenal. Cek log lengkap.';
  }
}

// ===================== ASYNC LOCK =====================

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
    }).catchError((_) {});
    return completer.future;
  }
}

// ===================== VIDEO INFO =====================

class _VideoInfo {
  final int width;
  final int height;
  final int displayWidth;
  final int displayHeight;
  final double duration;
  final int bitrate;
  final double fps;
  final String pixelFormat;
  final int rotation;
  
  const _VideoInfo({
    required this.width,
    required this.height,
    required this.displayWidth,
    required this.displayHeight,
    required this.duration,
    required this.bitrate,
    required this.fps,
    required this.pixelFormat,
    this.rotation = 0,
  });
}
