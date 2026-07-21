// lib/watermark/video_watermark_renderer.dart
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../models/scan_entry.dart';
import 'watermark_settings.dart';

// ─── VIDEO INFO ──────────────────────────────────────────────────
class VideoInfo {
  final int width;
  final int height;
  final double? duration;

  const VideoInfo({
    required this.width,
    required this.height,
    this.duration,
  });

  double get baseSize => math.min(width, height);
  double get aspectRatio => width / height;
  bool get isLandscape => width > height;
  bool get isPortrait => height > width;

  @override
  String toString() => 'VideoInfo(${width}x$height, duration: $duration)';
}

// ─── SCALING CONFIG ─────────────────────────────────────────────
class VideoScalingConfig {
  /// Font size sebagai persentase dari baseSize (minimum 16, maximum 72)
  final double fontSizeRatio;

  /// Logo width sebagai persentase dari lebar video
  final double logoWidthRatio;

  /// Padding sebagai persentase dari baseSize
  final double paddingRatio;

  /// Box border width sebagai persentase dari font size
  final double borderWidthRatio;

  /// Background opacity
  final double opacity;

  const VideoScalingConfig({
    this.fontSizeRatio = 0.028,   // 2.8% dari baseSize → 28px di 1080p, 56px di 4K
    this.logoWidthRatio = 0.08,   // 8% dari lebar video
    this.paddingRatio = 0.025,    // 2.5% dari baseSize
    this.borderWidthRatio = 0.18, // 18% dari font size
    this.opacity = 0.85,
  });

  // ─── PRESETS ────────────────────────────────────────────────────
  static const VideoScalingConfig minimal = VideoScalingConfig(
    fontSizeRatio: 0.020,
    logoWidthRatio: 0.06,
    paddingRatio: 0.015,
    borderWidthRatio: 0.12,
    opacity: 0.70,
  );

  static const VideoScalingConfig standard = VideoScalingConfig(
    fontSizeRatio: 0.028,
    logoWidthRatio: 0.08,
    paddingRatio: 0.025,
    borderWidthRatio: 0.18,
    opacity: 0.85,
  );

  static const VideoScalingConfig large = VideoScalingConfig(
    fontSizeRatio: 0.035,
    logoWidthRatio: 0.10,
    paddingRatio: 0.030,
    borderWidthRatio: 0.20,
    opacity: 0.90,
  );
}

// ─── VIDEO RENDERER ─────────────────────────────────────────────
class VideoWatermarkRenderer {
  static const VideoRenderConfig _defaultConfig = VideoRenderConfig();
  static const VideoScalingConfig _defaultScaling = VideoScalingConfig.standard;

  /// Render watermark ke video (MP4) menggunakan ffmpeg_kit_flutter_new
  static Future<String?> render({
    required String videoPath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
    VideoRenderConfig? config,
    VideoScalingConfig? scaling,
    void Function(double progress)? onProgress,
  }) async {
    final cfg = config ?? _defaultConfig;
    final scale = scaling ?? _defaultScaling;

    if (kDebugMode) {
      debugPrint('🎬 VIDEO WATERMARK START');
      debugPrint('  Style: ${settings.style.name}');
      debugPrint('  Preset: ${cfg.preset}, CRF: ${cfg.crf}');
    }

    try {
      // ─── VALIDASI INPUT ──────────────────────────────────────────
      final file = File(videoPath);
      if (!await file.exists()) {
        debugPrint('❌ Video tidak ditemukan: $videoPath');
        return null;
      }

      if (videoPath == outputPath) {
        debugPrint('❌ Input dan output path sama');
        return null;
      }

      final outputDir = File(outputPath).parent;
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      // ─── GET VIDEO INFO ──────────────────────────────────────────
      final videoInfo = await getVideoInfo(videoPath);
      if (videoInfo == null) {
        debugPrint('❌ Gagal mendapatkan info video, fallback ke default');
        // Fallback: asumsikan 1080p
        return _renderWithDimensions(
          videoPath: videoPath,
          outputPath: outputPath,
          settings: settings,
          entry: entry,
          config: cfg,
          scaling: scale,
          videoWidth: 1920,
          videoHeight: 1080,
          onProgress: onProgress,
        );
      }

      if (kDebugMode) {
        debugPrint('📐 Video: ${videoInfo.width}x${videoInfo.height} (${videoInfo.aspectRatio.toStringAsFixed(2)})');
      }

      // ─── RENDER DENGAN DIMENSI ──────────────────────────────────
      return await _renderWithDimensions(
        videoPath: videoPath,
        outputPath: outputPath,
        settings: settings,
        entry: entry,
        config: cfg,
        scaling: scale,
        videoWidth: videoInfo.width,
        videoHeight: videoInfo.height,
        onProgress: onProgress,
      );
    } catch (e, stack) {
      debugPrint('❌ Error processing video: $e\n$stack');
      return null;
    }
  }

  // ─── RENDER DENGAN DIMENSI ────────────────────────────────────
  static Future<String?> _renderWithDimensions({
    required String videoPath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
    required VideoRenderConfig config,
    required VideoScalingConfig scaling,
    required int videoWidth,
    required int videoHeight,
    void Function(double progress)? onProgress,
  }) async {
    final baseSize = math.min(videoWidth, videoHeight).toDouble();

    // ─── HITUNG UKURAN RESPONSIF ──────────────────────────────────
    // Font size: berdasarkan baseSize (bukan nilai absolut!)
    final fontSize = (baseSize * scaling.fontSizeRatio)
        .clamp(16.0, 72.0)
        .round();

    // Padding: berdasarkan baseSize
    final padding = (baseSize * scaling.paddingRatio)
        .clamp(8.0, 48.0)
        .round();

    // Border width: berdasarkan font size
    final borderWidth = (fontSize * scaling.borderWidthRatio)
        .clamp(2.0, 12.0)
        .round();

    // Logo width: berdasarkan lebar video
    final logoWidth = (videoWidth * scaling.logoWidthRatio)
        .clamp(60.0, 400.0)
        .round();

    // Opacity
    final opacity = scaling.opacity.clamp(0.0, 1.0);

    if (kDebugMode) {
      debugPrint('📏 Scaling: fontSize=$fontSize, padding=$padding, border=$borderWidth, logo=$logoWidth');
    }

    // ─── BUILD WATERMARK TEXT ──────────────────────────────────
    final text = _buildWatermarkText(settings, entry);
    final escapedText = _escapeDrawtext(text);

    // ─── POSISI ──────────────────────────────────────────────────
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

    final fontColor = 'white';
    final bgColor = 'black@$opacity';

    // ─── DRAW TEXT FILTER ──────────────────────────────────────
    String drawText =
        "drawtext=text='$escapedText':"
        "fontcolor=$fontColor:"
        "fontsize=$fontSize:"
        "fontfile=/system/fonts/Roboto-Regular.ttf:"
        "box=1:"
        "boxcolor=$bgColor:"
        "boxborderw=$borderWidth:"
        "x=$x:y=$y";

    // ─── LOGO ────────────────────────────────────────────────────
    String overlayFilter = '';
    bool useLogo = false;
    String? validLogoPath;

    if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
      final logoFile = File(settings.logoPath!);
      if (await logoFile.exists()) {
        useLogo = true;
        validLogoPath = settings.logoPath;
      } else {
        debugPrint('⚠️ Logo file tidak ditemukan: ${settings.logoPath}');
      }
    }

    if (useLogo && validLogoPath != null) {
      final logoX = '$padding';
      final logoY = '(h-th)-$padding';
      overlayFilter =
          "[1:v]scale=$logoWidth:-1[logo];"
          "[0:v][logo]overlay=$logoX:$logoY";
    }

    // ─── BUILD COMMAND ──────────────────────────────────────────
    String command;
    if (useLogo && validLogoPath != null) {
      command =
          "-i '$videoPath' -i '$validLogoPath' "
          "-filter_complex \"$overlayFilter, $drawText\" "
          "-c:a copy -c:v libx264 -preset ${config.preset} -crf ${config.crf} "
          "-movflags +faststart "
          "-y '$outputPath'";
    } else {
      command =
          "-i '$videoPath' "
          "-vf \"$drawText\" "
          "-c:a copy -c:v libx264 -preset ${config.preset} -crf ${config.crf} "
          "-movflags +faststart "
          "-y '$outputPath'";
    }

    if (kDebugMode) {
      final preview = command.length > 200 ? '${command.substring(0, 200)}...' : command;
      debugPrint('⚙️ FFmpeg command: $preview');
    }

    // ─── EKSEKUSI ───────────────────────────────────────────────
    final session = await FFmpegKit.execute(command, (log) {
      if (onProgress != null) {
        final progress = _parseProgress(log.getMessage());
        if (progress != null) {
          onProgress(progress);
        }
      }
    });

    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      if (kDebugMode) debugPrint('✅ Video watermark success: $outputPath');
      return outputPath;
    } else if (ReturnCode.isCancel(returnCode)) {
      debugPrint('⚠️ Video processing cancelled');
      return null;
    } else {
      final logs = await session.getOutput();
      debugPrint('❌ FFmpeg error: $logs');
      return null;
    }
  }

  // ─── GET VIDEO INFO ────────────────────────────────────────────
  static Future<VideoInfo?> getVideoInfo(String videoPath) async {
    try {
      final session = await FFmpegKit.execute(
        "-i '$videoPath' -f null -",
      );
      final output = await session.getOutput();
      if (output != null) {
        // Cari resolution: "1920x1080"
        final resRegex = RegExp(r'(\d{3,4})x(\d{3,4})');
        final resMatch = resRegex.firstMatch(output);
        if (resMatch != null) {
          final width = int.parse(resMatch.group(1)!);
          final height = int.parse(resMatch.group(2)!);

          // Cari durasi
          final durRegex = RegExp(r'Duration: (\d{2}):(\d{2}):(\d{2}\.\d{2})');
          final durMatch = durRegex.firstMatch(output);
          double? duration;
          if (durMatch != null) {
            final h = int.parse(durMatch.group(1)!);
            final m = int.parse(durMatch.group(2)!);
            final s = double.parse(durMatch.group(3)!);
            duration = h * 3600 + m * 60 + s;
          }

          return VideoInfo(
            width: width,
            height: height,
            duration: duration,
          );
        }
      }
    } catch (e) {
      debugPrint('⚠️ Gagal mendapatkan info video: $e');
    }
    return null;
  }

  // ─── BUILD WATERMARK TEXT ──────────────────────────────────────
  static String _buildWatermarkText(WatermarkSettings settings, ScanEntry entry) {
    final operator = settings.operatorName.isNotEmpty ? settings.operatorName : 'Operator';
    final company = settings.companyName;
    final timestamp = entry.timestamp.toIso8601String().substring(0, 19).replaceAll('T', ' ');
    final barcode = entry.value ?? 'No Barcode';
    final location = entry.locationName ?? '';

    switch (settings.style) {
      case WatermarkStyle.minimal:
        return '$timestamp';
      case WatermarkStyle.professional:
        return '$operator | $timestamp | $barcode';
      case WatermarkStyle.stamp:
        return 'VERIFIED\n$timestamp\n$operator';
      case WatermarkStyle.polaroid:
        return '$operator\n$timestamp';
      default:
        final lines = <String>[];
        lines.add(operator);
        if (company.isNotEmpty) lines.add(company);
        lines.add(timestamp);
        lines.add(barcode);
        if (location.isNotEmpty) lines.add(location);
        return lines.join('\n');
    }
  }

  // ─── ESCAPE ────────────────────────────────────────────────────
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

  // ─── PARSE PROGRESS ────────────────────────────────────────────
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

  // ─── CANCEL ────────────────────────────────────────────────────
  static Future<void> cancel() async {
    await FFmpegKit.cancel();
  }
}

// ─── VIDEO RENDER CONFIG ────────────────────────────────────────
class VideoRenderConfig {
  final String preset;
  final int crf;

  const VideoRenderConfig({
    this.preset = 'veryfast', // ← diubah ke veryfast untuk produksi
    this.crf = 23,
  });
}
