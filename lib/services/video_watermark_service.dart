import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../watermark/watermark_settings.dart';
import '../watermark/watermark_style.dart';
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

      final lines = _buildTextLines(entry, settings);
      final layout = _StyleLayout.forStyle(settings.style, settings.position);

      final blockLineHeight = settings.fontSize + 8;
      // ✅ Konversi eksplisit ke double
      final blockHeight = (lines.isEmpty)
          ? 0.0
          : (lines.length * blockLineHeight).toDouble() + (layout.padding * 2);

      final filterParts = <String>[];

      final bg = layout.buildBackground(
        blockHeight: blockHeight,
        opacity: settings.backgroundOpacity,
      );
      if (bg != null) filterParts.add(bg);

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.text.isEmpty) continue;
        final escapedText = _escapeFFmpegText(line.text);
        final fontSize = (settings.fontSize + line.sizeOffset).clamp(10, 64).round();
        final color = layout.textColor(line.isTitle);
        final xExpr = layout.textX();
        final yExpr = layout.textY(
          lineIndex: i,
          lineHeight: blockLineHeight,
          blockHeight: blockHeight,
        );

        filterParts.add(
          "drawtext=text='$escapedText':"
          "fontfile='$escapedFontPath':"
          "fontcolor=$color:"
          "fontsize=$fontSize:"
          "x=$xExpr:"
          "y=$yExpr:"
          "shadowcolor=black@0.6:shadowx=1:shadowy=1",
        );
      }

      final baseChain = filterParts;
      final buffer = StringBuffer();
      final logoOverlay = await _buildLogoOverlay(settings);

      if (logoOverlay != null) {
        final escapedLogoPath = _escapeFFmpegPath(logoOverlay);
        final logoXY = layout.logoXY();
        buffer.write("movie='$escapedLogoPath'[logo];");
        buffer.write("[0:v]${baseChain.join(',')}[base];");
        buffer.write("[base][logo]overlay=${logoXY.x}:${logoXY.y}:format=auto[outv]");
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
        sizeOffset: 4,
        isTitle: true,
      ));
    }
    if (entry.value.isNotEmpty) {
      lines.add(_TextLine(text: 'Barcode: ${entry.value}', sizeOffset: 0));
    }
    if (settings.operatorName.isNotEmpty) {
      lines.add(_TextLine(text: 'Operator: ${settings.operatorName}', sizeOffset: 0));
    }
    lines.add(_TextLine(
      text: 'Waktu: ${_formatTimestamp(entry.timestamp)}',
      sizeOffset: -1,
    ));
    if (entry.locationName != null && entry.locationName!.isNotEmpty) {
      lines.add(_TextLine(text: 'Lokasi: ${entry.locationName}', sizeOffset: -1));
    } else if (entry.latitude != null && entry.longitude != null) {
      lines.add(_TextLine(
        text:
            'GPS: ${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}',
        sizeOffset: -1,
      ));
    }

    return lines;
  }

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
        .replaceAll('%', '\\%')
        .replaceAll('[', '\\[')
        .replaceAll(']', '\\]');
  }

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
  final double sizeOffset;
  final bool isTitle;
  _TextLine({required this.text, required this.sizeOffset, this.isTitle = false});
}

class _XY {
  final String x;
  final String y;
  _XY(this.x, this.y);
}

class _StyleLayout {
  final WatermarkStyle style;
  final WatermarkPosition position;
  final double padding = 14;

  _StyleLayout._(this.style, this.position);

  factory _StyleLayout.forStyle(WatermarkStyle style, WatermarkPosition position) {
    return _StyleLayout._(style, position);
  }

  bool get _isBottom =>
      position == WatermarkPosition.bottomLeft || position == WatermarkPosition.bottomRight;
  bool get _isRight =>
      position == WatermarkPosition.topRight || position == WatermarkPosition.bottomRight;

  bool get _isFullWidthBanner =>
      style == WatermarkStyle.professional || style == WatermarkStyle.polaroid;

  String? buildBackground({required double blockHeight, required double opacity}) {
    if (style == WatermarkStyle.minimal) return null;

    if (_isFullWidthBanner) {
      final color = style == WatermarkStyle.polaroid ? 'white' : 'black';
      final y = _isBottom ? 'ih-${blockHeight.toInt()}' : '0';
      return "drawbox=x=0:y=$y:w=iw:h=${blockHeight.toInt()}:color=$color@${opacity.clamp(0.0, 1.0)}:t=fill";
    }

    final boxWidth = 'iw*0.42';
    final x = _isRight ? 'iw-($boxWidth)-20' : '20';
    final y = _isBottom ? 'ih-${blockHeight.toInt()}-20' : '20';
    final fill = "drawbox=x=$x:y=$y:w=$boxWidth:h=${blockHeight.toInt()}:"
        "color=black@${opacity.clamp(0.0, 1.0)}:t=fill";
    final border = "drawbox=x=$x:y=$y:w=$boxWidth:h=${blockHeight.toInt()}:color=white@0.9:t=2";
    return '$fill,$border';
  }

  String textX() {
    if (_isFullWidthBanner) return '(w-text_w)/2';
    final inset = style == WatermarkStyle.stamp ? 32 : 20;
    return _isRight ? 'w-text_w-$inset' : '$inset';
  }

  String textY({
    required int lineIndex,
    required double lineHeight,
    required double blockHeight,
  }) {
    if (_isFullWidthBanner) {
      final barTop = _isBottom ? 'ih-${blockHeight.toInt()}' : '0';
      return '($barTop)+${padding.toInt()}+($lineIndex*${lineHeight.toInt()})';
    }
    final inset = style == WatermarkStyle.stamp ? 20 + padding : 20;
    final top = _isBottom ? 'ih-${blockHeight.toInt()}-${inset.toInt()}+${padding.toInt()}'
                          : '${inset.toInt()}+${padding.toInt()}';
    return '($top)+($lineIndex*${lineHeight.toInt()})';
  }

  String textColor(bool isTitle) {
    if (style == WatermarkStyle.polaroid) return isTitle ? 'darkorange' : 'black';
    return isTitle ? 'orange' : 'white';
  }

  _XY logoXY() {
    final x = _isRight ? 'W-w-20' : '20';
    final y = _isBottom ? '20' : 'H-h-20';
    return _XY(x, y);
  }
}
