import 'dart:io';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../watermark/watermark_settings.dart';
import '../models/scan_entry.dart';

class VideoWatermarkService {
  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
  }) async {
    try {
      final fontPath = await _getFontPath(settings.fontFamily);
      final escapedFontPath = _escapeFFmpegPath(fontPath);
      final logoOverlay = await _buildLogoOverlay(settings);

      final lines = _buildTextLines(entry, settings);

      final filterParts = <String>[];
      double yOffset = 0.85;
      for (final line in lines) {
        if (line.text.isEmpty) continue;

        final escapedText = _escapeFFmpegText(line.text);
        final drawtext = "drawtext=text='$escapedText':"
            "fontfile='$escapedFontPath':"
            "fontcolor=${line.color}:"
            "fontsize=${line.size}:"
            "x=(w-text_w)/2:"
            "y=(h*$yOffset):"
            "shadowcolor=black@0.6:shadowx=2:shadowy=2";
        filterParts.add(drawtext);
        yOffset += 0.05;
      }

      final bgFilter = "drawbox=x=0:y=h*0.82:w=iw:h=h*0.18:"
          "color=black@0.45:t=fill";

      // Build a proper labeled filtergraph (required for -filter_complex,
      // since label-based pads like [0:v] are not valid inside -vf).
      final baseChain = <String>[bgFilter, ...filterParts];
      final buffer = StringBuffer();

      if (logoOverlay != null) {
        final escapedLogoPath = _escapeFFmpegPath(logoOverlay);
        buffer.write("movie='$escapedLogoPath'[logo];");
        buffer.write("[0:v]${baseChain.join(',')}[base];");
        buffer.write("[base][logo]overlay=W-w-20:20:format=auto[outv]");
      } else {
        buffer.write("[0:v]${baseChain.join(',')}[outv]");
      }

      final filterComplex = buffer.toString();

      final command = "-i '$inputPath' "
          "-filter_complex \"$filterComplex\" "
          "-map \"[outv]\" "
          "-map 0:a? "
          "-c:a copy "
          "-y "
          "'$outputPath'";

      debugPrint('🎬 FFmpeg command: $command');

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (returnCode?.isValueSuccess() == true) {
        debugPrint('✅ Video watermark berhasil: $outputPath');
        return outputPath;
      } else {
        final logs = await session.getAllLogsAsString();
        debugPrint('❌ FFmpeg gagal. Logs: $logs');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Error video watermark: $e');
      return null;
    }
  }

  static List<_TextLine> _buildTextLines(
      ScanEntry entry, WatermarkSettings settings) {
    final lines = <_TextLine>[];

    if (settings.companyName.isNotEmpty) {
      lines.add(_TextLine(
        text: settings.companyName.toUpperCase(),
        size: 18,
        color: 'orange',
      ));
    }
    if (entry.value.isNotEmpty) {
      lines.add(_TextLine(
        text: 'Barcode: ${entry.value}',
        size: 14,
        color: 'white',
      ));
    }
    if (settings.operatorName.isNotEmpty) {
      lines.add(_TextLine(
        text: 'Operator: ${settings.operatorName}',
        size: 14,
        color: 'white',
      ));
    }
    lines.add(_TextLine(
      text: 'Waktu: ${_formatTimestamp(entry.timestamp)}',
      size: 13,
      color: 'white',
    ));
    if (entry.locationName != null && entry.locationName!.isNotEmpty) {
      lines.add(_TextLine(
        text: 'Lokasi: ${entry.locationName}',
        size: 13,
        color: 'white',
      ));
    } else if (entry.latitude != null && entry.longitude != null) {
      lines.add(_TextLine(
        text: 'GPS: ${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}',
        size: 13,
        color: 'white',
      ));
    }

    return lines;
  }

  /// Copies the bundled font asset to a real filesystem path so FFmpeg can
  /// read it (FFmpeg cannot read Flutter's asset bundle directly). Cached
  /// per font family so switching fonts doesn't reuse a stale file.
  static Future<String> _getFontPath(String fontFamily) async {
    final assetPath = _assetFontPath(fontFamily);
    final tempDir = Directory.systemTemp;
    final safeName = fontFamily.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final destFile = File('${tempDir.path}/ffmpeg_font_$safeName.ttf');
    if (!await destFile.exists()) {
      final fontData = await rootBundle.load(assetPath);
      await destFile.writeAsBytes(
        fontData.buffer.asUint8List(fontData.offsetInBytes, fontData.lengthInBytes),
      );
    }
    return destFile.path;
  }

  static String _assetFontPath(String fontFamily) {
    switch (fontFamily) {
      case 'Roboto':
        return 'assets/fonts/Roboto-VariableFont_wdth,wght.ttf';
      case 'Inter':
        return 'assets/fonts/Inter-VariableFont_opsz,wght.ttf';
      case 'Montserrat':
        return 'assets/fonts/Montserrat-VariableFont_wght.ttf';
      case 'Poppins':
        return 'assets/fonts/Poppins-Regular.ttf';
      default:
        return 'assets/fonts/Roboto-VariableFont_wdth,wght.ttf';
    }
  }

  static Future<String?> _buildLogoOverlay(WatermarkSettings settings) async {
    if (!settings.hasLogo || settings.logoPath == null) return null;
    final logoFile = File(settings.logoPath!);
    if (!await logoFile.exists()) return null;
    return logoFile.path;
  }

  static String _escapeFFmpegText(String text) {
    return text
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll(':', '\\:')
        .replaceAll('%', '\\%');
  }

  /// Escapes a filesystem path for use inside an FFmpeg filter option
  /// (e.g. fontfile=, movie=), where ':' and '\' are special characters.
  static String _escapeFFmpegPath(String path) {
    return path
        .replaceAll('\\', '\\\\')
        .replaceAll(':', '\\:');
  }

  static String _formatTimestamp(DateTime dt) {
    return '${dt.day.toString().padLeft(2,'0')}-'
        '${dt.month.toString().padLeft(2,'0')}-'
        '${dt.year} '
        '${dt.hour.toString().padLeft(2,'0')}:'
        '${dt.minute.toString().padLeft(2,'0')}:'
        '${dt.second.toString().padLeft(2,'0')}';
  }
}

class _TextLine {
  final String text;
  final int size;
  final String color;
  _TextLine({required this.text, required this.size, required this.color});
}
