// lib/services/watermark/watermark_service.dart
// VERSI FINAL - PRODUCTION READY (SEMUA BUG FIXED)
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/scan_entry.dart';
import '../../watermark/watermark_settings.dart';
import '../../watermark/watermark_renderer.dart';
import 'watermark_cache.dart';

/// Service untuk menambahkan watermark ke video dengan orientasi yang benar.
class VideoWatermarkService {
  static String? lastError;
  static bool _warmedUp = false;
  static final WatermarkCache _cache = WatermarkCache();

  // FIX 1: Async LRU Cache dengan lock
  static final LinkedHashMap<String, _CachedOverlay> _overlayCache = 
      LinkedHashMap<String, _CachedOverlay>();
  static const int _maxCacheSize = 50;
  static const int _cacheExpiryHours = 24;
  
  // FIX: AsyncLock untuk thread-safe operations
  static final _AsyncLock _cacheLock = _AsyncLock();
  
  // Session management
  static final Map<String, FFmpegSession> _activeSessions = {};
  static final Map<String, void Function(double)> _progressCallbacks = {};
  static final Map<String, bool> _cancelFlags = {};
  static final _AsyncLock _sessionLock = _AsyncLock();
  
  // FIX 4: Hardware encoder detection (cached)
  static bool? _hwEncoderAvailable;
  static bool _hwEncoderChecked = false;

  // ─── PRELOAD ──────────────────────────────────────────────
  static Future<void> preload(WatermarkSettings settings) async {
    await _cache.initialize(settings);
    // FIX 2 & 3: Background cleanup tanpa sync/stat di UI thread
    unawaited(_cleanupOldCacheAsync());
    if (kDebugMode) debugPrint('📦 VideoWatermarkService preload selesai');
  }

  // FIX 2 & 3: Async cleanup tanpa blocking
  static Future<void> _cleanupOldCacheAsync() async {
    try {
      final cacheDir = await _getCacheDirectory();
      final files = await cacheDir.list().toList();
      final now = DateTime.now();
      
      // FIX 3: Gunakan async delete, bukan sync
      await _cacheLock.synchronized(() async {
        for (final file in files) {
          if (file is File) {
            try {
              final stat = await file.stat();
              final age = now.difference(stat.modified).inHours;
              if (age > _cacheExpiryHours) {
                await file.delete();
                _overlayCache.removeWhere((key, value) => value.path == file.path);
                if (kDebugMode) debugPrint('🗑️ Hapus cache lama: ${file.path}');
              }
            } catch (_) {}
          }
        }
        
        // Hapus memory cache expired
        final expiredKeys = <String>[];
        _overlayCache.forEach((key, value) {
          final age = now.difference(value.createdAt).inHours;
          if (age > _cacheExpiryHours) {
            expiredKeys.add(key);
          }
        });
        for (final key in expiredKeys) {
          try { 
            final path = _overlayCache[key]?.path;
            if (path != null) {
              await File(path).delete();
            }
          } catch (_) {}
          _overlayCache.remove(key);
        }
        
        // Trim cache
        while (_overlayCache.length > _maxCacheSize) {
          final firstKey = _overlayCache.keys.first;
          final firstValue = _overlayCache[firstKey];
          if (firstValue != null) {
            try { await File(firstValue.path).delete(); } catch (_) {}
          }
          _overlayCache.remove(firstKey);
        }
      });
    } catch (_) {}
  }

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
      } else {
        debugPrint('⚠️ FFmpeg warm-up gagal (rc=${returnCode?.getValue()})');
      }
    } catch (e) {
      debugPrint('❌ FFmpeg warm-up error: $e');
    } finally {
      _warmedUp = true;
    }
  }

  // ─── CANCEL ──────────────────────────────────────────────────
  static Future<void> cancel(String sessionId) async {
    await _sessionLock.synchronized(() async {
      _cancelFlags[sessionId] = true;
      
      final session = _activeSessions[sessionId];
      if (session != null) {
        FFmpegKit.cancel(session);
        if (kDebugMode) debugPrint('🛑 Cancel FFmpeg session: $sessionId');
        _activeSessions.remove(sessionId);
      }
    });
  }

  // ─── ADD WATERMARK ────────────────────────────────────────────
  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    bool keepAudio = false,
    bool useHardwareEncoder = false,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
  }) async {
    lastError = null;
    String? overlayPath;
    int offsetX = 0, offsetY = 0;
    
    final String sessionId = '${DateTime.now().millisecondsSinceEpoch}_${_randomString(8)}';

    try {
      await _cache.initialize(settings);
      await warmUp();

      final videoInfo = await _getVideoDisplayInfo(inputPath);
      if (videoInfo == null) {
        throw Exception('Gagal membaca informasi video');
      }
      
      debugPrint('📹 VIDEO INFO:');
      debugPrint('  - Frame: ${videoInfo.frameWidth}x${videoInfo.frameHeight}');
      debugPrint('  - Rotation Tag: ${videoInfo.rotationTag}°');
      debugPrint('  - Display Matrix: ${videoInfo.displayMatrix}°');
      debugPrint('  - Display: ${videoInfo.displayWidth}x${videoInfo.displayHeight}');

      final overlayResult = await _renderOverlayWithCache(
        displayWidth: videoInfo.displayWidth,
        displayHeight: videoInfo.displayHeight,
        settings: settings,
        entry: entry,
      );
      
      if (overlayResult == null) {
        debugPrint('⚠️ Gagal membuat overlay PNG, fallback drawtext...');
        final fallbackResult = await _addWatermarkWithDrawtext(
          inputPath: inputPath,
          outputPath: outputPath,
          entry: entry,
          settings: settings,
          keepAudio: keepAudio,
          videoInfo: videoInfo,
          useHardwareEncoder: useHardwareEncoder,
          onProgress: onProgress,
          onStatus: onStatus,
          sessionId: sessionId,
        );
        if (fallbackResult != null) return fallbackResult;
        throw Exception('Gagal membuat watermark');
      }
      
      overlayPath = overlayResult.$1;
      offsetX = overlayResult.$2;
      offsetY = overlayResult.$3;
      
      if (overlayPath == null) throw Exception('Overlay path null');
      
      // FIX 5 & 6: Validasi overlay tanpa membaca seluruh file
      final isValid = await _validateOverlayEfficient(overlayPath);
      if (!isValid) {
        await _cacheLock.synchronized(() async {
          _overlayCache.removeWhere((key, value) => value.path == overlayPath);
        });
        throw Exception('Overlay file corrupt');
      }
      
      debugPrint('🖼️ Overlay PNG siap: $overlayPath (offset: $offsetX, $offsetY)');

      // FIX 4: Deteksi hardware encoder async
      final hwAvailable = await _isHardwareEncoderAvailable();
      
      final args = _buildFFmpegArguments(
        inputPath: inputPath,
        outputPath: outputPath,
        overlayPath: overlayPath,
        offsetX: offsetX,
        offsetY: offsetY,
        settings: settings,
        keepAudio: keepAudio,
        useHardwareEncoder: useHardwareEncoder && hwAvailable,
      );
      debugPrint('🎬 FFmpeg args: ${args.join(' ')}');

      final success = await _executeEncodingAsync(
        args: args,
        sessionId: sessionId,
        duration: videoInfo.duration,
        outputPath: outputPath,
        onProgress: onProgress,
        onStatus: onStatus,
        timeoutSeconds: 300,
      );

      if (!success) {
        try {
          final outputFile = File(outputPath);
          if (await outputFile.exists()) {
            await outputFile.delete();
            debugPrint('🗑️ File output corrupt dihapus: $outputPath');
          }
        } catch (_) {}
        
        bool isCancelled = false;
        await _sessionLock.synchronized(() async {
          isCancelled = _cancelFlags[sessionId] == true;
        });
        
        if (isCancelled) {
          debugPrint('⏹️ Encoding dibatalkan');
          return null;
        }
        
        debugPrint('⚠️ Encoding gagal, coba drawtext fallback...');
        final fallbackResult = await _addWatermarkWithDrawtext(
          inputPath: inputPath,
          outputPath: outputPath,
          entry: entry,
          settings: settings,
          keepAudio: keepAudio,
          videoInfo: videoInfo,
          useHardwareEncoder: useHardwareEncoder,
          onProgress: onProgress,
          onStatus: onStatus,
          sessionId: sessionId,
        );
        if (fallbackResult != null) return fallbackResult;
        return null;
      }

      debugPrint('✅ Video watermark berhasil: $outputPath');
      return outputPath;
    } catch (e) {
      debugPrint('❌ Error video watermark: $e');
      lastError = diagnoseFailure(e.toString());
      return null;
    } finally {
      await _sessionLock.synchronized(() async {
        _cancelFlags.remove(sessionId);
        _activeSessions.remove(sessionId);
        _progressCallbacks.remove(sessionId);
      });
      
      if (_progressCallbacks.isEmpty) {
        FFmpegKitConfig.enableStatisticsCallback(null);
      }
      
      if (overlayPath != null) {
        bool inCache = false;
        await _cacheLock.synchronized(() async {
          for (final cached in _overlayCache.values) {
            if (cached.path == overlayPath) {
              inCache = true;
              break;
            }
          }
        });
        if (!inCache) {
          try { await File(overlayPath).delete(); } catch (_) {}
        }
      }
    }
  }

  // ─── EXECUTE ENCODING ASYNC ──────────────────────────────────
  static Future<bool> _executeEncodingAsync({
    required List<String> args,
    required String sessionId,
    required double duration,
    required String outputPath,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
    int timeoutSeconds = 300,
  }) async {
    final completer = Completer<bool>();
    FFmpegSession? session;
    bool isCompleted = false;
    
    Timer? timeoutTimer;
    double lastProgress = 0;
    
    try {
      session = await FFmpegKit.executeWithArgumentsAsync(
        args,
        (newSession) {
          if (kDebugMode) debugPrint('🎬 Session started: $sessionId');
          _sessionLock.synchronized(() async {
            _activeSessions[sessionId] = newSession;
          });
        },
        (statistics) {
          _sessionLock.synchronized(() async {
            if (_cancelFlags[sessionId] == true) return;
          });
          
          final callback = _progressCallbacks[sessionId];
          if (callback != null) {
            final timeMs = statistics.getTime();
            if (timeMs > 0) {
              double progress = timeMs / (duration * 1000);
              if (progress > 1.0) progress = 1.0;
              if (progress > lastProgress) {
                lastProgress = progress;
                callback(progress);
              }
            }
          }
        },
        (log) {
          // Log callback
        },
        (newSession) async {
          if (isCompleted) return;
          isCompleted = true;
          
          timeoutTimer?.cancel();
          
          final returnCode = await newSession.getReturnCode();
          await _sessionLock.synchronized(() async {
            _activeSessions.remove(sessionId);
            _progressCallbacks.remove(sessionId);
          });
          
          if (_progressCallbacks.isEmpty) {
            FFmpegKitConfig.enableStatisticsCallback(null);
          }
          
          bool isCancelled = false;
          await _sessionLock.synchronized(() async {
            isCancelled = _cancelFlags[sessionId] == true;
          });
          
          if (isCancelled) {
            debugPrint('⏹️ Encoding dibatalkan');
            completer.complete(false);
            return;
          }
          
          if (ReturnCode.isSuccess(returnCode)) {
            completer.complete(true);
          } else {
            final logs = await newSession.getAllLogsAsString() ?? '';
            lastError = diagnoseFailure(logs);
            debugPrint('❌ FFmpeg error log:\n$logs');
            completer.complete(false);
          }
        }
      );
      
      if (onProgress != null && duration > 0) {
        await _sessionLock.synchronized(() async {
          _progressCallbacks[sessionId] = onProgress;
        });
      }
      
      timeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
        if (!completer.isCompleted) {
          debugPrint('⏱️ Encoding timeout setelah $timeoutSeconds detik');
          if (session != null) {
            FFmpegKit.cancel(session!);
          }
          _sessionLock.synchronized(() async {
            _activeSessions.remove(sessionId);
          });
          lastError = 'Encoding timeout';
          completer.complete(false);
        }
      });
      
      final result = await completer.future;
      timeoutTimer?.cancel();
      return result;
      
    } catch (e) {
      debugPrint('❌ Encoding error: $e');
      timeoutTimer?.cancel();
      await _sessionLock.synchronized(() async {
        _activeSessions.remove(sessionId);
        _progressCallbacks.remove(sessionId);
      });
      if (session != null) {
        try { FFmpegKit.cancel(session!); } catch (_) {}
      }
      return false;
    }
  }

  // ─── RENDER OVERLAY WITH CACHE ──────────────────────────────
  static Future<(String?, int, int)?> _renderOverlayWithCache({
    required int displayWidth,
    required int displayHeight,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    final layoutHash = _getLayoutHash(settings);
    final contentHash = _getContentHash(entry);
    final cacheKey = '${displayWidth}x${displayHeight}_${layoutHash}_$contentHash';
    
    // FIX 1: Async lock untuk cache access
    return await _cacheLock.synchronized(() async {
      // LRU
      if (_overlayCache.containsKey(cacheKey)) {
        final cached = _overlayCache.remove(cacheKey)!;
        _overlayCache[cacheKey] = cached;
        
        final file = File(cached.path);
        if (await file.exists()) {
          final size = await file.length();
          if (size > 100) {
            debugPrint('🔄 Menggunakan overlay dari cache: ${cached.path}');
            return (cached.path, cached.offsetX, cached.offsetY);
          }
        }
        _overlayCache.remove(cacheKey);
      }

      debugPrint('🎨 Membuat overlay PNG ukuran ${displayWidth}x${displayHeight}...');
      
      final overlayResult = await WatermarkRenderer.renderOverlayBoundingBox(
        maxWidth: displayWidth,
        maxHeight: displayHeight,
        settings: settings,
        entry: entry,
      );
      
      if (overlayResult == null) {
        debugPrint('❌ renderOverlayBoundingBox mengembalikan null');
        return null;
      }
      
      final overlayBytes = overlayResult.$1;
      final overlayWidth = overlayResult.$2;
      final overlayHeight = overlayResult.$3;
      
      if (overlayBytes.isEmpty || overlayWidth <= 0 || overlayHeight <= 0) {
        debugPrint('❌ Overlay invalid: ${overlayWidth}x${overlayHeight}');
        return null;
      }
      
      debugPrint('✅ Overlay PNG berhasil dibuat (${overlayBytes.length} bytes, ${overlayWidth}x${overlayHeight})');

      final cacheDir = await _getCacheDirectory();
      final fileName = 'overlay_${_randomString(16)}.png';
      final filePath = '${cacheDir.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(overlayBytes);

      final padding = (displayWidth * 0.015).round().clamp(10, 40);
      
      final (offsetX, offsetY) = _calculateOverlayPosition(
        canvasWidth: displayWidth,
        canvasHeight: displayHeight,
        overlayWidth: overlayWidth,
        overlayHeight: overlayHeight,
        position: settings.position,
        padding: padding,
      );

      _overlayCache[cacheKey] = _CachedOverlay(
        path: filePath,
        offsetX: offsetX,
        offsetY: offsetY,
        createdAt: DateTime.now(),
      );
      
      while (_overlayCache.length > _maxCacheSize) {
        final firstKey = _overlayCache.keys.first;
        final firstValue = _overlayCache[firstKey];
        if (firstValue != null) {
          try { await File(firstValue.path).delete(); } catch (_) {}
        }
        _overlayCache.remove(firstKey);
      }

      return (filePath, offsetX, offsetY);
    });
  }

  // ─── CONTENT HASH ──────────────────────────────────────────────
  static String _getLayoutHash(WatermarkSettings settings) {
    final parts = [
      settings.style.name,
      settings.companyName,
      settings.operatorName,
      settings.position.name,
      settings.fontSize,
      settings.backgroundOpacity,
      settings.fontFamily,
      settings.logoPath ?? '',
      settings.hasLogo,
    ].join('|');
    return _stableHash(parts).toRadixString(16).padLeft(16, '0');
  }

  // FIX 6: Content hash dengan timestamp penuh (jika menampilkan detik)
  static String _getContentHash(ScanEntry entry) {
    final parts = [
      // FIX 6: Gunakan timestamp penuh (dengan detik)
      entry.timestamp.millisecondsSinceEpoch ~/ 1000, // Per detik
      entry.value,
      entry.barcodeFormat ?? '',
      entry.locationName ?? '',
      entry.latitude?.toStringAsFixed(6) ?? '',
      entry.longitude?.toStringAsFixed(6) ?? '',
    ].join('|');
    return _stableHash(parts).toRadixString(16).padLeft(16, '0');
  }

  // FIX 5 & 6: Validasi overlay efisien (tanpa membaca seluruh file)
  static Future<bool> _validateOverlayEfficient(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      
      final size = await file.length();
      if (size < 100) return false;
      
      // FIX 5: Hanya baca 33 bytes (header PNG + IHDR)
      final raf = await file.open(mode: FileMode.read);
      try {
        final header = Uint8List(33);
        await raf.readInto(header);
        await raf.close();
        
        if (header.length < 33) return false;
        
        // Check PNG signature
        const signature = [137, 80, 78, 71, 13, 10, 26, 10];
        for (int i = 0; i < 8; i++) {
          if (header[i] != signature[i]) return false;
        }
        
        // Check IHDR chunk
        if (header[12] != 73 || header[13] != 72 || header[14] != 68 || header[15] != 82) {
          return false;
        }
        
        // Read width and height from IHDR
        final width = (header[16] << 24) | (header[17] << 16) | (header[18] << 8) | header[19];
        final height = (header[20] << 24) | (header[21] << 16) | (header[22] << 8) | header[23];
        
        if (width <= 0 || height <= 0) return false;
        
        return true;
      } catch (_) {
        await raf.close();
        return false;
      }
    } catch (_) {
      return false;
    }
  }

  // FIX 4: Hardware encoder detection async dengan cache
  static Future<bool> _isHardwareEncoderAvailable() async {
    if (_hwEncoderChecked) return _hwEncoderAvailable ?? false;
    
    try {
      debugPrint('🔍 Mengecek hardware encoder...');
      // Coba deteksi dengan menjalankan command sederhana
      final session = await FFmpegKit.execute('-encoders');
      final returnCode = await session.getReturnCode();
      
      if (ReturnCode.isSuccess(returnCode)) {
        final output = await session.getOutput();
        _hwEncoderAvailable = output?.contains('h264_mediacodec') ?? false;
      } else {
        _hwEncoderAvailable = false;
      }
      
      _hwEncoderChecked = true;
      debugPrint('✅ Hardware encoder ${_hwEncoderAvailable! ? 'tersedia' : 'tidak tersedia'}');
    } catch (e) {
      debugPrint('⚠️ Gagal deteksi hardware encoder: $e');
      _hwEncoderAvailable = false;
      _hwEncoderChecked = true;
    }
    
    return _hwEncoderAvailable!;
  }

  // ─── UTILITY ──────────────────────────────────────────────────
  static String _randomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return String.fromCharCodes(
      Iterable.generate(length, (_) => chars.codeUnitAt(random.nextInt(chars.length)))
    );
  }

  static int _stableHash(String input) {
    const int fnvPrime = 0x100000001b3;
    int hash = 0xcbf29ce484222325;
    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * fnvPrime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash & 0x7FFFFFFFFFFFFFFF;
  }

  static Future<Directory> _getCacheDirectory() async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/watermark_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return cacheDir;
  }

  static (int, int) _calculateOverlayPosition({
    required int canvasWidth,
    required int canvasHeight,
    required int overlayWidth,
    required int overlayHeight,
    required WatermarkPosition position,
    int padding = 20,
  }) {
    int x, y;
    switch (position) {
      case WatermarkPosition.bottomRight:
        x = canvasWidth - overlayWidth - padding;
        y = canvasHeight - overlayHeight - padding;
        break;
      case WatermarkPosition.bottomLeft:
        x = padding;
        y = canvasHeight - overlayHeight - padding;
        break;
      case WatermarkPosition.topRight:
        x = canvasWidth - overlayWidth - padding;
        y = padding;
        break;
      case WatermarkPosition.topLeft:
        x = padding;
        y = padding;
        break;
    }
    
    x = x.clamp(0, canvasWidth - overlayWidth);
    y = y.clamp(0, canvasHeight - overlayHeight);
    
    return (x, y);
  }

  // ─── GET VIDEO DISPLAY INFO ──────────────────────────────────
  static Future<_VideoDisplayInfo?> _getVideoDisplayInfo(String inputPath) async {
    try {
      final session = await FFprobeKit.getMediaInformation(inputPath)
          .timeout(const Duration(seconds: 10));
      
      final mediaInfo = session.getMediaInformation();
      if (mediaInfo == null) return null;

      final durationObj = mediaInfo.getDuration();
      final double duration = double.tryParse(durationObj?.toString() ?? '') ?? 0.0;

      int frameWidth = 0, frameHeight = 0;
      int rotationTag = 0;
      int displayMatrix = 0;

      final streams = mediaInfo.getStreams();
      for (final stream in streams) {
        final w = stream.getWidth();
        final h = stream.getHeight();
        if (w != null && h != null && w > 0 && h > 0) {
          frameWidth = w;
          frameHeight = h;
          
          rotationTag = _getRotationTag(stream);
          displayMatrix = _getDisplayMatrix(stream);
          
          debugPrint('📐 Stream: ${frameWidth}x${frameHeight}, Tag: $rotationTag°, Matrix: $displayMatrix°');
          break;
        }
      }

      if (frameWidth == 0 || frameHeight == 0) {
        debugPrint('⚠️ Tidak ada stream video valid');
        return null;
      }

      int displayWidth = frameWidth;
      int displayHeight = frameHeight;
      
      final effectiveRotation = _getEffectiveRotation(rotationTag, displayMatrix);
      
      if (effectiveRotation == 90 || effectiveRotation == 270) {
        displayWidth = frameHeight;
        displayHeight = frameWidth;
        debugPrint('🔄 Display akan dirotasi: ${frameWidth}x${frameHeight} → ${displayWidth}x${displayHeight}');
      }

      displayWidth = (displayWidth ~/ 2) * 2;
      displayHeight = (displayHeight ~/ 2) * 2;

      return _VideoDisplayInfo(
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        rotationTag: rotationTag,
        displayMatrix: displayMatrix,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        duration: duration,
      );
    } on TimeoutException {
      debugPrint('⏱️ FFprobe timeout');
      return null;
    } catch (e) {
      debugPrint('❌ FFprobe error: $e');
      return null;
    }
  }

  static int _getRotationTag(dynamic stream) {
    try {
      final tags = stream.getTags();
      if (tags != null && tags.containsKey('rotate')) {
        final rotStr = tags['rotate']?.toString() ?? '0';
        return int.tryParse(rotStr) ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  static int _getDisplayMatrix(dynamic stream) {
    try {
      final props = stream.getAllProperties() as Map?;
      final sideDataList = props?['side_data_list'];
      if (sideDataList is List) {
        for (final sd in sideDataList) {
          if (sd is Map && sd.containsKey('rotation')) {
            final raw = sd['rotation'];
            final rot = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
            if (rot != 0) {
              return -rot;
            }
          }
        }
      }
    } catch (_) {}
    return 0;
  }

  static int _getEffectiveRotation(int rotationTag, int displayMatrix) {
    if (displayMatrix != 0) {
      return _normalizeRotation(displayMatrix);
    } else if (rotationTag != 0) {
      return _normalizeRotation(rotationTag);
    }
    return 0;
  }

  static int _normalizeRotation(int rotation) {
    var r = rotation % 360;
    if (r < 0) r += 360;
    return ((r + 45) ~/ 90) * 90 % 360;
  }

  // ─── BUILD FFMPEG ARGUMENTS ──────────────────────────────────
  static List<String> _buildFFmpegArguments({
    required String inputPath,
    required String outputPath,
    required String overlayPath,
    required int offsetX,
    required int offsetY,
    required WatermarkSettings settings,
    required bool keepAudio,
    required bool useHardwareEncoder,
  }) {
    if (!File(inputPath).existsSync()) {
      throw Exception('Input file not found: $inputPath');
    }
    if (!File(overlayPath).existsSync()) {
      throw Exception('Overlay file not found: $overlayPath');
    }

    final filterComplex =
        '[0:v][1:v]overlay=$offsetX:$offsetY:format=auto:eof_action=pass,format=yuv420p[outv]';

    final List<String> filterArgs = [
      '-filter_complex', filterComplex,
      '-map', '[outv]',
    ];

    final int bitrate = settings.videoBitrateKbps;
    final int crf = settings.videoCrf;
    final String preset = settings.x264Preset;

    final List<String> encoderArgs;
    if (useHardwareEncoder) {
      encoderArgs = [
        '-c:v', 'h264_mediacodec',
        '-b:v', '${bitrate}k',
        '-maxrate', '${bitrate * 2}k',
        '-bufsize', '${bitrate * 2}k',
      ];
      debugPrint('🎬 Menggunakan hardware encoder (h264_mediacodec)');
    } else {
      encoderArgs = [
        '-c:v', 'libx264',
        '-preset', preset,
        '-crf', '$crf',
        '-maxrate', '${bitrate}k',
        '-bufsize', '${bitrate * 2}k',
        '-threads', '0',
      ];
      debugPrint('🎬 Menggunakan software encoder (libx264)');
    }

    final arguments = <String>[
      '-i', inputPath,
      '-loop', '1',
      '-i', overlayPath,
      ...filterArgs,
      ...encoderArgs,
      '-pix_fmt', 'yuv420p',
      '-metadata:s:v:0', 'rotate=0',
      '-movflags', '+faststart',
      '-shortest',
      '-y',
      outputPath,
    ];

    if (keepAudio) {
      arguments.insertAll(arguments.length - 1, ['-map', '0:a?', '-c:a', 'copy']);
    } else {
      arguments.insertAll(arguments.length - 1, ['-an']);
    }

    return arguments;
  }

  // ─── FALLBACK DRAWTEXT ──────────────────────────────────────
  static Future<String?> _addWatermarkWithDrawtext({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    required bool keepAudio,
    required _VideoDisplayInfo videoInfo,
    required bool useHardwareEncoder,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
    required String sessionId,
  }) async {
    debugPrint('📝 Menggunakan drawtext fallback...');
    onStatus?.call('Menggunakan metode alternatif...');
    
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

      final padding = (videoInfo.displayWidth * 0.015).round().clamp(10, 40);
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

      final fontSize = (settings.fontSize * (videoInfo.displayWidth / 1920)).round().clamp(12, 72);
      final opacity = settings.backgroundOpacity;
      
      String drawText =
          "drawtext=text='$text':"
          "fontcolor=white:"
          "fontsize=$fontSize:"
          "box=1:"
          "boxcolor=black@$opacity:"
          "boxborderw=5:"
          "x=$x:y=$y";

      // FIX 4: Gunakan deteksi hardware encoder
      final hwAvailable = await _isHardwareEncoderAvailable();
      String encoder;
      String encoderOpts;
      
      if (useHardwareEncoder && hwAvailable) {
        encoder = 'h264_mediacodec';
        encoderOpts = '';
      } else {
        encoder = 'libx264';
        encoderOpts = ' -preset fast -crf 23';
      }

      final command =
          "-i '$inputPath' "
          "-vf \"$drawText\" "
          "-c:a ${keepAudio ? 'copy' : 'an'} "
          "-c:v $encoder$encoderOpts "
          "-metadata:s:v:0 rotate=0 "
          "-movflags +faststart "
          "-y '$outputPath'";

      debugPrint('🎬 FFmpeg fallback command: $command');
      
      onStatus?.call('Encoding dengan drawtext...');
      
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        debugPrint('✅ Fallback drawtext berhasil: $outputPath');
        return outputPath;
      } else {
        final logs = await session.getOutput();
        debugPrint('❌ Fallback drawtext error: $logs');
        
        if (logs.contains('Unknown encoder') || logs.contains('encoder not found')) {
          debugPrint('🔄 Mencoba fallback ke mpeg4...');
          final mpeg4Command = command.replaceAll('libx264', 'mpeg4');
          final mpeg4Session = await FFmpegKit.execute(mpeg4Command);
          final mpeg4ReturnCode = await mpeg4Session.getReturnCode();
          if (ReturnCode.isSuccess(mpeg4ReturnCode)) {
            debugPrint('✅ Fallback mpeg4 berhasil');
            return outputPath;
          }
        }
        
        lastError = logs;
        return null;
      }
    } catch (e) {
      debugPrint('❌ Fallback drawtext exception: $e');
      return null;
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

  // ─── DIAGNOSIS ──────────────────────────────────────────────
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
    return 'Penyebab tidak dikenal. Cek log lengkap.';
  }
}

// ─── MODEL INTERNAL ──────────────────────────────────────────
class _VideoDisplayInfo {
  final int frameWidth;
  final int frameHeight;
  final int rotationTag;
  final int displayMatrix;
  final int displayWidth;
  final int displayHeight;
  final double duration;

  _VideoDisplayInfo({
    required this.frameWidth,
    required this.frameHeight,
    required this.rotationTag,
    required this.displayMatrix,
    required this.displayWidth,
    required this.displayHeight,
    required this.duration,
  });
}

class _CachedOverlay {
  final String path;
  final int offsetX;
  final int offsetY;
  final DateTime createdAt;

  _CachedOverlay({
    required this.path,
    required this.offsetX,
    required this.offsetY,
    required this.createdAt,
  });
}

// ─── ASYNC LOCK ──────────────────────────────────────────────────
/// Async lock untuk thread-safe operations di Dart
class _AsyncLock {
  bool _locked = false;
  final Queue<Completer<void>> _waiters = Queue();

  Future<T> synchronized<T>(Future<T> Function() action) async {
    if (_locked) {
      final completer = Completer<void>();
      _waiters.add(completer);
      await completer.future;
    }
    
    _locked = true;
    try {
      return await action();
    } finally {
      _locked = false;
      if (_waiters.isNotEmpty) {
        final completer = _waiters.removeFirst();
        completer.complete();
      }
    }
  }
}
