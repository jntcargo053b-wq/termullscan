// lib/services/watermark/watermark_service.dart
// VERSI PERBAIKAN – kompatibel dengan WatermarkSettings baru

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
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

/// Service untuk menambahkan watermark ke video dengan efisiensi tinggi.
class VideoWatermarkService {
  static String? lastError;
  static bool _warmedUp = false;
  static final WatermarkCache _cache = WatermarkCache();

  // Cache overlay: key -> path file PNG
  static final Map<String, String> _overlayFileCache = {};
  static const int _maxCacheSize = 50;

  // Untuk progress callback yang aman (multi-session)
  static int _sessionCounter = 0;
  static final Map<int, void Function(double)> _progressCallbacks = {};

  // ─── WARM UP ──────────────────────────────────────────────────
  static Future<void> warmUp() async {
    if (_warmedUp) return;
    try {
      _log('info', '🔥 Memanaskan FFmpeg (ringan)...');
      final session = await FFmpegKit.execute(
        '-hide_banner -f lavfi -i color -frames:v 1 -f null -',
      );
      final returnCode = await session.getReturnCode();
      if (ReturnCode.isSuccess(returnCode)) {
        _log('info', '✅ FFmpeg warm-up berhasil.');
      } else {
        _log('error', '⚠️ FFmpeg warm-up gagal (rc=${returnCode?.getValue()})');
      }
    } catch (e) {
      _log('error', '❌ FFmpeg warm-up error: $e');
    } finally {
      _warmedUp = true;
    }
  }

  // ─── PRELOAD (opsional) ──────────────────────────────────────
  static Future<void> preload(WatermarkSettings settings) async {
    await _cache.initialize(settings);
  }

  // ─── ADD WATERMARK (entry point) ────────────────────────────
  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    bool keepAudio = false, // default false = audio dimatikan
    void Function(double progress)? onProgress,
  }) async {
    lastError = null;
    String? overlayPath;
    int offsetX = 0, offsetY = 0;
    final int sessionId = _sessionCounter++;

    try {
      await _cache.initialize(settings);

      // 1. Baca informasi video
      final videoInfo = await _readVideoInfo(inputPath);
      if (videoInfo == null) {
        throw Exception('Gagal membaca metadata video');
      }

      // 2. Hitung dimensi output & scale filter (resolusi selalu original)
      final dims = _computeDimensions(videoInfo);
      _log('info', '📐 Output: ${dims.outW}x${dims.outH} | Rotasi: ${dims.rotation}°');

      // 3. Render overlay PNG (dengan cache) – menggunakan WatermarkRenderer.renderOverlayPng
      final overlayResult = await _renderOverlay(
        outW: dims.outW,
        outH: dims.outH,
        settings: settings,
        entry: entry,
      );
      if (overlayResult == null) {
        throw Exception('Gagal membuat overlay watermark PNG');
      }
      overlayPath = overlayResult.$1;
      offsetX = overlayResult.$2;
      offsetY = overlayResult.$3;
      if (overlayPath == null) {
        throw Exception('Overlay path null');
      }

      // 4. Bangun argumen FFmpeg
      final args = _buildFFmpegArguments(
        inputPath: inputPath,
        outputPath: outputPath,
        overlayPath: overlayPath,
        offsetX: offsetX,
        offsetY: offsetY,
        dims: dims,
        settings: settings,
        keepAudio: keepAudio,
        videoInfo: videoInfo,
      );

      // 5. Eksekusi encoding (dengan progress & fallback)
      final success = await _executeEncoding(
        args: args,
        sessionId: sessionId,
        duration: videoInfo.duration,
        onProgress: onProgress,
        settings: settings,
        inputPath: inputPath,
        outputPath: outputPath,
        overlayPath: overlayPath,
        keepAudio: keepAudio,
        dims: dims,
        videoInfo: videoInfo,
      );

      if (!success) {
        return null;
      }

      _log('info', '✅ Video watermark berhasil: $outputPath');
      return outputPath;
    } catch (e) {
      _log('error', '❌ Error video watermark: $e');
      lastError = diagnoseFailure(e.toString());
      return null;
    } finally {
      _progressCallbacks.remove(sessionId);
      // Hapus overlay sementara (jika tidak di-cache)
      if (overlayPath != null && !_overlayFileCache.containsValue(overlayPath)) {
        try {
          final f = File(overlayPath);
          if (await f.exists()) await f.delete();
        } catch (e) {
          _log('error', '⚠️ Gagal hapus overlay sementara: $e');
        }
      }
      if (_progressCallbacks.isEmpty) {
        FFmpegKitConfig.enableStatisticsCallback(null);
      }
    }
  }

  // ─── 1. BACA INFO VIDEO ──────────────────────────────────────
  static Future<_VideoInfo?> _readVideoInfo(String inputPath) async {
    final session = await FFprobeKit.getMediaInformation(inputPath);
    final mediaInfo = session.getMediaInformation();
    if (mediaInfo == null) return null;

    // ⚠️ PENTING: MediaInformation.getDuration() dari ffmpeg_kit_flutter_new
    // mengembalikan String? (mis. "12.345000"), BUKAN double. Cast langsung
    // `as double?` di sini SELALU melempar TypeError di setiap video (100%
    // reproducible), yang langsung tertangkap oleh try/catch di addWatermark()
    // dan membuat proses watermark video SELALU gagal sejak langkah pertama
    // (baca metadata) — sebelum overlay/FFmpeg encode sempat dijalankan sama
    // sekali. Ini akar masalah "video selalu tersimpan tanpa watermark".
    final durationObj = mediaInfo.getDuration();
    final double duration = double.tryParse(durationObj?.toString() ?? '') ?? 0.0;

    int srcW = 720, srcH = 1280, rotation = 0;
    final streams = mediaInfo.getStreams();
    for (final stream in streams) {
      final w = stream.getWidth();
      final h = stream.getHeight();
      if (w != null && h != null && w > 0 && h > 0) {
        srcW = w;
        srcH = h;
        rotation = _detectRotation(stream);
        break;
      }
    }
    return _VideoInfo(
      width: srcW,
      height: srcH,
      rotation: rotation,
      duration: duration,
    );
  }

  // ─── 2. HITUNG DIMENSI (selalu original) ──────────────────────
  static _Dimensions _computeDimensions(_VideoInfo info) {
    int outW = info.width;
    int outH = info.height;
    int rotation = info.rotation;

    if (rotation == 90 || rotation == 270) {
      final temp = outW;
      outW = outH;
      outH = temp;
    }

    // Tidak ada scaling resolusi lagi → selalu original
    String scaleFilter = '';
    if (rotation == 90) scaleFilter += 'transpose=1,';
    else if (rotation == 270) scaleFilter += 'transpose=2,';
    else if (rotation == 180) scaleFilter += 'transpose=2,transpose=2,';

    // Pertahankan resolusi asli (tanpa scaling)
    scaleFilter += 'setsar=1';

    return _Dimensions(
      outW: outW,
      outH: outH,
      rotation: rotation,
      scaleFilter: scaleFilter,
      needScale: false,
    );
  }

  // ─── 3. RENDER OVERLAY (DENGAN CACHE) ──────────────────────
  static Future<(String?, int, int)?> _renderOverlay({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    // Gunakan content-based key, bukan hashCode
    final key = _cacheKey(outW, outH, settings, entry);
    // Cek cache file
    if (_overlayFileCache.containsKey(key)) {
      final cachedPath = _overlayFileCache[key]!;
      if (await File(cachedPath).exists()) {
        _log('info', '🔄 Menggunakan overlay dari cache: $cachedPath');
        return (cachedPath, 0, 0);
      } else {
        _overlayFileCache.remove(key);
      }
    }

    // Generate overlay PNG via WatermarkRenderer
    final Uint8List? overlayBytes = await WatermarkRenderer.renderOverlayPng(
      canvasWidth: outW,
      canvasHeight: outH,
      settings: settings,
      entry: entry,
    );
    if (overlayBytes == null || overlayBytes.isEmpty) return null;

    // Simpan ke file cache
    final cacheDir = await _getCacheDirectory();
    final fileName = 'overlay_$key.png';
    final filePath = '${cacheDir.path}/$fileName';
    final file = File(filePath);
    await file.writeAsBytes(overlayBytes);

    _overlayFileCache[key] = filePath;
    if (_overlayFileCache.length > _maxCacheSize) {
      _trimCache();
    }

    _log('info', '🖼️ Overlay PNG dibuat & di-cache: $filePath (${overlayBytes.length} bytes)');
    // Offset selalu (0,0) karena overlay full-frame
    return (filePath, 0, 0);
  }

  // ─── CACHE KEY (CONTENT-BASED) ─────────────────────────────
  static String _cacheKey(int outW, int outH, WatermarkSettings settings, ScanEntry entry) {
    final parts = [
      outW,
      outH,
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
    // Gunakan hash dari gabungan string
    final hash = parts.hashCode.abs();
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static Future<Directory> _getCacheDirectory() async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/watermark_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  static void _trimCache() {
    if (_overlayFileCache.length <= _maxCacheSize) return;
    final entries = _overlayFileCache.entries.toList();
    final toRemove = entries.take(_overlayFileCache.length - _maxCacheSize);
    for (final entry in toRemove) {
      try {
        final file = File(entry.value);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
      _overlayFileCache.remove(entry.key);
    }
  }

  // ─── 4. BANGUN ARGUMEN FFMPEG ──────────────────────────────
  static List<String> _buildFFmpegArguments({
    required String inputPath,
    required String outputPath,
    required String overlayPath,
    required int offsetX,
    required int offsetY,
    required _Dimensions dims,
    required WatermarkSettings settings,
    required bool keepAudio,
    required _VideoInfo videoInfo,
  }) {
    // Filter complex dengan offset overlay
    final filterComplex =
        '[0:v]${dims.scaleFilter}[base];'
        '[base][1:v]overlay=$offsetX:$offsetY:format=auto[outv];'
        '[outv]format=yuv420p[out]';

    final List<String> filterArgs = [
      '-filter_complex', filterComplex,
      '-map', '[out]',
    ];

    final int bitrate = settings.videoBitrateKbps;
    final int crf = settings.videoCrf;
    final String preset = settings.x264Preset;
    final bool useHw = _shouldUseHardwareEncoder();

    final List<String> encoderArgs;
    if (useHw) {
      encoderArgs = [
        '-c:v', 'h264_mediacodec',
        '-b:v', '${bitrate}k',
      ];
    } else {
      encoderArgs = [
        '-c:v', 'libx264',
        '-preset', preset,
        '-crf', '$crf',
        '-maxrate', '${bitrate}k',
        '-bufsize', '${bitrate * 2}k',
        '-threads', '0',
      ];
    }

    final arguments = <String>[
      '-noautorotate',
      '-i', inputPath,
      '-loop', '1', '-i', overlayPath,
      ...filterArgs,
      ...encoderArgs,
      '-pix_fmt', 'yuv420p',
      '-shortest',
      '-movflags', '+faststart',
      '-y',
      outputPath,
    ];

    // ─── AUDIO ─────────────────────────────
    if (keepAudio) {
      arguments.insertAll(arguments.length - 1, ['-map', '0:a?', '-c:a', 'copy']);
      _log('info', '🔊 Audio akan disalin dari input');
    } else {
      arguments.insertAll(arguments.length - 1, ['-an']);
      _log('info', '🔇 Audio akan dihilangkan');
    }

    return arguments;
  }

  // ─── 5. EKSEKUSI ENCODING (DENGAN FALLBACK) ──────────────
  static Future<bool> _executeEncoding({
    required List<String> args,
    required int sessionId,
    required double duration,
    void Function(double progress)? onProgress,
    required WatermarkSettings settings,
    required String inputPath,
    required String outputPath,
    required String overlayPath,
    required bool keepAudio,
    required _Dimensions dims,
    required _VideoInfo videoInfo,
  }) async {
    // Registrasi callback progress
    if (onProgress != null && duration > 0) {
      _progressCallbacks[sessionId] = onProgress;
      FFmpegKitConfig.enableStatisticsCallback((statistics) {
        final callback = _progressCallbacks[sessionId];
        if (callback != null) {
          final timeMicros = statistics.getTime();
          if (timeMicros > 0) {
            double progress = timeMicros / (duration * 1000000);
            if (progress > 1.0) progress = 1.0;
            callback(progress);
          }
        }
      });
    }

    _log('ffmpeg', '🎬 FFmpeg arguments: ${args.join(' ')}');
    var session = await FFmpegKit.executeWithArguments(args);
    var returnCode = await session.getReturnCode();

    // Fallback hardware → software
    final useHw = _shouldUseHardwareEncoder();
    if (useHw && !ReturnCode.isSuccess(returnCode)) {
      _log('error', '⚠️ h264_mediacodec gagal (rc=${returnCode?.getValue()}), fallback ke libx264...');
      final swArgs = _buildFFmpegArguments(
        inputPath: inputPath,
        outputPath: outputPath,
        overlayPath: overlayPath,
        offsetX: 0,
        offsetY: 0,
        dims: dims,
        settings: settings,
        keepAudio: keepAudio,
        videoInfo: videoInfo,
      );
      final swIndex = swArgs.indexWhere((arg) => arg == '-c:v');
      if (swIndex != -1) {
        swArgs[swIndex + 1] = 'libx264';
        swArgs.removeRange(swIndex + 2, swIndex + 2);
        swArgs.insertAll(swIndex + 2, [
          '-preset', 'veryfast',
          '-crf', '${settings.videoCrf}',
          '-maxrate', '${settings.videoBitrateKbps}k',
          '-bufsize', '${settings.videoBitrateKbps * 2}k',
          '-threads', '0',
        ]);
      }
      session = await FFmpegKit.executeWithArguments(swArgs);
      returnCode = await session.getReturnCode();
    }

    if (_progressCallbacks.isEmpty) {
      FFmpegKitConfig.enableStatisticsCallback(null);
    }

    if (!ReturnCode.isSuccess(returnCode)) {
      final output = await session.getOutput();
      final logs = await session.getAllLogsAsString() ?? '';
      final diagnosis = diagnoseFailure(logs);
      _log('error', '❌ FFmpeg error log:\n$logs');
      _log('error', '🩺 Diagnosis: $diagnosis');
      lastError = '$diagnosis (rc=${returnCode?.getValue()})\n$output\n$logs';
      return false;
    }
    return true;
  }

  // ─── DETEKSI ROTASI ──────────────────────────────────────────
  static int _detectRotation(dynamic stream) {
    try {
      final tags = stream.getTags();
      if (tags != null && tags.containsKey('rotate')) {
        final rotStr = tags['rotate']?.toString() ?? '0';
        final tagRotation = int.tryParse(rotStr) ?? 0;
        if (tagRotation != 0) return _normalizeRotation(tagRotation);
      }
    } catch (_) {}

    try {
      final props = stream.getAllProperties() as Map?;
      final sideDataList = props?['side_data_list'];
      if (sideDataList is List) {
        for (final sd in sideDataList) {
          if (sd is Map && sd.containsKey('rotation')) {
            final raw = sd['rotation'];
            final rot = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
            // ⚠️ PENTING: side_data "displaymatrix rotation" pakai KONVENSI TANDA
            // TERBALIK dibanding tag legacy 'rotate'. Contoh nyata dari video yang
            // sama: tag rotate=90 selalu berpasangan dengan side_data rotation=-90
            // (dua-duanya menggambarkan rotasi fisik YANG SAMA, butuh transpose=1).
            // Tanpa negasi ini, rotation=-90 dinormalisasi jadi 270 → transpose=2
            // (arah terbalik) → video ke-rotate ke arah yang salah (miring 90°).
            if (rot != 0) return _normalizeRotation(-rot);
          }
        }
      }
    } catch (_) {}
    return 0;
  }

  static int _normalizeRotation(int rotation) {
    var r = rotation % 360;
    if (r < 0) r += 360;
    return (r / 90).round() * 90 % 360;
  }

  // ─── HARDWARE ENCODER AVAILABILITY ──────────────────────────
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
    } catch (_) {
      _isEmulator = false;
    }
    return _isEmulator!;
  }

  static bool _shouldUseHardwareEncoder() {
    // Sederhana: selalu false untuk stabilitas, bisa diubah nanti
    if (_hwEncoderAvailable != null) return _hwEncoderAvailable!;
    return false;
  }

  // ─── DIAGNOSIS ERROR ─────────────────────────────────────────
  static String diagnoseFailure(String logs) {
    final l = logs.toLowerCase();
    if (l.contains('overlay.png') && (l.contains('no such file') || l.contains('invalid data found'))) {
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
    if (l.contains('cannot allocate memory')) {
      return 'Memori perangkat tidak cukup untuk proses encoding. Coba turunkan resolusi atau bitrate.';
    }
    if (l.contains('broken pipe')) {
      return 'Proses encoding terputus (broken pipe). Periksa stabilitas sistem.';
    }
    if (l.contains('too many packets buffered')) {
      return 'Buffer FFmpeg penuh. Coba kurangi thread atau gunakan preset lebih lambat.';
    }
    if (l.contains('cannot init encoder')) {
      return 'Encoder gagal diinisialisasi. Coba gunakan encoder software (libx264).';
    }
    if (l.contains('error while opening encoder')) {
      return 'Gagal membuka encoder. Periksa parameter encoding (bitrate, preset, dll).';
    }
    if (l.contains('no space left on device')) {
      return 'Ruang penyimpanan tidak cukup untuk menyimpan video hasil.';
    }
    if (l.contains('connection timed out')) {
      return 'Koneksi timeout (tidak relevan untuk lokal).';
    }
    return 'Penyebab tidak dikenal. Cek log lengkap di atas.';
  }

  // ─── LOG HELPER ──────────────────────────────────────────────
  static void _log(String level, String message) {
    final prefix = level == 'error' ? '❌' : level == 'ffmpeg' ? '🎬' : 'ℹ️';
    debugPrint('$prefix $message');
  }
}

// ─── MODEL INTERNAL ──────────────────────────────────────────
class _VideoInfo {
  final int width, height, rotation;
  final double duration;
  _VideoInfo({required this.width, required this.height, required this.rotation, required this.duration});
}

class _Dimensions {
  final int outW, outH, rotation;
  final String scaleFilter;
  final bool needScale;
  _Dimensions({required this.outW, required this.outH, required this.rotation, required this.scaleFilter, required this.needScale});
}
