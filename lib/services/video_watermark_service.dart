import 'dart:io';
import 'dart:math' as math;
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/watermark_style.dart';
import '../models/scan_entry.dart';

// ─────────────────────────────────────────────────────────────
//  1.  Kelas pembantu untuk menyimpan template
// ─────────────────────────────────────────────────────────────

class _FilterTemplate {
  final String placeholder;
  final String template; // string filter dengan placeholder

  _FilterTemplate(this.placeholder, this.template);

  String render(String value) => template.replaceFirst(placeholder, _escapeFFmpegText(value));
}

class _PrecomputedStyle {
  final List<_FilterTemplate> filterTemplates; // semua filter teks (dengan placeholder)
  final _XY logoXY;
  final double blockHeight;
  final double blockLineHeight;
  final List<String> staticFilters; // filter non-teks (background, accent, divider)

  _PrecomputedStyle({
    required this.filterTemplates,
    required this.logoXY,
    required this.blockHeight,
    required this.blockLineHeight,
    required this.staticFilters,
  });

  /// Menghasilkan daftar filter lengkap dengan mengganti placeholder menggunakan data dinamis.
  List<String> buildFilters(List<String> dynamicTexts) {
    final result = <String>[];
    result.addAll(staticFilters);
    for (var i = 0; i < dynamicTexts.length && i < filterTemplates.length; i++) {
      if (dynamicTexts[i].isEmpty) continue;
      result.add(filterTemplates[i].render(dynamicTexts[i]));
    }
    return result;
  }
}

class _PrecomputedTimestamp {
  final List<_FilterTemplate> dynamicFilters; // filter yang mengandung placeholder dinamis
  final List<String> staticFilters;          // filter tanpa placeholder (background, brand, tagline, dll)
  final _XY logoXY;
  final double barHeight;

  _PrecomputedTimestamp({
    required this.dynamicFilters,
    required this.staticFilters,
    required this.logoXY,
    required this.barHeight,
  });

  /// Menghasilkan daftar filter dengan data dinamis.
  /// `dynamicData` berisi: [time, date, day, addr0, addr1, meta0, meta1, code]
  List<String> buildFilters(List<String> dynamicData) {
    final result = <String>[];
    result.addAll(staticFilters);
    for (var i = 0; i < dynamicData.length && i < dynamicFilters.length; i++) {
      if (dynamicData[i].isEmpty) continue;
      result.add(dynamicFilters[i].render(dynamicData[i]));
    }
    return result;
  }
}

// ─────────────────────────────────────────────────────────────
//  2.  Cache watermark (singleton)
// ─────────────────────────────────────────────────────────────

class _WatermarkCache {
  static final _WatermarkCache _instance = _WatermarkCache._internal();
  factory _WatermarkCache() => _instance;
  _WatermarkCache._internal();

  bool _initialized = false;
  WatermarkSettings? _settings;
  String? _cachedFontPath;
  String? _cachedLogoPath;
  Map<WatermarkStyle, _PrecomputedStyle>? _styleCache;
  _PrecomputedTimestamp? _timestampCache;

  /// Inisialisasi cache jika `settings` berbeda dari yang terakhir.
  Future<void> initialize(WatermarkSettings settings) async {
    if (_initialized && _settings == settings) return;
    _settings = settings;

    // 1. Font
    _cachedFontPath = await _getFontPath(settings.fontFamily);

    // 2. Logo
    if (settings.hasLogo && settings.logoPath != null) {
      final logo = File(settings.logoPath!);
      if (await logo.exists()) _cachedLogoPath = logo.path;
    } else {
      _cachedLogoPath = null;
    }

    // 3. Prekomputasi untuk semua gaya
    _styleCache = {};
    for (var style in WatermarkStyle.values) {
      if (style == WatermarkStyle.timestamp) {
        _timestampCache = _precomputeTimestamp(settings);
      } else {
        _styleCache![style] = _precomputeGeneral(settings, style);
      }
    }

    _initialized = true;
  }

  // ─── Prekomputasi untuk gaya umum (professional, polaroid, stamp, minimal) ───

  _PrecomputedStyle _precomputeGeneral(WatermarkSettings settings, WatermarkStyle style) {
    final layout = _StyleLayout.forStyle(style, settings.position);
    final lines = _buildStaticTextLines(settings); // label statis (tanpa nilai)
    final blockLineHeight = settings.fontSize + 8;
    final blockHeight = lines.isEmpty
        ? 0.0
        : (lines.length * blockLineHeight) + (layout.padding * 2);

    final staticParts = <String>[];

    // Background
    final bg = layout.buildBackground(
      blockHeight: blockHeight,
      opacity: settings.backgroundOpacity,
    );
    if (bg != null) staticParts.add(bg);

    // Accent bar
    final accent = layout.buildAccentBar(blockHeight: blockHeight);
    if (accent != null) staticParts.add(accent);

    // Divider
    final divider = layout.buildDivider(blockHeight: blockHeight);
    if (divider != null) staticParts.add(divider);

    // Filter teks dengan placeholder
    final templates = <_FilterTemplate>[];
    final escapedFontPath = _escapeFFmpegPath(_cachedFontPath!);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final fontSize = (settings.fontSize + line.sizeOffset).clamp(10, 64).round();
      final color = layout.textColor(line.isTitle);
      final x = layout.textX();
      final y = layout.textY(
        lineIndex: i,
        lineHeight: blockLineHeight,
        blockHeight: blockHeight,
      );
      final placeholder = '{{line$i}}';
      final filter =
          "drawtext=text='$placeholder':"
          "fontfile='$escapedFontPath':"
          "fontcolor=$color:"
          "fontsize=$fontSize:"
          "x=$x:"
          "y=$y:"
          "shadowcolor=black@0.8:"
          "shadowx=2:"
          "shadowy=2:"
          "bordercolor=black@0.3:"
          "borderw=1";
      templates.add(_FilterTemplate(placeholder, filter));
    }

    final logoXY = layout.logoXY();
    return _PrecomputedStyle(
      filterTemplates: templates,
      logoXY: logoXY,
      blockHeight: blockHeight,
      blockLineHeight: blockLineHeight,
      staticFilters: staticParts,
    );
  }

  // ─── Prekomputasi untuk gaya timestamp ────────────────────

  _PrecomputedTimestamp _precomputeTimestamp(WatermarkSettings settings) {
    const padding = 22;
    const accentColor = 'yellow';

    final timeFontSize = (settings.fontSize * 2.9).round().clamp(28, 90);
    final dateFontSize = (settings.fontSize * 0.95).round().clamp(12, 30);
    final dayFontSize = (settings.fontSize * 0.8).round().clamp(10, 26);
    final addressFontSize = settings.fontSize.round().clamp(10, 28);
    final metaFontSize = (settings.fontSize * 0.85).round().clamp(10, 26);
    final brandFontSize = (settings.fontSize * 1.15).round().clamp(12, 32);
    final taglineFontSize = (settings.fontSize * 0.7).round().clamp(9, 20);
    final codeFontSize = (settings.fontSize * 0.65).round().clamp(9, 18);

    // Asumsikan maksimal 2 baris meta, 2 baris alamat (kita siapkan placeholder)
    // Kita akan tetap hitung barHeight berdasarkan data statis (hanya brand, tagline, dan struktur)
    // Tapi karena kita tidak tahu panjang alamat/meta, kita pakai perkiraan maksimal 2 baris.
    // Untuk perhitungan posisi, kita butuh barHeight. Kita asumsikan 2 baris meta dan 2 baris alamat.
    const maxMetaLines = 2;
    const maxAddressLines = 2;
    final metaBlockH = maxMetaLines * (metaFontSize + 8);
    final timeRowH = math.max(timeFontSize, dateFontSize + 4 + dayFontSize) + 10;
    final addressBlockH = maxAddressLines * (addressFontSize + 8);
    final barHeight = padding * 2 + metaBlockH + timeRowH + addressBlockH;

    final escapedFontPath = _escapeFFmpegPath(_cachedFontPath!);
    final staticParts = <String>[];

    // 1. Background bar
    staticParts.add(
      "drawbox=x=0:y=ih-$barHeight:w=iw:h=$barHeight:"
      "color=black@${settings.backgroundOpacity.clamp(0.4, 1.0)}:t=fill",
    );

    // 2. Brand badge (pojok kanan atas)
    final brandText = settings.companyName.isNotEmpty ? settings.companyName : 'TermulScan';
    staticParts.add(
      "drawtext=text='${_escapeFFmpegText(brandText)}':"
      "fontfile='$escapedFontPath':fontcolor=$accentColor:fontsize=$brandFontSize:"
      "x=w-text_w-$padding:y=$padding:"
      "shadowcolor=black@0.8:shadowx=2:shadowy=2",
    );
    staticParts.add(
      "drawtext=text='Foto Terverifikasi GPS':"
      "fontfile='$escapedFontPath':fontcolor=white@0.9:fontsize=$taglineFontSize:"
      "x=w-text_w-$padding:y=${padding + brandFontSize + 4}:"
      "shadowcolor=black@0.8:shadowx=1:shadowy=1",
    );

    // 3. Kode verifikasi (bawah kanan) – statis template dengan placeholder {{code}}
    final codePlaceholder = '{{code}}';
    staticParts.add(
      "drawtext=text='$codePlaceholder  •  TERMULSCAN VERIFIED':"
      "fontfile='$escapedFontPath':fontcolor=white@0.75:fontsize=$codeFontSize:"
      "x=w-text_w-$padding:y=ih-$barHeight-${codeFontSize + 10}:"
      "shadowcolor=black@0.7:shadowx=1:shadowy=1",
    );

    // ─── Filter dinamis ──────────────────────────────────────

    final dynamicTemplates = <_FilterTemplate>[];

    // Meta baris (maks 2)
    for (var i = 0; i < maxMetaLines; i++) {
      final placeholder = '{{meta$i}}';
      final yPos = padding + i * (metaFontSize + 8);
      final filter =
          "drawtext=text='$placeholder':"
          "fontfile='$escapedFontPath':fontcolor=white@0.9:fontsize=$metaFontSize:"
          "x=$padding:y=ih-$barHeight+$yPos:"
          "shadowcolor=black@0.8:shadowx=1:shadowy=1";
      dynamicTemplates.add(_FilterTemplate(placeholder, filter));
    }

    // Jam besar
    final timeRowTop = (maxMetaLines > 0) ? padding + maxMetaLines * (metaFontSize + 8) : padding;
    dynamicTemplates.add(
      _FilterTemplate(
        '{{time}}',
        "drawtext=text='{{time}}':"
        "fontfile='$escapedFontPath':fontcolor=white:fontsize=$timeFontSize:"
        "x=$padding:y=ih-$barHeight+$timeRowTop:"
        "shadowcolor=black@0.85:shadowx=2:shadowy=2",
      ),
    );

    // Divider vertikal (statis posisi tergantung timeFontSize)
    final dividerX = padding + (timeFontSize * 2.6).round();
    staticParts.add(
      "drawbox=x=$dividerX:y=ih-$barHeight+$timeRowTop:w=4:h=$timeFontSize:"
      "color=$accentColor@0.95:t=fill",
    );

    // Tanggal + hari
    final dateColX = dividerX + 16;
    dynamicTemplates.add(
      _FilterTemplate(
        '{{date}}',
        "drawtext=text='{{date}}':"
        "fontfile='$escapedFontPath':fontcolor=white:fontsize=$dateFontSize:"
        "x=$dateColX:y=ih-$barHeight+$timeRowTop:"
        "shadowcolor=black@0.8:shadowx=1:shadowy=1",
      ),
    );
    dynamicTemplates.add(
      _FilterTemplate(
        '{{day}}',
        "drawtext=text='{{day}}':"
        "fontfile='$escapedFontPath':fontcolor=white@0.8:fontsize=$dayFontSize:"
        "x=$dateColX:y=ih-$barHeight+$timeRowTop+${dateFontSize + 4}:"
        "shadowcolor=black@0.8:shadowx=1:shadowy=1",
      ),
    );

    // Alamat (2 baris)
    final addressStartY = timeRowTop + timeRowH;
    for (var i = 0; i < maxAddressLines; i++) {
      final placeholder = '{{addr$i}}';
      final yPos = addressStartY + i * (addressFontSize + 8);
      final filter =
          "drawtext=text='$placeholder':"
          "fontfile='$escapedFontPath':fontcolor=white:fontsize=$addressFontSize:"
          "x=$padding:y=ih-$barHeight+$yPos:"
          "shadowcolor=black@0.8:shadowx=1:shadowy=1";
      dynamicTemplates.add(_FilterTemplate(placeholder, filter));
    }

    // Logo posisi
    final logoXY = _XY('W-w-22', 'H-h-22');

    return _PrecomputedTimestamp(
      dynamicFilters: dynamicTemplates,
      staticFilters: staticParts,
      logoXY: logoXY,
      barHeight: barHeight,
    );
  }

  // ─── Pembantu untuk mendapatkan data dinamis ─────────────

  /// Untuk gaya umum: mengembalikan daftar teks dinamis (nilai barcode, operator, waktu, lokasi)
  List<String> getDynamicTexts(ScanEntry entry, WatermarkSettings settings) {
    final lines = <String>[];
    if (entry.value.isNotEmpty) lines.add(entry.value);
    if (settings.operatorName.isNotEmpty) lines.add(settings.operatorName);
    lines.add(_formatTimestamp(entry.timestamp));
    if (entry.locationName != null && entry.locationName!.isNotEmpty) {
      lines.add(entry.locationName!);
    } else if (entry.latitude != null && entry.longitude != null) {
      lines.add('${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}');
    } else {
      lines.add('Lokasi tidak tersedia');
    }
    return lines;
  }

  /// Untuk gaya timestamp: mengembalikan list [time, date, day, addr0, addr1, meta0, meta1, code]
  List<String> getTimestampDynamicData(ScanEntry entry, WatermarkSettings settings) {
    final metaLines = <String>[];
    if (entry.value.isNotEmpty) metaLines.add('📦 ${entry.value}');
    if (settings.operatorName.isNotEmpty) metaLines.add('👤 ${settings.operatorName}');

    final addressText = (entry.locationName != null && entry.locationName!.isNotEmpty)
        ? entry.locationName!
        : (entry.latitude != null && entry.longitude != null)
            ? '${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}'
            : 'Lokasi tidak tersedia';
    final addressLines = _wrapAddress(addressText, maxLineLen: 42);

    final data = <String>[
      _hhmmFF(entry.timestamp),
      _ddmmyyyyFF(entry.timestamp),
      _dayNameFF(entry.timestamp),
      addressLines.isNotEmpty ? addressLines[0] : '',
      addressLines.length > 1 ? addressLines[1] : '',
      metaLines.isNotEmpty ? metaLines[0] : '',
      metaLines.length > 1 ? metaLines[1] : '',
      _generateVerificationCode(entry, settings),
    ];
    return data;
  }

  // ─── Metode akses cache ─────────────────────────────────

  _PrecomputedStyle getStyle(WatermarkStyle style) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');
    if (style == WatermarkStyle.timestamp) {
      throw ArgumentError('Gunakan getTimestamp() untuk gaya timestamp');
    }
    return _styleCache![style]!;
  }

  _PrecomputedTimestamp getTimestamp() {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');
    return _timestampCache!;
  }

  String? get logoPath => _cachedLogoPath;

  // ─── Metode utilitas internal (diambil dari kode asli) ──

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

  static String _escapeFFmpegText(String text) {
    return text.replaceAll("'", r"'\''").replaceAll(':', r'\:');
  }

  static String _escapeFFmpegPath(String path) {
    return path.replaceAll("'", r"'\''").replaceAll(':', r'\:');
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

  static String _formatTimestamp(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  // Untuk membangun label statis (tanpa nilai) pada gaya umum
  static List<_TextLine> _buildStaticTextLines(WatermarkSettings settings) {
    final lines = <_TextLine>[];
    if (settings.companyName.isNotEmpty) {
      lines.add(_TextLine(
        text: settings.companyName.toUpperCase(),
        sizeOffset: 6,
        isTitle: true,
      ));
    }
    // Label statis (placeholder akan diganti dengan nilai dinamis)
    lines.add(_TextLine(text: 'Barcode: {{line0}}', sizeOffset: 0));
    lines.add(_TextLine(text: 'Operator: {{line1}}', sizeOffset: 0));
    lines.add(_TextLine(text: 'Waktu: {{line2}}', sizeOffset: -1));
    lines.add(_TextLine(text: 'Lokasi: {{line3}}', sizeOffset: -1));
    return lines;
  }
}

// ─────────────────────────────────────────────────────────────
//  3.  VideoWatermarkService yang dimodifikasi
// ─────────────────────────────────────────────────────────────

class VideoWatermarkService {
  static String? lastError;

  static final _WatermarkCache _cache = _WatermarkCache();

  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
  }) async {
    lastError = null;
    try {
      // 1. Inisialisasi cache (jika perlu)
      await _cache.initialize(settings);

      // 2. Bangun filter chain berdasarkan gaya
      final List<String> filterParts;
      final _XY logoXY;

      if (settings.style == WatermarkStyle.timestamp) {
        final precomputed = _cache.getTimestamp();
        final dynamicData = _cache.getTimestampDynamicData(entry, settings);
        filterParts = precomputed.buildFilters(dynamicData);
        logoXY = precomputed.logoXY;
      } else {
        final precomputed = _cache.getStyle(settings.style);
        final dynamicTexts = _cache.getDynamicTexts(entry, settings);
        filterParts = precomputed.buildFilters(dynamicTexts);
        logoXY = precomputed.logoXY;
      }

      // 3. Logo overlay
      final logoPath = _cache.logoPath;
      final List<String> filterArgs;
      if (logoPath != null) {
        final escapedLogoPath = _escapeFFmpegPath(logoPath);
        final buffer = StringBuffer();
        buffer.write("movie='$escapedLogoPath'[logo];");
        buffer.write("[0:v]${filterParts.join(',')}[base];");
        buffer.write("[base][logo]overlay=${logoXY.x}:${logoXY.y}:format=auto[outv]");
        filterArgs = [
          '-filter_complex', buffer.toString(),
          '-map', '[outv]',
          '-map', '0:a?',
        ];
      } else {
        filterArgs = [
          '-vf', filterParts.join(','),
        ];
      }

      // 4. Argumen FFmpeg
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

      // 5. Eksekusi
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

  // ─── Metode pembantu (tetap statis) ──────────────────────

  static String _escapeFFmpegText(String text) {
    return text.replaceAll("'", r"'\''").replaceAll(':', r'\:');
  }

  static String _escapeFFmpegPath(String path) {
    return path.replaceAll("'", r"'\''").replaceAll(':', r'\:');
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
}

// ─── Helper classes (sama seperti sebelumnya) ──────────────

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

    final boxWidth = 'iw*0.45';
    final x = _isRight ? 'iw-($boxWidth)-20' : '20';
    final y = _isBottom ? 'ih-${blockHeight.toInt()}-20' : '20';
    final fill = "drawbox=x=$x:y=$y:w=$boxWidth:h=${blockHeight.toInt()}:"
        "color=black@${opacity.clamp(0.0, 1.0)}:t=fill";
    final border = "drawbox=x=$x:y=$y:w=$boxWidth:h=${blockHeight.toInt()}:color=white@0.9:t=2";
    return '$fill,$border';
  }

  String? buildAccentBar({required double blockHeight}) {
    if (style == WatermarkStyle.minimal) return null;

    final barWidth = 4;
    final accentColor = style == WatermarkStyle.polaroid ? 'darkorange' : 'orange';
    final x = _isRight ? 'iw-$barWidth-18' : '18';
    final y = _isBottom ? 'ih-${blockHeight.toInt()}' : '0';
    return "drawbox=x=$x:y=$y:w=$barWidth:h=${blockHeight.toInt()}:color=$accentColor@0.9:t=fill";
  }

  String? buildDivider({required double blockHeight}) {
    if (style == WatermarkStyle.minimal || style == WatermarkStyle.stamp) return null;

    final y = _isBottom ? 'ih-${blockHeight.toInt()}' : '0';
    return "drawbox=x=18:y=$y:w=iw-36:h=1:color=white@0.2:t=fill";
  }

  String textX() {
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
    final top = _isBottom
        ? 'h-${blockHeight.toInt()}-${inset.toInt()}+${padding.toInt()}'
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
