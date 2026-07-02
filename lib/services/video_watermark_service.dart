import 'dart:io';
import 'dart:math' as math;
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

      final List<String> filterParts;
      final _XY logoXY;

      if (settings.style == WatermarkStyle.timestamp) {
        filterParts = _buildTimestampFilterChain(
          entry: entry,
          settings: settings,
          escapedFontPath: escapedFontPath,
        );
        // Logo ditaruh di pojok kanan-bawah bar, konsisten dgn versi foto.
        logoXY = _XY('W-w-22', 'H-h-22');
      } else {
        final lines = _buildTextLines(entry, settings);
        final layout = _StyleLayout.forStyle(settings.style, settings.position);

        final blockLineHeight = settings.fontSize + 8;
        final blockHeight = (lines.isEmpty)
            ? 0.0
            : (lines.length * blockLineHeight).toDouble() + (layout.padding * 2);

        final parts = <String>[];

        // 1. Background panel
        final bg = layout.buildBackground(
          blockHeight: blockHeight,
          opacity: settings.backgroundOpacity,
        );
        if (bg != null) parts.add(bg);

        // 2. Accent bar (garis vertikal berwarna)
        final accentBar = layout.buildAccentBar(blockHeight: blockHeight);
        if (accentBar != null) parts.add(accentBar);

        // 3. Divider horizontal (garis pemisah)
        final divider = layout.buildDivider(blockHeight: blockHeight);
        if (divider != null) parts.add(divider);

        // 4. Teks dengan shadow lebih kuat
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

          parts.add(
            "drawtext=text='$escapedText':"
            "fontfile='$escapedFontPath':"
            "fontcolor=$color:"
            "fontsize=$fontSize:"
            "x=$xExpr:"
            "y=$yExpr:"
            "shadowcolor=black@0.8:"
            "shadowx=2:"
            "shadowy=2:"
            "bordercolor=black@0.3:"
            "borderw=1",
          );
        }
        filterParts = parts;
        logoXY = layout.logoXY();
      }

      final baseChain = filterParts;
      final logoOverlay = await _buildLogoOverlay(settings);

      final List<String> filterArgs;
      if (logoOverlay != null) {
        final escapedLogoPath = _escapeFFmpegPath(logoOverlay);
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

      final arguments = <String>[
        '-i', inputPath,
        ...filterArgs,
        '-pix_fmt', 'yuv420p',
        '-c:v', 'mpeg4',
        '-b:v', '4M',
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
        final tail = fullLog.length > 1500 ? fullLog.substring(fullLog.length - 1500) : fullLog;
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

  /// Filter chain khusus style `timestamp` (jam besar + divider + tanggal/hari
  /// + alamat + brand pojok kanan-atas), meniru layout foto `TimestampLayout`.
  ///
  /// CATATAN KETERBATASAN: versi foto punya teks kode verifikasi vertikal
  /// (rotate 90°) di tepi kanan. FFmpeg `drawtext` TIDAK punya opsi rotasi
  /// bawaan — rotasi teks butuh render ke layer terpisah lalu filter `rotate`,
  /// yang belum tentu tersedia di build `ffmpeg_kit_flutter_new_video` (varian
  /// GPL minimal yang dipakai proyek ini, mengingat riwayat error "No such
  /// filter" sebelumnya). Daripada berisiko bikin build FFmpeg gagal lagi,
  /// kode verifikasi untuk video ditampilkan mendatar di pojok kanan bawah,
  /// bukan vertikal.
  static List<String> _buildTimestampFilterChain({
    required ScanEntry entry,
    required WatermarkSettings settings,
    required String escapedFontPath,
  }) {
    const padding = 22;
    const accentColor = 'yellow'; // dekat dengan amber 0xFFFFC107 di palet ffmpeg

    final timeFontSize = (settings.fontSize * 2.9).round().clamp(28, 90);
    final dateFontSize = (settings.fontSize * 0.95).round().clamp(12, 30);
    final dayFontSize = (settings.fontSize * 0.8).round().clamp(10, 26);
    final addressFontSize = settings.fontSize.round().clamp(10, 28);
    final metaFontSize = (settings.fontSize * 0.85).round().clamp(10, 26);
    final brandFontSize = (settings.fontSize * 1.15).round().clamp(12, 32);
    final taglineFontSize = (settings.fontSize * 0.7).round().clamp(9, 20);
    final codeFontSize = (settings.fontSize * 0.65).round().clamp(9, 18);

    final metaLines = <String>[];
    if (entry.value.isNotEmpty) metaLines.add('📦 ${entry.value}');
    if (settings.operatorName.isNotEmpty) metaLines.add('👤 ${settings.operatorName}');

    final addressText = (entry.locationName != null && entry.locationName!.isNotEmpty)
        ? entry.locationName!
        : (entry.latitude != null && entry.longitude != null)
            ? '${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}'
            : 'Lokasi tidak tersedia';
    final addressLines = _wrapAddress(addressText, maxLineLen: 42);

    final metaBlockH = metaLines.isEmpty ? 0 : metaLines.length * (metaFontSize + 8);
    final timeRowH = math.max(timeFontSize, dateFontSize + 4 + dayFontSize) + 10;
    final addressBlockH = addressLines.length * (addressFontSize + 8);
    final barHeight = padding * 2 + metaBlockH + timeRowH + addressBlockH;

    final parts = <String>[];

    // 1. Bar bawah solid (bukan gradient — FFmpeg drawbox tidak punya gradient).
    parts.add(
      "drawbox=x=0:y=ih-$barHeight:w=iw:h=$barHeight:"
      "color=black@${settings.backgroundOpacity.clamp(0.4, 1.0)}:t=fill",
    );

    int cursorTop = padding; // offset dari atas bar

    // 2. Baris meta (barcode / operator), opsional.
    for (final meta in metaLines) {
      parts.add(
        "drawtext=text='${_escapeFFmpegText(meta)}':"
        "fontfile='$escapedFontPath':fontcolor=white@0.9:fontsize=$metaFontSize:"
        "x=$padding:y=ih-$barHeight+$cursorTop:"
        "shadowcolor=black@0.8:shadowx=1:shadowy=1",
      );
      cursorTop += metaFontSize + 8;
    }

    // 3. Jam besar (kiri).
    final timeRowTop = cursorTop;
    parts.add(
      "drawtext=text='${_escapeFFmpegText(_hhmmFF(entry.timestamp))}':"
      "fontfile='$escapedFontPath':fontcolor=white:fontsize=$timeFontSize:"
      "x=$padding:y=ih-$barHeight+$timeRowTop:"
      "shadowcolor=black@0.85:shadowx=2:shadowy=2",
    );

    // 4. Divider vertikal kuning, di sebelah kanan jam.
    // Estimasi lebar teks "HH:mm" ≈ 2.6× font size (aman untuk font default).
    final dividerX = padding + (timeFontSize * 2.6).round();
    parts.add(
      "drawbox=x=$dividerX:y=ih-$barHeight+$timeRowTop:w=4:h=$timeFontSize:"
      "color=$accentColor@0.95:t=fill",
    );

    // 5. Tanggal + nama hari, di sebelah kanan divider.
    final dateColX = dividerX + 16;
    parts.add(
      "drawtext=text='${_ddmmyyyyFF(entry.timestamp)}':"
      "fontfile='$escapedFontPath':fontcolor=white:fontsize=$dateFontSize:"
      "x=$dateColX:y=ih-$barHeight+$timeRowTop:"
      "shadowcolor=black@0.8:shadowx=1:shadowy=1",
    );
    parts.add(
      "drawtext=text='${_dayNameFF(entry.timestamp)}':"
      "fontfile='$escapedFontPath':fontcolor=white@0.8:fontsize=$dayFontSize:"
      "x=$dateColX:y=ih-$barHeight+$timeRowTop+${dateFontSize + 4}:"
      "shadowcolor=black@0.8:shadowx=1:shadowy=1",
    );

    cursorTop = timeRowTop + timeRowH;

    // 6. Alamat (maks 2 baris).
    for (final line in addressLines) {
      parts.add(
        "drawtext=text='${_escapeFFmpegText(line)}':"
        "fontfile='$escapedFontPath':fontcolor=white:fontsize=$addressFontSize:"
        "x=$padding:y=ih-$barHeight+$cursorTop:"
        "shadowcolor=black@0.8:shadowx=1:shadowy=1",
      );
      cursorTop += addressFontSize + 8;
    }

    // 7. Badge brand pojok kanan-atas (di atas foto, bukan di dalam bar).
    final brandText = settings.companyName.isNotEmpty ? settings.companyName : 'TermulScan';
    parts.add(
      "drawtext=text='${_escapeFFmpegText(brandText)}':"
      "fontfile='$escapedFontPath':fontcolor=$accentColor:fontsize=$brandFontSize:"
      "x=w-text_w-$padding:y=$padding:"
      "shadowcolor=black@0.8:shadowx=2:shadowy=2",
    );
    parts.add(
      "drawtext=text='Foto Terverifikasi GPS':"
      "fontfile='$escapedFontPath':fontcolor=white@0.9:fontsize=$taglineFontSize:"
      "x=w-text_w-$padding:y=${padding + brandFontSize + 4}:"
      "shadowcolor=black@0.8:shadowx=1:shadowy=1",
    );

    // 8. Kode verifikasi — mendatar di pojok kanan-bawah bar (lihat catatan
    //    keterbatasan rotasi di atas).
    final code = _generateVerificationCode(entry, settings);
    parts.add(
      "drawtext=text='$code  •  TERMULSCAN VERIFIED':"
      "fontfile='$escapedFontPath':fontcolor=white@0.75:fontsize=$codeFontSize:"
      "x=w-text_w-$padding:y=ih-$barHeight-${codeFontSize + 10}:"
      "shadowcolor=black@0.7:shadowx=1:shadowy=1",
    );

    return parts;
  }

  static List<String> _wrapAddress(String text, {int maxLineLen = 42}) {
    if (text.length <= maxLineLen) return [text];
    final words = text.split(' ');
    final line1 = StringBuffer();
    final line2 = StringBuffer();
    for (final w in words) {
      if ((line1.length + w.length + 1) <= maxLineLen) {
        if (line1.isNotEmpty) line1.write(' ');
        line1.write(w);
      } else {
        if (line2.isNotEmpty) line2.write(' ');
        line2.write(w);
      }
    }
    var second = line2.toString();
    if (second.length > maxLineLen) {
      second = '${second.substring(0, maxLineLen - 1)}…';
    }
    return second.isEmpty ? [line1.toString()] : [line1.toString(), second];
  }

  static String _generateVerificationCode(ScanEntry entry, WatermarkSettings settings) {
    final seed = '${entry.timestamp.millisecondsSinceEpoch}'
        '${settings.operatorName}${entry.value}';
    final hash = seed.codeUnits.fold<int>(0, (p, c) => (p * 31 + c) & 0x7FFFFFFF);
    final code = hash.toRadixString(36).toUpperCase();
    return code.padLeft(10, 'X').substring(0, 10);
  }

  static String _hhmmFF(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  static String _ddmmyyyyFF(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  static const List<String> _hariIndoFF = [
    'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu',
  ];
  static String _dayNameFF(DateTime dt) => _hariIndoFF[dt.weekday - 1];

  static List<_TextLine> _buildTextLines(
      ScanEntry entry, WatermarkSettings settings) {
    final lines = <_TextLine>[];

    if (settings.companyName.isNotEmpty) {
      lines.add(_TextLine(
        text: settings.companyName.toUpperCase(),
        sizeOffset: 6,
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
        text: 'GPS: ${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}',
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
      return 'Filter drawtext TIDAK tersedia. Pastikan pubspec.yaml memakai '
          'ffmpeg_kit_flutter_new_video atau varian yang menyertakan freetype.';
    }
    if (l.contains('cannot find a valid font') ||
        l.contains('could not load font') ||
        l.contains('error loading freetype')) {
      return 'Font gagal dimuat. Coba font statis (mis. Poppins-Regular.ttf).';
    }
    if (l.contains('unknown encoder') || l.contains('encoder not found')) {
      return 'Encoder tidak tersedia. Ganti ke mpeg4.';
    }
    if (l.contains('invalid argument') && l.contains('drawtext')) {
      return 'Syntax filter drawtext tidak valid (karakter khusus belum di-escape).';
    }
    if (l.contains('permission denied')) {
      return 'Tidak ada izin baca/tulis ke file video.';
    }
    if (l.contains('moov atom not found') || l.contains('invalid data found')) {
      return 'File video input korup/tidak lengkap.';
    }
    return 'Penyebab tidak dikenal. Cek log lengkap di atas.';
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

// ─── Helper classes ──────────────────────────────
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

    // stamp: bordered badge
    final boxWidth = 'iw*0.45';
    final x = _isRight ? 'iw-($boxWidth)-20' : '20';
    final y = _isBottom ? 'ih-${blockHeight.toInt()}-20' : '20';
    final fill = "drawbox=x=$x:y=$y:w=$boxWidth:h=${blockHeight.toInt()}:"
        "color=black@${opacity.clamp(0.0, 1.0)}:t=fill";
    final border = "drawbox=x=$x:y=$y:w=$boxWidth:h=${blockHeight.toInt()}:color=white@0.9:t=2";
    return '$fill,$border';
  }

  // ✅ Accent bar: garis vertikal berwarna di samping teks
  String? buildAccentBar({required double blockHeight}) {
    if (style == WatermarkStyle.minimal) return null;

    final barWidth = 4;
    final accentColor = style == WatermarkStyle.polaroid ? 'darkorange' : 'orange';
    final x = _isRight ? 'iw-$barWidth-18' : '18';
    final y = _isBottom ? 'ih-${blockHeight.toInt()}' : '0';
    return "drawbox=x=$x:y=$y:w=$barWidth:h=${blockHeight.toInt()}:color=$accentColor@0.9:t=fill";
  }

  // ✅ Divider horizontal: garis tipis di atas teks
  String? buildDivider({required double blockHeight}) {
    if (style == WatermarkStyle.minimal || style == WatermarkStyle.stamp) return null;

    final y = _isBottom ? 'ih-${blockHeight.toInt()}' : '0';
    return "drawbox=x=18:y=$y:w=iw-36:h=1:color=white@0.2:t=fill";
  }

  String textX() {
    // Sisakan ruang untuk accent bar
    final accentSpace = (style == WatermarkStyle.minimal) ? 0 : 12;
    if (_isFullWidthBanner) return '(w-text_w)/2';
    final inset = style == WatermarkStyle.stamp ? 32 : 20;
    return _isRight ? 'w-text_w-$inset' : '${inset + accentSpace}';
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
