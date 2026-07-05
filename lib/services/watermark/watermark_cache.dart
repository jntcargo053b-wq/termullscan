import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import '../../models/scan_entry.dart';
import '../../watermark/watermark_settings.dart';
import '../../watermark/watermark_style.dart';
import 'watermark_utils.dart';

// ─── FILTER TEMPLATE ─────────────────────────────────────

class FilterTemplate {
  final String placeholder;
  final String template;
  FilterTemplate(this.placeholder, this.template);
  String render(String value) => template.replaceFirst(placeholder, escapeFFmpegText(value));
}

// ─── PRECOMPUTED STYLES ──────────────────────────────────

class PrecomputedStyle {
  final List<FilterTemplate> filterTemplates;
  final XY logoXY;
  final double blockHeight;
  final double blockLineHeight;
  final List<String> staticFilters;
  PrecomputedStyle({
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

class PrecomputedTimestamp {
  final List<FilterTemplate> dynamicFilters;
  final List<String> staticFilters;
  final XY logoXY;
  final double barHeight;
  PrecomputedTimestamp({
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

class PrecomputedFullInfo {
  final List<FilterTemplate> dynamicFilters;
  final List<String> staticFilters;
  final XY logoXY;
  final double barHeight;
  PrecomputedFullInfo({
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

// ─── HELPER CLASSES ──────────────────────────────────────

class XY {
  final String x;
  final String y;
  XY(this.x, this.y);
}

class _TextLine {
  final String text;
  final double sizeOffset;
  final bool isTitle;
  _TextLine({required this.text, required this.sizeOffset, this.isTitle = false});
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
    final boxWidth = 'iw*0.6';
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

  XY logoXY() {
    final edgeGap = (20 * scale).round();
    final x = _isRight ? 'W-w-$edgeGap' : '$edgeGap';
    final y = _isBottom ? 'H-h-$edgeGap' : '$edgeGap';
    return XY(x, y);
  }
}

// ─── WATERMARK CACHE ──────────────────────────────────────

class WatermarkCache {
  static final WatermarkCache _instance = WatermarkCache._internal();
  factory WatermarkCache() => _instance;
  WatermarkCache._internal();

  bool _initialized = false;
  WatermarkSettings? _settings;
  int _lastRevision = -1;
  String? _cachedFontPath;
  String? _cachedLogoPath;
  ui.Image? _cachedLogoImage;

  final Map<String, PrecomputedStyle> _styleCache = {};
  final Map<double, PrecomputedTimestamp> _timestampCache = {};
  final Map<double, PrecomputedFullInfo> _fullInfoCache = {};

  String get _fontSpec {
    if (_cachedFontPath != null) {
      final file = File(_cachedFontPath!);
      if (file.existsSync()) {
        return "fontfile='${escapeFFmpegPath(_cachedFontPath!)}'";
      }
    }
    return "font='sans-serif'";
  }

  Future<void> initialize(WatermarkSettings settings) async {
    if (_initialized && _settings == settings && _lastRevision == settings.revision) {
      return;
    }
    _settings = settings;
    _lastRevision = settings.revision;
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

  // ─── Precompute General ────────────────────────────────

  PrecomputedStyle _precomputeGeneral(
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

    final templates = <FilterTemplate>[];
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
      templates.add(FilterTemplate(placeholder, filter));
    }

    final logoXY = layout.logoXY();
    return PrecomputedStyle(
      filterTemplates: templates,
      logoXY: logoXY,
      blockHeight: blockHeight,
      blockLineHeight: blockLineHeight,
      staticFilters: staticParts,
    );
  }

  // ─── Precompute Timestamp ──────────────────────────────

  PrecomputedTimestamp _precomputeTimestamp(WatermarkSettings settings, double scale, {int? maxHeight}) {
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

    // PERBAIKAN: gunakan ternary langsung untuk hasil double pasti
    final double effectiveBarHeight = maxHeight != null
        ? (barHeight < maxHeight * 0.28 ? barHeight : maxHeight * 0.28)
        : barHeight;

    final fontSpec = _fontSpec;
    final staticParts = <String>[];

    staticParts.add(
      "drawbox=x=0:y=ih-$effectiveBarHeight:w=iw:h=$effectiveBarHeight:"
      "color=black@${settings.backgroundOpacity.clamp(0.4, 1.0)}:t=fill",
    );

    final brandText = settings.companyName.isNotEmpty ? settings.companyName : 'TermulScan';
    staticParts.add(
      "drawtext=text='${escapeFFmpegText(brandText)}':"
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
      "x=w-text_w-$padding:y=ih-$effectiveBarHeight-${codeFontSize + gap10}:"
      "shadowcolor=black@0.7:shadowx=$shadow1:shadowy=$shadow1",
    );

    final dynamicTemplates = <FilterTemplate>[];

    for (var i = 0; i < maxMetaLines; i++) {
      final placeholder = '{{meta$i}}';
      final yPos = padding + i * (metaFontSize + gap8);
      final filter =
          "drawtext=text='$placeholder':"
          "$fontSpec:fontcolor=white@0.9:fontsize=$metaFontSize:"
          "x=$padding:y=ih-$effectiveBarHeight+$yPos:"
          "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1";
      dynamicTemplates.add(FilterTemplate(placeholder, filter));
    }

    final timeRowTop = (maxMetaLines > 0) ? padding + maxMetaLines * (metaFontSize + gap8) : padding;
    dynamicTemplates.add(
      FilterTemplate(
        '{{time}}',
        "drawtext=text='{{time}}':"
        "$fontSpec:fontcolor=white:fontsize=$timeFontSize:"
        "x=$padding:y=ih-$effectiveBarHeight+$timeRowTop:"
        "shadowcolor=black@0.85:shadowx=$shadow2:shadowy=$shadow2",
      ),
    );

    final dividerX = padding + (timeFontSize * 2.6).round();
    staticParts.add(
      "drawbox=x=$dividerX:y=ih-$effectiveBarHeight+$timeRowTop:w=$barWidth:h=$timeFontSize:"
      "color=$accentColor@0.95:t=fill",
    );

    final dateColX = dividerX + gap16;
    dynamicTemplates.add(
      FilterTemplate(
        '{{date}}',
        "drawtext=text='{{date}}':"
        "$fontSpec:fontcolor=white:fontsize=$dateFontSize:"
        "x=$dateColX:y=ih-$effectiveBarHeight+$timeRowTop:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    dynamicTemplates.add(
      FilterTemplate(
        '{{day}}',
        "drawtext=text='{{day}}':"
        "$fontSpec:fontcolor=white@0.8:fontsize=$dayFontSize:"
        "x=$dateColX:y=ih-$effectiveBarHeight+$timeRowTop+${dateFontSize + gap4}:"
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
          "x=$padding:y=ih-$effectiveBarHeight+$yPos:"
          "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1";
      dynamicTemplates.add(FilterTemplate(placeholder, filter));
    }

    final logoXY = XY('W-w-$logoGap', 'H-h-$logoGap');

    return PrecomputedTimestamp(
      dynamicFilters: dynamicTemplates,
      staticFilters: staticParts,
      logoXY: logoXY,
      barHeight: effectiveBarHeight,
    );
  }

  // ─── Precompute FullInfo ──────────────────────────────

  PrecomputedFullInfo _precomputeFullInfo(WatermarkSettings settings, double scale, {int? maxHeight}) {
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

    // PERBAIKAN: gunakan ternary langsung untuk hasil double pasti
    final double effectiveBarHeight = maxHeight != null
        ? (barHeight < maxHeight * 0.28 ? barHeight : maxHeight * 0.28)
        : barHeight;

    final fontSpec = _fontSpec;
    final staticParts = <String>[];

    staticParts.add(
      "drawbox=x=0:y=ih-$effectiveBarHeight:w=iw:h=$effectiveBarHeight:"
      "color=black@${settings.backgroundOpacity.clamp(0.4, 1.0)}:t=fill",
    );

    staticParts.add(
      "drawbox=x=$padding:y=ih-$effectiveBarHeight:w=iw-${padding*2}:h=1:color=white@0.15:t=fill",
    );

    final dynamicTemplates = <FilterTemplate>[];

    int cursorY = padding;

    dynamicTemplates.add(
      FilterTemplate(
        '{{barcode}}',
        "drawtext=text='{{barcode}}':"
        "$fontSpec:fontcolor=white:fontsize=$barcodeSize:"
        "x=$padding:y=ih-$effectiveBarHeight+$cursorY:"
        "shadowcolor=black@0.85:shadowx=$shadow2:shadowy=$shadow2",
      ),
    );
    cursorY += barcodeSize + gap6;

    final dateTimeText = "{{date}}  {{time}} WIB";
    dynamicTemplates.add(
      FilterTemplate(
        '{{datetime}}',
        "drawtext=text='$dateTimeText':"
        "$fontSpec:fontcolor=white@0.95:fontsize=$dateSize:"
        "x=$padding:y=ih-$effectiveBarHeight+$cursorY:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    cursorY += dateSize + gap8;

    final opText = "{{operator}}  •  {{company}}";
    dynamicTemplates.add(
      FilterTemplate(
        '{{operator_company}}',
        "drawtext=text='$opText':"
        "$fontSpec:fontcolor=white@0.9:fontsize=$operatorSize:"
        "x=$padding:y=ih-$effectiveBarHeight+$cursorY:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    cursorY += operatorSize + gap8;

    if (settings.showGps) {
      dynamicTemplates.add(
        FilterTemplate(
          '{{gps}}',
          "drawtext=text='📍 {{gps}}':"
          "$fontSpec:fontcolor=white@0.85:fontsize=$gpsSize:"
          "x=$padding:y=ih-$effectiveBarHeight+$cursorY:"
          "shadowcolor=black@0.7:shadowx=$shadow1:shadowy=$shadow1",
        ),
      );
      cursorY += gpsSize + gap4;
    }

    if (settings.showLocation) {
      dynamicTemplates.add(
        FilterTemplate(
          '{{location}}',
          "drawtext=text='🏷️ {{location}}':"
          "$fontSpec:fontcolor=white@0.8:fontsize=$locationSize:"
          "x=$padding:y=ih-$effectiveBarHeight+$cursorY:"
          "shadowcolor=black@0.7:shadowx=$shadow1:shadowy=$shadow1",
        ),
      );
      cursorY += locationSize + gap4;
    }

    staticParts.add(
      "drawtext=text='{{code}}  •  TERMULSCAN VERIFIED':"
      "$fontSpec:fontcolor=white@0.7:fontsize=$codeSize:"
      "x=w-text_w-$padding:y=ih-$effectiveBarHeight-${codeSize + gap10}:"
      "shadowcolor=black@0.6:shadowx=$shadow1:shadowy=$shadow1",
    );

    final logoXY = XY('W-w-$logoGap', 'H-h-$logoGap');

    return PrecomputedFullInfo(
      dynamicFilters: dynamicTemplates,
      staticFilters: staticParts,
      logoXY: logoXY,
      barHeight: effectiveBarHeight,
    );
  }

  // ─── Data Dinamis ──────────────────────────────────────

  List<String> getDynamicTexts(ScanEntry entry, WatermarkSettings settings) {
    final lines = <String>[];
    if (entry.value.isNotEmpty) lines.add(entry.value);
    if (settings.operatorName.isNotEmpty) lines.add(settings.operatorName);
    lines.add(formatTimestamp(entry.timestamp));
    if (entry.locationName != null && entry.locationName!.isNotEmpty) {
      lines.add(entry.locationName!);
    } else if (entry.latitude != null && entry.longitude != null) {
      lines.add('${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}');
    } else {
      lines.add('Lokasi tidak tersedia');
    }
    return lines;
  }

  List<String> getTimestampDynamicData(ScanEntry entry, WatermarkSettings settings, {int? maxLineLen}) {
    final metaLines = <String>[];
    if (entry.value.isNotEmpty) metaLines.add('📦 ${entry.value}');
    if (settings.operatorName.isNotEmpty) metaLines.add('👤 ${settings.operatorName}');

    final addressText = (entry.locationName != null && entry.locationName!.isNotEmpty)
        ? entry.locationName!
        : (entry.latitude != null && entry.longitude != null)
            ? '${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}'
            : 'Lokasi tidak tersedia';
    final maxLen = maxLineLen ?? 42;
    final addressLines = wrapAddress(addressText, maxLineLen: maxLen);

    return [
      hhmmFF(entry.timestamp),
      ddmmyyyyFF(entry.timestamp),
      dayNameFF(entry.timestamp),
      addressLines.isNotEmpty ? addressLines[0] : '',
      addressLines.length > 1 ? addressLines[1] : '',
      metaLines.isNotEmpty ? metaLines[0] : '',
      metaLines.length > 1 ? metaLines[1] : '',
      generateVerificationCode(entry, settings),
    ];
  }

  List<String> getFullInfoData(ScanEntry entry, WatermarkSettings settings) {
    final dateStr = ddmmyyyyFF(entry.timestamp);
    final timeStr = hhmmFF(entry.timestamp);
    final gpsText = (entry.latitude != null && entry.longitude != null)
        ? '${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}'
        : 'GPS tidak tersedia';
    final location = entry.locationName ?? '';
    final code = generateVerificationCode(entry, settings);
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

  // ─── Akses Cache ──────────────────────────────────────

  PrecomputedStyle getStyle(WatermarkStyle style, double scale) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');
    if (style == WatermarkStyle.timestamp) {
      throw ArgumentError('Gunakan getTimestamp() untuk gaya timestamp');
    }
    final key = '${style.name}_${scale.toStringAsFixed(3)}';
    return _styleCache.putIfAbsent(key, () => _precomputeGeneral(_settings!, style, scale));
  }

  PrecomputedTimestamp getTimestamp(double scale, {int? maxHeight}) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');
    return _timestampCache.putIfAbsent(
      scale,
      () => _precomputeTimestamp(_settings!, scale, maxHeight: maxHeight),
    );
  }

  PrecomputedFullInfo getFullInfo(double scale, {int? maxHeight}) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');
    return _fullInfoCache.putIfAbsent(
      scale,
      () => _precomputeFullInfo(_settings!, scale, maxHeight: maxHeight),
    );
  }

  // ─── Font helper ──────────────────────────────────────

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
