import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/watermark_style.dart';
import '../models/scan_entry.dart';

class VideoWatermarkService {
  static String? lastError;

  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
  }) async {
    lastError = null;
    try {
      final fontPath = await _getFontPath(settings.fontFamily);
      final escapedFontPath = _escapeFFmpegPath(fontPath);

      final lines = _buildTextLines(entry, settings);
      final layout = _StyleLayout.forStyle(settings.style, settings.position);

      final blockLineHeight = settings.fontSize + 8;
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
      final logoOverlay = await _buildLogoOverlay(settings);

      final List<String> filterArgs;
      if (logoOverlay != null) {
        final escapedLogoPath = _escapeFFmpegPath(logoOverlay);
        final logoXY = layout.logoXY();
        final buffer = StringBuffer();
        buffer.write("movie='$escapedLogoPath'[logo];");
        buffer.write("[0:v]${baseChain.join(',')}[base];");
        buffer.write("[base][logo]overlay=${logoXY.x}:${logoXY.y}:format=auto[outv]");
        filterArgs = [
          '-filter_complex', buffer.toString(),
          '-map', '[outv]',
          '-map', '0:a?',
        ];
      } else {
        filterArgs = [
          '-vf', baseChain.join(','),
        ];
      }

      // Encoder yang selalu tersedia di semua build ffmpeg_kit (termasuk
      // varian video yang dipakai di sini). libopenh264 tidak selalu ada,
      // jadi kita gunakan mpeg4 sebagai codec video yang paling kompatibel.
      final arguments = <String>[
        '-i', inputPath,
        ...filterArgs,
        '-pix_fmt', 'yuv420p',   // wajib untuk kompatibilitas galeri
        '-c:v', 'mpeg4',         // encoder video yang pasti ada
        '-b:v', '4M',            // bitrate tinggi untuk kualitas baik
        '-c:a', 'aac',
        '-b:a', '128k',
        '-movflags', '+faststart',
        '-y',
        outputPath,
      ];

      debugPrint('🎬 FFmpeg arguments: $arguments');

      final session = await FFmpegKit.executeWithArguments(arguments);
      final returnCode = await session.getReturnCode();

      debugPrint('🔢 ReturnCode = ${returnCode?.getValue()}');
      final output = await session.getOutput();
      if (output != null && output.isNotEmpty) {
        debugPrint('📤 Output: $output');
      }
      final logs = await session.getAllLogsAsString();
      debugPrint('📜 Full logs: $logs');

      if (returnCode?.isValueSuccess() == true) {
        debugPrint('✅ Video watermark berhasil: $outputPath');
        return outputPath;
      } else {
        final diagnosis = _diagnoseFailure(logs ?? '');
        debugPrint('❌ FFmpeg gagal. Diagnosis: $diagnosis');
        final fullLog = logs ?? '';
        final tail =
            fullLog.length > 1500 ? fullLog.substring(fullLog.length - 1500) : fullLog;
        lastError = 'rc=${returnCode?.getValue()} | $diagnosis\n'
            '---arguments---\n${arguments.join(' ')}\n'
            '---log tail---\n$tail';
        return null;
      }
    } catch (e) {
      debugPrint('❌ Error video watermark: $e');
      lastError = 'Exception: $e';
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────
  // Helper methods
  // ─────────────────────────────────────────────────────────

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
    final dir = await getApplicationDocumentsDirectory();
    final safeName = fontFamily.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final destFile = File('${dir.path}/ffmpeg_font_$safeName.ttf');
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
        .replaceAll("'", r"'\''")
        .replaceAll(':', r'\:');
  }

  static String _escapeFFmpegPath(String path) {
    return path
        .replaceAll("'", r"'\''")
        .replaceAll(':', r'\:');
  }

  static String _diagnoseFailure(String logs) {
    final l = logs.toLowerCase();
    if (l.contains('no such filter') && l.contains('drawtext')) {
      return 'Filter drawtext TIDAK tersedia di build ffmpeg_kit ini '
          '(varian package ffmpeg_kit yang dipakai tidak menyertakan '
          'libfreetype/libfontconfig). Solusi: pastikan pubspec.yaml '
          'memakai paket yang menyertakan freetype+fontconfig, mis. '
          'ffmpeg_kit_flutter_new_video atau ffmpeg_kit_flutter_new '
          '(full-gpl) — varian min/min-gpl TIDAK menyertakan freetype.';
    }
    if (l.contains('cannot find a valid font') ||
        l.contains('could not load font') ||
        l.contains('error loading freetype')) {
      return 'Font gagal dimuat oleh freetype (fontfile bermasalah, cek '
          'apakah font variable-weight [VariableFont] didukung, coba font '
          'statis seperti Poppins-Regular.ttf).';
    }
    if (l.contains('unknown encoder') || l.contains('encoder not found')) {
      return 'Encoder yang diminta tidak tersedia. Ganti ke mpeg4 yang '
          'pasti ada di semua build ffmpeg_kit.';
    }
    if (l.contains('invalid argument') && l.contains('drawtext')) {
      return 'Syntax filter drawtext tidak valid (kemungkinan karakter '
          'khusus di teks/path belum di-escape dengan benar).';
    }
    if (l.contains('permission denied')) {
      return 'Tidak ada izin baca/tulis ke path input/output.';
    }
    if (l.contains('moov atom not found') || l.contains('invalid data found')) {
      return 'File video input korup/tidak lengkap (kemungkinan proses '
          'perekaman terputus).';
    }
    return 'Penyebab tidak cocok pola yang dikenal — cek isi lengkap logs '
        'di atas secara manual.';
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
      final barTop = _isBottom ? 'h-${blockHeight.toInt()}' : '0';
      return '($barTop)+${padding.toInt()}+($lineIndex*${lineHeight.toInt()})';
    }
    final inset = style == WatermarkStyle.stamp ? 20 + padding : 20;
    final top = _isBottom ? 'h-${blockHeight.toInt()}-${inset.toInt()}+${padding.toInt()}'
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
