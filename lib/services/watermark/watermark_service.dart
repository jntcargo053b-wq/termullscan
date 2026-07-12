// lib/services/watermark/watermark_service.dart
// VERSI FINAL – dengan preload()
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

/// Service untuk menambahkan watermark ke video dengan orientasi yang benar.
class VideoWatermarkService {
  static String? lastError;
  static bool _warmedUp = false;
  static final WatermarkCache _cache = WatermarkCache();

  static final Map<String, String> _overlayFileCache = {};
  static const int _maxCacheSize = 50;

  static int _sessionCounter = 0;
  static final Map<int, void Function(double)> _progressCallbacks = {};

  // ─── PRELOAD (untuk main.dart) ──────────────────────────────
  static Future<void> preload(WatermarkSettings settings) async {
    await _cache.initialize(settings);
    // Tidak perlu warmUp di sini, bisa dipanggil nanti
    if (kDebugMode) debugPrint('📦 VideoWatermarkService preload selesai');
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

  // ─── ADD WATERMARK ────────────────────────────────────────────
  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    bool keepAudio = false,
    void Function(double progress)? onProgress,
  }) async {
    lastError = null;
    String? overlayPath;
    int offsetX = 0, offsetY = 0;
    final int sessionId = _sessionCounter++;

    try {
      await _cache.initialize(settings);
      await warmUp(); // pastikan FFmpeg siap

      final videoInfo = await _readVideoInfo(inputPath);
      if (videoInfo == null) {
        throw Exception('Gagal membaca metadata video');
      }
      debugPrint('📹 Input: ${videoInfo.width}x${videoInfo.height}, rotasi ${videoInfo.rotation}°');

      final dims = _computeDimensions(videoInfo);
      debugPrint('📐 Output: ${dims.outW}x${dims.outH}');

      final overlayResult = await _renderOverlay(
        outW: dims.outW,
        outH: dims.outH,
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
          onProgress: onProgress,
          sessionId: sessionId,
        );
        if (fallbackResult != null) return fallbackResult;
        throw Exception('Gagal membuat watermark');
      }
      overlayPath = overlayResult.$1;
      offsetX = overlayResult.$2;
      offsetY = overlayResult.$3;
      if (overlayPath == null) throw Exception('Overlay path null');
      debugPrint('🖼️ Overlay PNG siap: $overlayPath');

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
      debugPrint('🎬 FFmpeg args: ${args.join(' ')}');

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
        debugPrint('⚠️ Encoding gagal, coba drawtext fallback...');
        final fallbackResult = await _addWatermarkWithDrawtext(
          inputPath: inputPath,
          outputPath: outputPath,
          entry: entry,
          settings: settings,
          keepAudio: keepAudio,
          videoInfo: videoInfo,
          onProgress: onProgress,
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
      _progressCallbacks.remove(sessionId);
      if (overlayPath != null && !_overlayFileCache.containsValue(overlayPath)) {
        try { await File(overlayPath).delete(); } catch (_) {}
      }
      if (_progressCallbacks.isEmpty) {
        FFmpegKitConfig.enableStatisticsCallback(null);
      }
    }
  }

  // ─── FALLBACK DRAWTEXT ──────────────────────────────────────
  static Future<String?> _addWatermarkWithDrawtext({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    required bool keepAudio,
    required _VideoInfo videoInfo,
    void Function(double progress)? onProgress,
    required int sessionId,
  }) async {
    debugPrint('📝 Menggunakan drawtext fallback...');
    try {
      final operator = settings.operatorName.isNotEmpty ? settings.operatorName : '';
      final company = settings.companyName.isNotEmpty ? '\n${settings.companyName}' : '';
      final timestamp = entry.timestamp.toIso8601String().substring(0, 19).replaceAll('T', ' ');
      final barcode = entry.value ?? 'No Barcode';
      final location = entry.locationName ?? '';

      String text = '$operator$company\n$timestamp\n$barcode';
      if (location.isNotEmpty) text += '\n$location';
      text = text.replaceAll("'", "'\\\\''");
      text = text.replaceAll(':', '\\:');
      text = text.replaceAll('\\', '\\\\');

      final pos = settings.position;
      final padding = 20;
      String x, y;
      switch (pos) {
        case WatermarkPosition.bottomRight:
          x = '(w-tw)-$padding'; y = '(h-th)-$padding'; break;
        case WatermarkPosition.bottomLeft:
          x = '$padding'; y = '(h-th)-$padding'; break;
        case WatermarkPosition.topRight:
          x = '(w-tw)-$padding'; y = '$padding'; break;
        case WatermarkPosition.topLeft:
          x = '$padding'; y = '$padding'; break;
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

      final command =
          "-i '$inputPath' "
          "-vf \"$drawText\" "
          "-c:a ${keepAudio ? 'copy' : 'an'} "
          "-c:v libx264 -preset fast -crf 23 "
          "-y '$outputPath'";

      debugPrint('🎬 FFmpeg fallback command: $command');
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        debugPrint('✅ Fallback drawtext berhasil: $outputPath');
        return outputPath;
      } else {
        final logs = await session.getOutput();
        debugPrint('❌ Fallback drawtext error: $logs');
        lastError = logs;
        return null;
      }
    } catch (e) {
      debugPrint('❌ Fallback drawtext exception: $e');
      return null;
    }
  }

  // ─── BACA INFO VIDEO ──────────────────────────────────────────
  static Future<_VideoInfo?> _readVideoInfo(String inputPath) async {
    final session = await FFprobeKit.getMediaInformation(inputPath);
    final mediaInfo = session.getMediaInformation();
    if (mediaInfo == null) return null;

    final durationObj = mediaInfo.getDuration();
    final double duration = double.tryParse(durationObj?.toString() ?? '') ?? 0.0;

    int width = 0, height = 0;
    int rotation = 0;

    final streams = mediaInfo.getStreams();
    for (final stream in streams) {
      final w = stream.getWidth();
      final h = stream.getHeight();
      if (w != null && h != null && w > 0 && h > 0) {
        width = w;
        height = h;
        rotation = _detectRotation(stream);
        debugPrint('📐 Stream: ${width}x${height}, rotasi terdeteksi: $rotation°');
        break;
      }
    }

    if (rotation == 0 && height > width) {
      debugPrint('⚠️ Dimensi portrait tanpa metadata rotasi → asumsi 90°');
      rotation = 90;
    }

    return _VideoInfo(
      width: width,
      height: height,
      rotation: rotation,
      duration: duration,
    );
  }

  // ─── DETEKSI ROTASI ──────────────────────────────────────────
  static int _detectRotation(dynamic stream) {
    int rotation = 0;

    try {
      final tags = stream.getTags();
      if (tags != null && tags.containsKey('rotate')) {
        final rotStr = tags['rotate']?.toString() ?? '0';
        final tagRotation = int.tryParse(rotStr) ?? 0;
        if (tagRotation != 0) {
          rotation = _normalizeRotation(tagRotation);
          debugPrint('🔄 Rotasi dari tag: $rotation°');
          return rotation;
        }
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
            if (rot != 0) {
              // PENTING: side_data (Display Matrix) pakai konvensi tanda
              // terbalik dari tag 'rotate' legacy. av_display_rotation_get()
              // mengembalikan sudut CCW; harus dinegasikan untuk mendapat
              // "derajat CW yang dibutuhkan" (konvensi yang sama dipakai
              // FFmpeg CLI sendiri di auto-rotate filter: theta = -av_display_rotation_get(...)).
              int finalRot = _normalizeRotation(-rot);
              debugPrint('🔄 Rotasi dari side_data: ${rot} → normalisasi: $finalRot°');
              return finalRot;
            }
          }
        }
      }
    } catch (_) {}

    return 0;
  }

  static int _normalizeRotation(int rotation) {
    var r = rotation % 360;
    if (r < 0) r += 360;
    return ((r + 45) ~/ 90) * 90 % 360;
  }

  // ─── HITUNG DIMENSI OUTPUT ──────────────────────────────────
  static _Dimensions _computeDimensions(_VideoInfo info) {
    int outW = info.width;
    int outH = info.height;
    final rot = info.rotation;
    if (rot == 90 || rot == 270) {
      final temp = outW;
      outW = outH;
      outH = temp;
      debugPrint('🔄 Swap dimensi karena rotasi $rot°: ${outW}x${outH}');
    }
    outW = (outW ~/ 2) * 2;
    outH = (outH ~/ 2) * 2;

    return _Dimensions(
      outW: outW,
      outH: outH,
      rotation: info.rotation,
      needScale: false,
    );
  }

  // ─── RENDER OVERLAY ─────────────────────────────────────────
  static Future<(String?, int, int)?> _renderOverlay({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    final key = _cacheKey(outW, outH, settings, entry);
    if (_overlayFileCache.containsKey(key)) {
      final cachedPath = _overlayFileCache[key]!;
      if (await File(cachedPath).exists()) {
        debugPrint('🔄 Menggunakan overlay dari cache: $cachedPath');
        return (cachedPath, 0, 0);
      } else {
        _overlayFileCache.remove(key);
      }
    }

    debugPrint('🎨 Membuat overlay PNG ukuran ${outW}x${outH}...');
    final Uint8List? overlayBytes = await WatermarkRenderer.renderOverlayPng(
      canvasWidth: outW,
      canvasHeight: outH,
      settings: settings,
      entry: entry,
    );
    if (overlayBytes == null || overlayBytes.isEmpty) {
      debugPrint('❌ renderOverlayPng mengembalikan null atau kosong');
      return null;
    }
    debugPrint('✅ Overlay PNG berhasil dibuat (${overlayBytes.length} bytes)');

    final cacheDir = await _getCacheDirectory();
    final fileName = 'overlay_$key.png';
    final filePath = '${cacheDir.path}/$fileName';
    final file = File(filePath);
    await file.writeAsBytes(overlayBytes);

    _overlayFileCache[key] = filePath;
    if (_overlayFileCache.length > _maxCacheSize) _trimCache();

    return (filePath, 0, 0);
  }

  static String _cacheKey(int outW, int outH, WatermarkSettings settings, ScanEntry entry) {
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
    final hash = parts.hashCode.abs();
    return hash.toRadixString(16).padLeft(16, '0');
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

  // ─── BANGUN ARGUMEN FFMPEG ──────────────────────────────────
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
    String videoFilter = '';
    final rot = dims.rotation;

    // rot merepresentasikan "derajat searah jarum jam (CW) yang dibutuhkan
    // agar tampil benar" (konvensi sama dgn tag 'rotate' & FFmpeg auto-rotate).
    // transpose=1 = 90° CW, transpose=2 = 90° CCW.
    if (rot == 90) {
      videoFilter += 'transpose=1,';
      debugPrint('🔄 Mapping rotasi 90° → transpose=1 (CW)');
    } else if (rot == 270) {
      videoFilter += 'transpose=2,';
      debugPrint('🔄 Mapping rotasi 270° → transpose=2 (CCW)');
    } else if (rot == 180) {
      videoFilter += 'transpose=2,transpose=2,';
      debugPrint('🔄 Mapping rotasi 180° → transpose=2,transpose=2');
    } else {
      debugPrint('🔄 Tidak ada rotasi (0°)');
    }

    videoFilter += 'setsar=1';

    final filterComplex =
        '[0:v]$videoFilter,format=yuv420p[base];'
        '[base][1:v]overlay=0:0:format=auto[outv]';

    final List<String> filterArgs = [
      '-filter_complex', filterComplex,
      '-map', '[outv]',
    ];

    final int bitrate = settings.videoBitrateKbps;
    final int crf = settings.videoCrf;
    final String preset = settings.x264Preset;
    final bool useHw = _shouldUseHardwareEncoder();

    final List<String> encoderArgs;
    if (useHw) {
      encoderArgs = ['-c:v', 'h264_mediacodec', '-b:v', '${bitrate}k'];
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
      '-loop', '1',
      '-i', overlayPath,
      ...filterArgs,
      ...encoderArgs,
      '-pix_fmt', 'yuv420p',
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

  // ─── EKSEKUSI ENCODING ──────────────────────────────────────
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

    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();

    if (_progressCallbacks.isEmpty) {
      FFmpegKitConfig.enableStatisticsCallback(null);
    }

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString() ?? '';
      lastError = diagnoseFailure(logs);
      debugPrint('❌ FFmpeg error log:\n$logs');
      return false;
    }
    return true;
  }

  // ─── HARDWARE ENCODER ────────────────────────────────────────
  static bool? _hwEncoderAvailable;
  static bool _shouldUseHardwareEncoder() => false;

  // ─── DIAGNOSIS ──────────────────────────────────────────────
  static String diagnoseFailure(String logs) {
    final l = logs.toLowerCase();
    if (l.contains('overlay.png') && (l.contains('no such file') || l.contains('invalid data found'))) {
      return 'Overlay PNG watermark gagal dibuat/dibaca.';
    }
    if (l.contains('unknown encoder') || l.contains('encoder not found')) {
      return 'Encoder tidak tersedia. Ganti ke mpeg4.';
    }
    if (l.contains('invalid argument') && l.contains('overlay')) {
      return 'Argumen filter overlay tidak valid.';
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
    return 'Penyebab tidak dikenal. Cek log lengkap.';
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
  final bool needScale;
  _Dimensions({required this.outW, required this.outH, required this.rotation, required this.needScale});
}
