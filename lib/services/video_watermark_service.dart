import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/watermark_style.dart';
import '../models/scan_entry.dart';

// ─────────────────────────────────────────────────────────────
//  0.  FUNGSI UTILITAS TOP-LEVEL
// ─────────────────────────────────────────────────────────────

String _escapeFFmpegText(String text) {
  return text.replaceAll("'", r"'\''").replaceAll(':', r'\:');
}

String _escapeFFmpegPath(String path) {
  return path.replaceAll("'", r"'\''").replaceAll(':', r'\:');
}

List<String> _wrapAddress(String text, {int maxLineLen = 42}) {
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

String _generateVerificationCode(ScanEntry entry, WatermarkSettings settings) {
  final seed = '${entry.timestamp.millisecondsSinceEpoch}'
      '${settings.operatorName}${entry.value}';
  final hash = seed.codeUnits.fold<int>(0, (p, c) => (p * 31 + c) & 0x7FFFFFFF);
  final code = hash.toRadixString(36).toUpperCase();
  return code.padLeft(10, 'X').substring(0, 10);
}

String _hhmmFF(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

String _ddmmyyyyFF(DateTime dt) =>
    '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

const List<String> _hariIndoFF = [
  'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu',
];
String _dayNameFF(DateTime dt) => _hariIndoFF[dt.weekday - 1];

String _formatTimestamp(DateTime dt) {
  return '${dt.day.toString().padLeft(2, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';
}

// ─────────────────────────────────────────────────────────────
//  0b. DURASI & DIMENSI VIDEO (via FFprobe)
// ─────────────────────────────────────────────────────────────

Future<int> _probeVideoDuration(String inputPath) async {
  try {
    final session = await FFprobeKit.getMediaInformation(inputPath);
    final mediaInfo = session.getMediaInformation();
    if (mediaInfo != null) {
      final durationStr = mediaInfo.getDuration();
      if (durationStr != null && durationStr.isNotEmpty) {
        final duration = double.tryParse(durationStr);
        if (duration != null) return duration.round();
      }
    }
    return 0;
  } catch (e) {
    return 0;
  }
}

Future<_XY2> _probeVideoDimensions(String inputPath) async {
  try {
    final session = await FFprobeKit.getMediaInformation(inputPath);
    final mediaInfo = session.getMediaInformation();
    if (mediaInfo != null) {
      final streams = mediaInfo.getStreams();
      for (final stream in streams) {
        // Versi 5.0.0 tidak memiliki getCodecType(), jadi cukup cek width/height > 0
        final w = stream.getWidth();
        final h = stream.getHeight();
        if (w != null && h != null && w > 0 && h > 0) {
          return _XY2(w, h);
        }
      }
    }
  } catch (_) {}
  return _XY2(0, 0);
}

class _XY2 {
  final int width;
  final int height;
  _XY2(this.width, this.height);
}

// ─────────────────────────────────────────────────────────────
//  1.  KELAS PEMBANTU TEMPLATE FILTER
// ─────────────────────────────────────────────────────────────

class _FilterTemplate {
  final String placeholder;
  final String template;
  _FilterTemplate(this.placeholder, this.template);
  String render(String value) => template.replaceFirst(placeholder, _escapeFFmpegText(value));
}

class _PrecomputedStyle {
  final List<_FilterTemplate> filterTemplates;
  final _XY logoXY;
  final double blockHeight;
  final double blockLineHeight;
  final List<String> staticFilters;
  _PrecomputedStyle({
    required this.filterTemplates,
    required this.logoXY,
    required this.blockHeight,
    required this.blockLineHeight,
    required this.staticFilters,
  });
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
  final List<_FilterTemplate> dynamicFilters;
  final List<String> staticFilters;
  final _XY logoXY;
  final double barHeight;
  _PrecomputedTimestamp({
    required this.dynamicFilters,
    required this.staticFilters,
    required this.logoXY,
    required this.barHeight,
  });
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

class _PrecomputedFullInfo {
  final List<_FilterTemplate> dynamicFilters;
  final List<String> staticFilters;
  final _XY logoXY;
  final double barHeight;

  _PrecomputedFullInfo({
    required this.dynamicFilters,
    required this.staticFilters,
    required this.logoXY,
    required this.barHeight,
  });

  List<String> buildFilters({
    required String barcode,
    required String date,
    required String time,
    required String operator,
    required String company,
    required String gpsText,
    required String location,
    required String code,
  }) {
    final data = [
      barcode,
      date,
      time,
      operator,
      company,
      gpsText,
      location,
      code,
    ];
    final result = <String>[];
    result.addAll(staticFilters);
    for (var i = 0; i < data.length && i < dynamicFilters.length; i++) {
      if (data[i].isEmpty) continue;
      result.add(dynamicFilters[i].render(data[i]));
    }
    return result;
  }
}

// ─────────────────────────────────────────────────────────────
//  2.  CACHE WATERMARK (dengan fallback font)
// ─────────────────────────────────────────────────────────────

class _WatermarkCache {
  static final _WatermarkCache _instance = _WatermarkCache._internal();
  factory _WatermarkCache() => _instance;
  _WatermarkCache._internal();

  bool _initialized = false;
  WatermarkSettings? _settings;
  String? _cachedFontPath;
  String? _cachedLogoPath;
  ui.Image? _cachedLogoImage;

  final Map<String, _PrecomputedStyle> _styleCache = {};
  final Map<double, _PrecomputedTimestamp> _timestampCache = {};
  final Map<double, _PrecomputedFullInfo> _fullInfoCache = {};

  // Fallback font
  String get _fontSpec {
    if (_cachedFontPath != null) {
      final file = File(_cachedFontPath!);
      if (file.existsSync()) {
        return "fontfile='${_escapeFFmpegPath(_cachedFontPath!)}'";
      }
    }
    return "font='sans-serif'";
  }

  Future<void> initialize(WatermarkSettings settings) async {
    if (_initialized && _settings == settings) return;
    _settings = settings;
    try {
      _cachedFontPath = await _getFontPath(settings.fontFamily);
    } catch (e) {
      debugPrint('⚠️ Gagal memuat font $settings.fontFamily, menggunakan fallback sans-serif');
      _cachedFontPath = null;
    }
    _cachedLogoPath = null;
    _cachedLogoImage = null;
    if (settings.hasLogo && settings.logoPath != null) {
      final logoFile = File(settings.logoPath!);
      if (await logoFile.exists()) {
        _cachedLogoPath = logoFile.path;
        _cachedLogoImage = await _decodeLogo(logoFile);
      }
    }
    _styleCache.clear();
    _timestampCache.clear();
    _fullInfoCache.clear();
    _initialized = true;
  }

  static Future<ui.Image?> _decodeLogo(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, (img) => completer.complete(img));
      return await completer.future;
    } catch (e) {
      debugPrint('❌ Gagal decode logo: $e');
      return null;
    }
  }

  String? get logoPath => _cachedLogoPath;
  Future<ui.Image?> getLogoImage() async {
    if (_cachedLogoImage != null) return _cachedLogoImage;
    if (_cachedLogoPath != null) {
      final file = File(_cachedLogoPath!);
      if (await file.exists()) {
        _cachedLogoImage = await _decodeLogo(file);
        return _cachedLogoImage;
      }
    }
    return null;
  }

  // ─── Prekomputasi gaya umum ──────────────────────────────

  _PrecomputedStyle _precomputeGeneral(
    WatermarkSettings settings,
    WatermarkStyle style,
    double scale,
  ) {
    final layout = _StyleLayout.forStyle(style, settings.position, scale);
    final lines = _buildStaticTextLines(settings);
    final baseFontSize = settings.fontSize * scale;
    final blockLineHeight = baseFontSize + (8 * scale);
    final blockHeight = lines.isEmpty
        ? 0.0
        : (lines.length * blockLineHeight) + (layout.padding * 2);

    final staticParts = <String>[];
    final bg = layout.buildBackground(blockHeight: blockHeight, opacity: settings.backgroundOpacity);
    if (bg != null) staticParts.add(bg);
    final accent = layout.buildAccentBar(blockHeight: blockHeight);
    if (accent != null) staticParts.add(accent);
    final divider = layout.buildDivider(blockHeight: blockHeight);
    if (divider != null) staticParts.add(divider);

    final templates = <_FilterTemplate>[];
    final fontSpec = _fontSpec;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final fontSize = (baseFontSize + line.sizeOffset * scale)
          .clamp(10 * scale, 64 * scale)
          .round();
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
          "$fontSpec:"
          "fontcolor=$color:"
          "fontsize=$fontSize:"
          "x=$x:"
          "y=$y:"
          "shadowcolor=black@0.8:"
          "shadowx=${math.max(1, (2 * scale).round())}:"
          "shadowy=${math.max(1, (2 * scale).round())}:"
          "bordercolor=black@0.3:"
          "borderw=${math.max(1, (1 * scale).round())}";
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

  // ─── Prekomputasi timestamp ──────────────────────────────

  _PrecomputedTimestamp _precomputeTimestamp(WatermarkSettings settings, double scale) {
    final padding = (22 * scale).round();
    const accentColor = 'yellow';

    int scaled(num px, {int min = 1}) => math.max(min, (px * scale).round());

    final timeFontSize = scaled(settings.fontSize * 2.9, min: (28 * scale).round());
    final dateFontSize = scaled(settings.fontSize * 0.95, min: (12 * scale).round());
    final dayFontSize = scaled(settings.fontSize * 0.8, min: (10 * scale).round());
    final addressFontSize = scaled(settings.fontSize, min: (10 * scale).round());
    final metaFontSize = scaled(settings.fontSize * 0.85, min: (10 * scale).round());
    final brandFontSize = scaled(settings.fontSize * 1.15, min: (12 * scale).round());
    final taglineFontSize = scaled(settings.fontSize * 0.7, min: (9 * scale).round());
    final codeFontSize = scaled(settings.fontSize * 0.65, min: (9 * scale).round());

    final gap4 = scaled(4);
    final gap8 = scaled(8);
    final gap10 = scaled(10);
    final gap16 = scaled(16);
    final shadow1 = scaled(1);
    final shadow2 = scaled(2);
    final barWidth = scaled(4, min: 2);
    final logoGap = scaled(22);

    const maxMetaLines = 2;
    const maxAddressLines = 2;
    final metaBlockH = maxMetaLines * (metaFontSize + gap8);
    final timeRowH = math.max(timeFontSize, dateFontSize + gap4 + dayFontSize) + gap10;
    final addressBlockH = maxAddressLines * (addressFontSize + gap8);
    final barHeight = padding * 2 + metaBlockH + timeRowH + addressBlockH;

    final fontSpec = _fontSpec;
    final staticParts = <String>[];

    staticParts.add(
      "drawbox=x=0:y=ih-$barHeight:w=iw:h=$barHeight:"
      "color=black@${settings.backgroundOpacity.clamp(0.4, 1.0)}:t=fill",
    );

    final brandText = settings.companyName.isNotEmpty ? settings.companyName : 'TermulScan';
    staticParts.add(
      "drawtext=text='${_escapeFFmpegText(brandText)}':"
      "$fontSpec:fontcolor=$accentColor:fontsize=$brandFontSize:"
      "x=w-text_w-$padding:y=$padding:"
      "shadowcolor=black@0.8:shadowx=$shadow2:shadowy=$shadow2",
    );
    staticParts.add(
      "drawtext=text='Foto Terverifikasi GPS':"
      "$fontSpec:fontcolor=white@0.9:fontsize=$taglineFontSize:"
      "x=w-text_w-$padding:y=${padding + brandFontSize + gap4}:"
      "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
    );

    staticParts.add(
      "drawtext=text='{{code}}  •  TERMULSCAN VERIFIED':"
      "$fontSpec:fontcolor=white@0.75:fontsize=$codeFontSize:"
      "x=w-text_w-$padding:y=ih-$barHeight-${codeFontSize + gap10}:"
      "shadowcolor=black@0.7:shadowx=$shadow1:shadowy=$shadow1",
    );

    final dynamicTemplates = <_FilterTemplate>[];

    for (var i = 0; i < maxMetaLines; i++) {
      final placeholder = '{{meta$i}}';
      final yPos = padding + i * (metaFontSize + gap8);
      final filter =
          "drawtext=text='$placeholder':"
          "$fontSpec:fontcolor=white@0.9:fontsize=$metaFontSize:"
          "x=$padding:y=ih-$barHeight+$yPos:"
          "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1";
      dynamicTemplates.add(_FilterTemplate(placeholder, filter));
    }

    final timeRowTop = (maxMetaLines > 0) ? padding + maxMetaLines * (metaFontSize + gap8) : padding;
    dynamicTemplates.add(
      _FilterTemplate(
        '{{time}}',
        "drawtext=text='{{time}}':"
        "$fontSpec:fontcolor=white:fontsize=$timeFontSize:"
        "x=$padding:y=ih-$barHeight+$timeRowTop:"
        "shadowcolor=black@0.85:shadowx=$shadow2:shadowy=$shadow2",
      ),
    );

    final dividerX = padding + (timeFontSize * 2.6).round();
    staticParts.add(
      "drawbox=x=$dividerX:y=ih-$barHeight+$timeRowTop:w=$barWidth:h=$timeFontSize:"
      "color=$accentColor@0.95:t=fill",
    );

    final dateColX = dividerX + gap16;
    dynamicTemplates.add(
      _FilterTemplate(
        '{{date}}',
        "drawtext=text='{{date}}':"
        "$fontSpec:fontcolor=white:fontsize=$dateFontSize:"
        "x=$dateColX:y=ih-$barHeight+$timeRowTop:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    dynamicTemplates.add(
      _FilterTemplate(
        '{{day}}',
        "drawtext=text='{{day}}':"
        "$fontSpec:fontcolor=white@0.8:fontsize=$dayFontSize:"
        "x=$dateColX:y=ih-$barHeight+$timeRowTop+${dateFontSize + gap4}:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );

    final addressStartY = timeRowTop + timeRowH;
    for (var i = 0; i < maxAddressLines; i++) {
      final placeholder = '{{addr$i}}';
      final yPos = addressStartY + i * (addressFontSize + gap8);
      final filter =
          "drawtext=text='$placeholder':"
          "$fontSpec:fontcolor=white:fontsize=$addressFontSize:"
          "x=$padding:y=ih-$barHeight+$yPos:"
          "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1";
      dynamicTemplates.add(_FilterTemplate(placeholder, filter));
    }

    final logoXY = _XY('W-w-$logoGap', 'H-h-$logoGap');

    return _PrecomputedTimestamp(
      dynamicFilters: dynamicTemplates,
      staticFilters: staticParts,
      logoXY: logoXY,
      barHeight: barHeight.toDouble(),
    );
  }

  // ─── PREKOMPUTASI FULL INFO ─────────────────────────────

  _PrecomputedFullInfo _precomputeFullInfo(WatermarkSettings settings, double scale) {
    final padding = (20 * scale).round();
    const accentColor = 'orange';

    int scaled(num px, {int min = 1}) => math.max(min, (px * scale).round());

    final barcodeSize = scaled(settings.fontSize * 2.2, min: (32 * scale).round());
    final dateSize = scaled(settings.fontSize * 1.2, min: (18 * scale).round());
    final timeSize = scaled(settings.fontSize * 1.2, min: (18 * scale).round());
    final operatorSize = scaled(settings.fontSize * 0.9, min: (14 * scale).round());
    final companySize = scaled(settings.fontSize * 0.9, min: (14 * scale).round());
    final gpsSize = scaled(settings.fontSize * 0.8, min: (12 * scale).round());
    final locationSize = scaled(settings.fontSize * 0.8, min: (12 * scale).round());
    final codeSize = scaled(settings.fontSize * 0.65, min: (10 * scale).round());

    final gap4 = scaled(4);
    final gap6 = scaled(6);
    final gap8 = scaled(8);
    final gap10 = scaled(10);
    final gap12 = scaled(12);
    final gap16 = scaled(16);
    final shadow1 = scaled(1);
    final shadow2 = scaled(2);
    final logoGap = scaled(20);

    final row1 = barcodeSize;
    final row2 = math.max(dateSize, timeSize) + gap4;
    final row3 = math.max(operatorSize, companySize) + gap4;
    final row4 = gpsSize + gap4;
    final row5 = locationSize + gap4;
    final row6 = codeSize + gap10;

    final totalRows = (row1 + row2 + row3 + row4 + row5 + row6).toInt();
    final barHeight = padding * 2 + totalRows;

    final fontSpec = _fontSpec;
    final staticParts = <String>[];

    staticParts.add(
      "drawbox=x=0:y=ih-$barHeight:w=iw:h=$barHeight:"
      "color=black@${settings.backgroundOpacity.clamp(0.4, 1.0)}:t=fill",
    );

    staticParts.add(
      "drawbox=x=$padding:y=ih-$barHeight:w=iw-${padding*2}:h=1:color=white@0.15:t=fill",
    );

    final dynamicTemplates = <_FilterTemplate>[];

    int cursorY = padding;

    dynamicTemplates.add(
      _FilterTemplate(
        '{{barcode}}',
        "drawtext=text='{{barcode}}':"
        "$fontSpec:fontcolor=white:fontsize=$barcodeSize:"
        "x=$padding:y=ih-$barHeight+$cursorY:"
        "shadowcolor=black@0.85:shadowx=$shadow2:shadowy=$shadow2",
      ),
    );
    cursorY += barcodeSize + gap6;

    final dateTimeText = "{{date}}  {{time}} WIB";
    dynamicTemplates.add(
      _FilterTemplate(
        '{{datetime}}',
        "drawtext=text='$dateTimeText':"
        "$fontSpec:fontcolor=white@0.95:fontsize=$dateSize:"
        "x=$padding:y=ih-$barHeight+$cursorY:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    cursorY += dateSize + gap8;

    final opText = "{{operator}}  •  {{company}}";
    dynamicTemplates.add(
      _FilterTemplate(
        '{{operator_company}}',
        "drawtext=text='$opText':"
        "$fontSpec:fontcolor=white@0.9:fontsize=$operatorSize:"
        "x=$padding:y=ih-$barHeight+$cursorY:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    cursorY += operatorSize + gap8;

    if (settings.showGps) {
      dynamicTemplates.add(
        _FilterTemplate(
          '{{gps}}',
          "drawtext=text='📍 {{gps}}':"
          "$fontSpec:fontcolor=white@0.85:fontsize=$gpsSize:"
          "x=$padding:y=ih-$barHeight+$cursorY:"
          "shadowcolor=black@0.7:shadowx=$shadow1:shadowy=$shadow1",
        ),
      );
      cursorY += gpsSize + gap4;
    }

    if (settings.showLocation) {
      dynamicTemplates.add(
        _FilterTemplate(
          '{{location}}',
          "drawtext=text='🏷️ {{location}}':"
          "$fontSpec:fontcolor=white@0.8:fontsize=$locationSize:"
          "x=$padding:y=ih-$barHeight+$cursorY:"
          "shadowcolor=black@0.7:shadowx=$shadow1:shadowy=$shadow1",
        ),
      );
      cursorY += locationSize + gap4;
    }

    staticParts.add(
      "drawtext=text='{{code}}  •  TERMULSCAN VERIFIED':"
      "$fontSpec:fontcolor=white@0.7:fontsize=$codeSize:"
      "x=w-text_w-$padding:y=ih-$barHeight-${codeSize + gap10}:"
      "shadowcolor=black@0.6:shadowx=$shadow1:shadowy=$shadow1",
    );

    final logoXY = _XY('W-w-$logoGap', 'H-h-$logoGap');

    return _PrecomputedFullInfo(
      dynamicFilters: dynamicTemplates,
      staticFilters: staticParts,
      logoXY: logoXY,
      barHeight: barHeight.toDouble(),
    );
  }

  // ─── Data dinamis ─────────────────────────────────────────

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

    return [
      _hhmmFF(entry.timestamp),
      _ddmmyyyyFF(entry.timestamp),
      _dayNameFF(entry.timestamp),
      addressLines.isNotEmpty ? addressLines[0] : '',
      addressLines.length > 1 ? addressLines[1] : '',
      metaLines.isNotEmpty ? metaLines[0] : '',
      metaLines.length > 1 ? metaLines[1] : '',
      _generateVerificationCode(entry, settings),
    ];
  }

  List<String> getFullInfoData(ScanEntry entry, WatermarkSettings settings) {
    final dateStr = _ddmmyyyyFF(entry.timestamp);
    final timeStr = _hhmmFF(entry.timestamp);
    final gpsText = (entry.latitude != null && entry.longitude != null)
        ? '${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}'
        : 'GPS tidak tersedia';
    final location = entry.locationName ?? '';
    final code = _generateVerificationCode(entry, settings);
    return [
      entry.value,
      dateStr,
      timeStr,
      settings.operatorName.isNotEmpty ? settings.operatorName : '-',
      settings.companyName.isNotEmpty ? settings.companyName : '-',
      gpsText,
      location,
      code,
    ];
  }

  // ─── Akses cache ──────────────────────────────────────────

  _PrecomputedStyle getStyle(WatermarkStyle style, double scale) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');
    if (style == WatermarkStyle.timestamp) {
      throw ArgumentError('Gunakan getTimestamp() untuk gaya timestamp');
    }
    final key = '${style.name}_${scale.toStringAsFixed(3)}';
    return _styleCache.putIfAbsent(key, () => _precomputeGeneral(_settings!, style, scale));
  }

  _PrecomputedTimestamp getTimestamp(double scale) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');
    return _timestampCache.putIfAbsent(scale, () => _precomputeTimestamp(_settings!, scale));
  }

  _PrecomputedFullInfo getFullInfo(double scale) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');
    return _fullInfoCache.putIfAbsent(scale, () => _precomputeFullInfo(_settings!, scale));
  }

  // ─── Font helper ──────────────────────────────────────────

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

  static List<_TextLine> _buildStaticTextLines(WatermarkSettings settings) {
    final lines = <_TextLine>[];
    if (settings.companyName.isNotEmpty) {
      lines.add(_TextLine(
        text: settings.companyName.toUpperCase(),
        sizeOffset: 6,
        isTitle: true,
      ));
    }
    lines.add(_TextLine(text: 'Barcode: {{line0}}', sizeOffset: 0));
    lines.add(_TextLine(text: 'Operator: {{line1}}', sizeOffset: 0));
    lines.add(_TextLine(text: 'Waktu: {{line2}}', sizeOffset: -1));
    lines.add(_TextLine(text: 'Lokasi: {{line3}}', sizeOffset: -1));
    return lines;
  }
}

// ─────────────────────────────────────────────────────────────
//  3.  VIDEO WATERMARK SERVICE (PUBLIC API)
// ─────────────────────────────────────────────────────────────

class VideoWatermarkService {
  static String? lastError;
  static bool _warmedUp = false;

  static Future<void> warmUp() async {
    if (_warmedUp) return;
    try {
      debugPrint('🔥 Memanaskan FFmpeg...');
      final session = await FFmpegKit.execute('-version');
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

  static final _WatermarkCache _cache = _WatermarkCache();

  static Future<void> preload(WatermarkSettings settings) async {
    await _cache.initialize(settings);
  }

  static Future<String?> addWatermark({
    required String inputPath,
    required String outputPath,
    required ScanEntry entry,
    required WatermarkSettings settings,
    void Function(double progress)? onProgress,
  }) async {
    lastError = null;
    try {
      await _cache.initialize(settings);

      final durationSeconds = await _probeVideoDuration(inputPath);
      debugPrint('⏱️ Durasi video: ${durationSeconds}s');

      final srcDim = await _probeVideoDimensions(inputPath);
      int outW = srcDim.width;
      int outH = srcDim.height;
      if (outW <= 0 || outH <= 0) {
        outW = 720;
        outH = 1280;
      } else {
        const maxSide = 1280;
        if (outW > maxSide || outH > maxSide) {
          if (outW >= outH) {
            outH = (outH * maxSide / outW).round();
            outW = maxSide;
          } else {
            outW = (outW * maxSide / outH).round();
            outH = maxSide;
          }
        }
      }
      outW = (outW ~/ 2) * 2;
      outH = (outH ~/ 2) * 2;

      final double scale = (math.min(outW, outH) / 720.0).clamp(0.6, 1.8);
      debugPrint('📐 Output: ${outW}x$outH | Skala watermark: $scale');

      final List<String> watermarkFilters;
      final _XY logoXY;

      if (settings.style == WatermarkStyle.fullInfo) {
        final precomputed = _cache.getFullInfo(scale);
        final data = _cache.getFullInfoData(entry, settings);
        watermarkFilters = precomputed.buildFilters(
          barcode: data[0],
          date: data[1],
          time: data[2],
          operator: data[3],
          company: data[4],
          gpsText: data[5],
          location: data[6],
          code: data[7],
        );
        logoXY = precomputed.logoXY;
      } else if (settings.style == WatermarkStyle.timestamp) {
        final precomputed = _cache.getTimestamp(scale);
        final dynamicData = _cache.getTimestampDynamicData(entry, settings);
        watermarkFilters = precomputed.buildFilters(dynamicData);
        logoXY = precomputed.logoXY;
      } else {
        final precomputed = _cache.getStyle(settings.style, scale);
        final dynamicTexts = _cache.getDynamicTexts(entry, settings);
        watermarkFilters = precomputed.buildFilters(dynamicTexts);
        logoXY = precomputed.logoXY;
      }

      final String scaleFilter = 'scale=$outW:$outH';
      final String videoFilterChain =
          '[0:v]$scaleFilter,${watermarkFilters.join(',')}';

      final logoPath = _cache.logoPath;
      String filterComplex;
      if (logoPath != null) {
        final logoFile = File(logoPath);
        if (await logoFile.exists()) {
          final escapedLogoPath = _escapeFFmpegPath(logoPath);
          filterComplex =
              "movie='$escapedLogoPath'[logo]; $videoFilterChain[base]; [base][logo]overlay=${logoXY.x}:${logoXY.y}:format=auto[outv]";
        } else {
          filterComplex = "$videoFilterChain[outv]";
        }
      } else {
        filterComplex = "$videoFilterChain[outv]";
      }

      final List<String> filterArgs = [
        '-filter_complex', filterComplex,
        '-map', '[outv]',
      ];

      final int bitrate = settings.videoBitrateKbps;
      debugPrint('🎚️ Video bitrate: ${bitrate}kbps');

      final arguments = <String>[
        '-i', inputPath,
        ...filterArgs,
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-b:v', '${bitrate}k',
        '-maxrate', '${bitrate}k',
        '-bufsize', '${bitrate * 2}k',
        '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart',
        '-y',
        outputPath,
      ];

      arguments.insertAll(arguments.length - 1, ['-an']);

      if (onProgress != null && durationSeconds > 0) {
        FFmpegKitConfig.enableLogCallback((log) {
          final message = log.getMessage();
          if (message.contains('out_time_ms=')) {
            final regex = RegExp(r'out_time_ms=(\d+)');
            final match = regex.firstMatch(message);
            if (match != null) {
              final outTimeMs = int.parse(match.group(1)!);
              double progress = outTimeMs / (durationSeconds * 1000);
              if (progress > 1.0) progress = 1.0;
              onProgress(progress);
            }
          }
        });
      }

      debugPrint('🎬 FFmpeg arguments: $arguments');

      final session = await FFmpegKit.executeWithArguments(arguments);
      final returnCode = await session.getReturnCode();

      FFmpegKitConfig.enableLogCallback(null);

      if (!ReturnCode.isSuccess(returnCode)) {
        final output = await session.getOutput();
        final logs = await session.getAllLogsAsString();
        throw Exception('FFmpeg gagal (rc=${returnCode?.getValue()}): $output\n$logs');
      }

      debugPrint('✅ Video watermark berhasil: $outputPath');
      return outputPath;
    } catch (e) {
      FFmpegKitConfig.enableLogCallback(null);
      debugPrint('❌ Error video watermark: $e');
      lastError = 'Exception: $e';
      return null;
    }
  }

  static String _diagnoseFailure(String logs) {
    final l = logs.toLowerCase();
    if (l.contains('no such filter') && l.contains('drawtext')) {
      return 'Filter drawtext TIDAK tersedia. Pastikan pubspec.yaml memakai '
          'ffmpeg_kit_flutter (resmi) atau varian yang menyertakan freetype.';
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

// ─────────────────────────────────────────────────────────────
//  4.  HELPER CLASSES
// ─────────────────────────────────────────────────────────────

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
  final double scale;
  late final double padding = 14 * scale;

  _StyleLayout._(this.style, this.position, this.scale);

  factory _StyleLayout.forStyle(WatermarkStyle style, WatermarkPosition position, double scale) {
    return _StyleLayout._(style, position, scale);
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

    final edgeGap = (20 * scale).round();
    final borderWidth = math.max(1, (2 * scale).round());
    final boxWidth = 'iw*0.45';
    final x = _isRight ? 'iw-($boxWidth)-$edgeGap' : '$edgeGap';
    final y = _isBottom ? 'ih-${blockHeight.toInt()}-$edgeGap' : '$edgeGap';
    final fill = "drawbox=x=$x:y=$y:w=$boxWidth:h=${blockHeight.toInt()}:"
        "color=black@${opacity.clamp(0.0, 1.0)}:t=fill";
    final border = "drawbox=x=$x:y=$y:w=$boxWidth:h=${blockHeight.toInt()}:color=white@0.9:t=$borderWidth";
    return '$fill,$border';
  }

  String? buildAccentBar({required double blockHeight}) {
    if (style == WatermarkStyle.minimal) return null;

    final barWidth = math.max(2, (4 * scale).round());
    final edgeGap = (18 * scale).round();
    final accentColor = style == WatermarkStyle.polaroid ? 'darkorange' : 'orange';
    final x = _isRight ? 'iw-$barWidth-$edgeGap' : '$edgeGap';
    final y = _isBottom ? 'ih-${blockHeight.toInt()}' : '0';
    return "drawbox=x=$x:y=$y:w=$barWidth:h=${blockHeight.toInt()}:color=$accentColor@0.9:t=fill";
  }

  String? buildDivider({required double blockHeight}) {
    if (style == WatermarkStyle.minimal || style == WatermarkStyle.stamp) return null;

    final edgeGap = (18 * scale).round();
    final lineHeight = math.max(1, (1 * scale).round());
    final y = _isBottom ? 'ih-${blockHeight.toInt()}' : '0';
    return "drawbox=x=$edgeGap:y=$y:w=iw-${edgeGap * 2}:h=$lineHeight:color=white@0.2:t=fill";
  }

  String textX() {
    final accentSpace = (style == WatermarkStyle.minimal) ? 0 : (12 * scale).round();
    if (_isFullWidthBanner) return '(w-text_w)/2';
    final inset = (style == WatermarkStyle.stamp ? 32 : 20) * scale;
    return _isRight ? 'w-text_w-${inset.round()}' : '${(inset).round() + accentSpace}';
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
    final baseInset = 20 * scale;
    final inset = style == WatermarkStyle.stamp ? baseInset + padding : baseInset;
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
    final edgeGap = (20 * scale).round();
    final x = _isRight ? 'W-w-$edgeGap' : '$edgeGap';
    final y = _isBottom ? 'H-h-$edgeGap' : '$edgeGap';
    return _XY(x, y);
  }
}
