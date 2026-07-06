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
import '../../watermark/theme/watermark_typography.dart';
import 'watermark_utils.dart';

// ─── FILTER TEMPLATE ─────────────────────────────────────

class FilterTemplate {
  final String placeholder;
  final String template;
  FilterTemplate(this.placeholder, this.template);
  String render(String value) => template.replaceFirst(placeholder, escapeFFmpegText(value));
}

// ─── PRECOMPUTED STYLES ──────────────────────────────────

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

/// Tingkat hierarki visual satu baris pada blok info video.
/// title = nama lokasi/perusahaan (paling besar & warna aksen)
/// body  = barcode/operator/tanggal-jam (ukuran sedang, warna normal)
/// caption = koordinat lat/lon (paling kecil, warna sedikit transparan)
enum _Tier { title, body, caption }

/// Satu baris pada blok info hierarki baru (lokasi/tanggal/jam/koordinat).
/// `tier` menentukan ukuran & warna — bukan ikon, murni tipografi.
class _HLine {
  final String text;
  final _Tier tier;
  _HLine(this.text, {this.tier = _Tier.body});
  bool get isTitle => tier == _Tier.title;
}

/// Hasil akhir filter FFmpeg untuk gaya minimal/professional/polaroid/stamp
/// di video, dibangun langsung per-entry (bukan lewat cache placeholder)
/// karena hampir seluruh kontennya memang dinamis per entry.
class GeneralStyleResult {
  final List<String> filters;
  final XY logoXY;
  GeneralStyleResult(this.filters, this.logoXY);
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

  bool get _isFullWidthBanner => style == WatermarkStyle.professional;

  String? buildBackground({required double blockHeight, required double opacity}) {
    if (style == WatermarkStyle.minimal) return null;

    if (_isFullWidthBanner) {
      final color = style == WatermarkStyle.polaroid ? 'white' : 'black';
      final y = _isBottom ? 'ih-${blockHeight.toInt()}' : '0';
      return "drawbox=x=0:y=$y:w=iw:h=${blockHeight.toInt()}:color=$color@${opacity.clamp(0.0, 1.0)}:t=fill";
    }

    final edgeGap = (20 * scale).round();
    final borderWidth = math.max(1, (2 * scale).round());
    final boxWidth = 'iw*0.38'; // maks. 38% lebar video, sesuai spesifikasi desain
    final x = _isRight ? 'iw-($boxWidth)-$edgeGap' : '$edgeGap';
    final y = _isBottom ? 'ih-${blockHeight.toInt()}-$edgeGap' : '$edgeGap';
    // Polaroid = kartu putih transparan + garis tipis abu (bukan kotak
    // gelap + garis putih seperti gaya lain).
    final isPolaroid = style == WatermarkStyle.polaroid;
    final fillColor = isPolaroid ? 'white' : 'black';
    final borderColor = isPolaroid ? 'black@0.18' : 'white@0.9';
    final fill = "drawbox=x=$x:y=$y:w=$boxWidth:h=${blockHeight.toInt()}:"
        "color=$fillColor@${opacity.clamp(0.0, 1.0)}:t=fill";
    final border = "drawbox=x=$x:y=$y:w=$boxWidth:h=${blockHeight.toInt()}:color=$borderColor:t=$borderWidth";
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
    // Minimal & Stamp tidak pakai divider sama sekali. Polaroid juga di-skip
    // sejak jadi kartu kecil bersudut (bukan banner) — garis tepi kartu
    // (border pada buildBackground) sudah berfungsi sebagai "garis tipis".
    if (style == WatermarkStyle.minimal ||
        style == WatermarkStyle.stamp ||
        style == WatermarkStyle.polaroid) {
      return null;
    }

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

  /// Sama seperti [textX] tapi TIDAK dipaksa center — dipakai untuk panel
  /// info kamera profesional (Professional) yang tetap rata kiri/kanan
  /// sesuai posisi watermark, mengikuti pola `professional_layout.dart` (foto).
  String panelTextX({required double contentPadding}) {
    return _isRight ? 'w-text_w-${contentPadding.round()}' : '${contentPadding.round()}';
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

  // Cache key menggunakan String agar bisa menyertakan scale + maxHeight
  final Map<String, PrecomputedTimestamp> _timestampCache = {};
  final Map<String, PrecomputedFullInfo> _fullInfoCache = {};

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

  // ─── Engine Hierarki Info (minimal/professional/polaroid/stamp) ──
  //
  // Berbeda dari timestamp/fullInfo (yang punya bagian label statis vs
  // nilai dinamis yang jelas), gaya-gaya ini kontennya hampir seluruhnya
  // dinamis per entry (nama lokasi, barcode, operator, koordinat) — jadi
  // dibangun langsung per panggilan, tanpa placeholder cache.
  //
  // Hierarki tampilan (baris di-skip kalau datanya kosong, TIDAK diganti
  // teks "tidak tersedia"), disusun 3 tingkat visual seperti saran evaluasi:
  //   [title]   Nama lokasi / nama perusahaan  — paling besar, warna aksen
  //   [body]    Barcode, Operator, tanggal•jam — ukuran sedang, warna normal
  //   [caption] Lat, Lon                       — paling kecil, opacity 75%
  // (Altitude/Accuracy akan otomatis masuk tier caption begitu field-nya
  // ditambahkan ke ScanEntry — lihat catatan di respons sebelumnya.)
  //
  // Ukuran font & padding responsif terhadap TINGGI video, memakai rasio
  // WatermarkTypography yang sama dengan layout foto (title/body/caption)
  // supaya video & foto satu keluarga desain. Lebar blok (styles non-banner)
  // dibatasi 38% lebar video via `buildBackground` (lihat `_StyleLayout`).

  GeneralStyleResult buildGeneralStyleFilters({
    required WatermarkStyle style,
    required WatermarkSettings settings,
    required ScanEntry entry,
    required double scale,
    required int outW,
    required int outH,
  }) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');

    final layout = _StyleLayout.forStyle(style, settings.position, scale);
    final fontSpec = _fontSpec;
    final H = outH.toDouble();

    // ─── Ukuran responsif (berbasis tinggi video) ─────────
    // Baseline "body" dihitung dari tinggi video, lalu title/caption
    // diturunkan dari baseline yang SAMA memakai rasio WatermarkTypography
    // yang sudah jadi standar di layout foto (title ×1.29, caption ×0.79)
    // — supaya video & foto satu keluarga desain, bukan skala terpisah.
    final fontBody = (H * 0.024).clamp(12.0, 46.0);
    final fontTitle = WatermarkTypography.title(fontBody).clamp(16.0, 60.0);
    final fontCaption = WatermarkTypography.caption(fontBody).clamp(10.0, 36.0);
    final blockPadding = (H * 0.015).clamp(10.0, 36.0);
    final lineGap = (H * 0.008).clamp(3.0, 14.0);
    // Semua baris memakai TINGGI baris yang sama (dipatok ke tier terbesar
    // yang dipakai) supaya posisi Y sederhana & tidak pernah tumpang tindih,
    // meski ukuran font per tier berbeda.
    final rowHeight = fontTitle + lineGap;
    final shadowOff = math.max(1, (H * 0.0018).round());

    double sizeFor(_Tier tier) {
      switch (tier) {
        case _Tier.title:
          return fontTitle;
        case _Tier.body:
          return fontBody;
        case _Tier.caption:
          return fontCaption;
      }
    }

    // ─── Lebar maksimum blok → dipakai untuk wrap nama lokasi ─
    final maxBlockWidth = outW * 0.38;
    final approxCharWidth = fontBody * 0.55;
    final maxLineChars = math.max(10, (maxBlockWidth / approxCharWidth).floor());

    // ─── Susun baris sesuai hierarki, skip kalau kosong ───
    // Prioritas visual: lokasi (besar) > tanggal/jam & data operasional
    // (sedang) > koordinat (kecil). Altitude/accuracy akan masuk tier
    // caption juga begitu field-nya tersedia di ScanEntry.
    //
    // Catatan: baris nama perusahaan SENGAJA tidak ada di sini — dicek ke
    // `minimal_layout.dart`/`polaroid_layout.dart` (foto), keduanya tidak
    // pernah merender nama perusahaan sebagai teks (branding cuma lewat
    // logo gambar). Baris itu di versi awal video adalah tambahan saya
    // sendiri yang ternyata tidak sesuai versi foto — sudah dihapus.
    final rawLocation = (entry.locationName ?? '').trim();
    final locationLines = rawLocation.isEmpty
        ? const <String>[]
        : wrapAddress(rawLocation, maxLineLen: maxLineChars).take(2).toList();

    final lines = <_HLine>[];
    for (final l in locationLines) {
      lines.add(_HLine(l, tier: _Tier.title));
    }
    if (entry.value.isNotEmpty) {
      lines.add(_HLine('Barcode: ${entry.value}', tier: _Tier.body));
    }
    if (settings.operatorName.isNotEmpty) {
      lines.add(_HLine('Operator: ${settings.operatorName}', tier: _Tier.body));
    }
    lines.add(_HLine(
      '${ddmmyyyyFF(entry.timestamp)}  •  ${hhmmFF(entry.timestamp)} WIB',
      tier: _Tier.body,
    ));
    if (entry.latitude != null) {
      lines.add(_HLine('Lat ${entry.latitude!.toStringAsFixed(6)}', tier: _Tier.caption));
    }
    if (entry.longitude != null) {
      lines.add(_HLine('Lon ${entry.longitude!.toStringAsFixed(6)}', tier: _Tier.caption));
    }
    // Indikator entri manual — ada di minimal/polaroid (foto) sebagai baris
    // beraksen terpisah. Ditaruh paling akhir, dirender dengan tier title
    // (aksen oranye) supaya tetap menonjol tanpa perlu warna ke-3.
    if (entry.barcodeFormat == 'MANUAL') {
      lines.add(_HLine('MANUAL ENTRY', tier: _Tier.title));
    }

    double blockHeight = (blockPadding * 2) + (lines.length * rowHeight);
    // Polaroid harus tetap kecil (kartu, bukan banner) — dibatasi lebih
    // ketat daripada gaya lain supaya tidak menutupi video.
    final maxHeightRatio = style == WatermarkStyle.polaroid ? 0.28 : 0.5;
    blockHeight = blockHeight.clamp(0.0, H * maxHeightRatio);

    // ─── Background / accent / divider ────────────────────
    final filters = <String>[];
    final bg = layout.buildBackground(blockHeight: blockHeight, opacity: settings.backgroundOpacity);
    if (bg != null) filters.add(bg);
    final accent = layout.buildAccentBar(blockHeight: blockHeight);
    if (accent != null) filters.add(accent);
    final divider = layout.buildDivider(blockHeight: blockHeight);
    if (divider != null) filters.add(divider);

    // ─── Baris teks ────────────────────────────────────────
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final fontSize = sizeFor(line.tier).round();
      final color = line.tier == _Tier.caption
          ? (layout.textColor(false) == 'black' ? 'black@0.75' : 'white@0.75')
          : layout.textColor(line.isTitle);
      final x = layout.textX();
      final y = layout.textY(lineIndex: i, lineHeight: rowHeight, blockHeight: blockHeight);
      filters.add(
        "drawtext=text='${escapeFFmpegText(line.text)}':"
        "$fontSpec:"
        "fontcolor=$color:"
        "fontsize=$fontSize:"
        "x=$x:"
        "y=$y:"
        "shadowcolor=black@0.8:"
        "shadowx=$shadowOff:"
        "shadowy=$shadowOff:"
        "bordercolor=black@0.3:"
        "borderw=${math.max(1, (shadowOff / 2).round())}",
      );
    }

    return GeneralStyleResult(filters, layout.logoXY());
  }

  // ─── Stamp (dedikasi, bukan engine generik) ────────────────
  //
  // Meniru semangat `stamp_layout.dart` (foto): badge modern hijau
  // "VERIFIED" (atau oranye "MANUAL" untuk entri manual) — BUKAN cap merah
  // tradisional. Video tidak bisa rotasi teks seperti foto, jadi badge
  // dirender sebagai baris judul tebal di atas panel (bukan kotak
  // terpisah yang dimiringkan) — penyederhanaan yang disengaja untuk
  // keterbatasan drawtext.
  GeneralStyleResult buildStampVideoFilters({
    required WatermarkSettings settings,
    required ScanEntry entry,
    required double scale,
    required int outW,
    required int outH,
  }) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');

    final layout = _StyleLayout.forStyle(WatermarkStyle.stamp, settings.position, scale);
    final fontSpec = _fontSpec;
    final H = outH.toDouble();

    final isManual = entry.barcodeFormat == 'MANUAL';
    // Hijau modern untuk terverifikasi, oranye untuk entri manual — selaras
    // dengan warna di stamp_layout.dart foto (bukan merah tradisional).
    final badgeColor = isManual ? 'darkorange' : 'seagreen';
    final badgeLabel = isManual ? 'MANUAL' : 'VERIFIED';

    final fontBody = (H * 0.022).clamp(11.0, 42.0);
    final fontBadge = WatermarkTypography.title(fontBody).clamp(15.0, 54.0);
    final fontCaption = WatermarkTypography.caption(fontBody).clamp(9.0, 32.0);
    final fontBarcode = (fontBody * 1.2).clamp(13.0, 48.0);

    final blockPadding = (H * 0.014).clamp(8.0, 30.0);
    final lineGap = (H * 0.007).clamp(3.0, 12.0);
    final shadowOff = math.max(1, (H * 0.0016).round());

    final rows = <_HLine>[
      _HLine(badgeLabel, tier: _Tier.title),
    ];
    if (entry.value.isNotEmpty) {
      rows.add(_HLine('Brg: ${entry.value}', tier: _Tier.body));
    }
    if (settings.operatorName.isNotEmpty) {
      rows.add(_HLine('Op: ${settings.operatorName}', tier: _Tier.body));
    }
    rows.add(_HLine(
      '${ddmmyyyyFF(entry.timestamp)} ${hhmmFF(entry.timestamp)} WIB',
      tier: _Tier.body,
    ));
    if (entry.latitude != null) {
      rows.add(_HLine('Lat ${entry.latitude!.toStringAsFixed(6)}', tier: _Tier.caption));
    }
    if (entry.longitude != null) {
      rows.add(_HLine('Lon ${entry.longitude!.toStringAsFixed(6)}', tier: _Tier.caption));
    }

    final rowHeight = fontBadge + lineGap;
    var blockHeight = (blockPadding * 2) + (rows.length * rowHeight);
    blockHeight = blockHeight.clamp(0.0, H * 0.4);
    final blockHeightInt = blockHeight.toInt();

    final filters = <String>[];
    final bg = layout.buildBackground(blockHeight: blockHeight, opacity: settings.backgroundOpacity);
    if (bg != null) filters.add(bg);

    // Accent bar warna dinamis (hijau/oranye sesuai status), bukan orange
    // tetap seperti gaya lain — dibangun manual, bukan lewat
    // layout.buildAccentBar() yang warnanya statis.
    final barWidth = math.max(2, (4 * scale).round());
    final edgeGap = (18 * scale).round();
    final isRight = settings.position == WatermarkPosition.topRight ||
        settings.position == WatermarkPosition.bottomRight;
    final isBottom = settings.position == WatermarkPosition.bottomLeft ||
        settings.position == WatermarkPosition.bottomRight;
    final barX = isRight ? 'iw-$barWidth-$edgeGap' : '$edgeGap';
    final barY = isBottom ? 'ih-$blockHeightInt' : '0';
    filters.add(
      "drawbox=x=$barX:y=$barY:w=$barWidth:h=$blockHeightInt:color=$badgeColor@0.9:t=fill",
    );

    final x = layout.textX();
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final fontSize = (row.tier == _Tier.title
              ? fontBadge
              : row.tier == _Tier.caption
                  ? fontCaption
                  : (row.text.startsWith('Brg:') ? fontBarcode : fontBody))
          .round();
      final color = row.tier == _Tier.title
          ? badgeColor
          : row.tier == _Tier.caption
              ? 'white@0.7'
              : 'white@0.92';
      final y = layout.textY(lineIndex: i, lineHeight: rowHeight, blockHeight: blockHeight);
      filters.add(
        "drawtext=text='${escapeFFmpegText(row.text)}':"
        "$fontSpec:"
        "fontcolor=$color:"
        "fontsize=$fontSize:"
        "x=$x:"
        "y=$y:"
        "shadowcolor=black@0.8:"
        "shadowx=$shadowOff:"
        "shadowy=$shadowOff",
      );
    }

    return GeneralStyleResult(filters, layout.logoXY());
  }
  //
  // Meniru pola `professional_layout.dart` (foto) persis: LOKASI (judul,
  // aksen) → KODE BARANG (label kecil + value besar-tebal) → OPERATOR
  // (label + value) → TANGGAL (label + value) → JAM (label + value,
  // TERPISAH dari tanggal) → Lat/Lon (kecil, tanpa label, skip jika
  // kosong). Beda dari 4 gaya lain, di sini setiap field bernilai adalah
  // pasangan LABEL (caption pudar) + VALUE (lebih besar), bukan satu
  // baris datar — ini yang bikin panel terasa "info kamera profesional"
  // alih-alih semua teks berukuran hampir sama.
  GeneralStyleResult buildProfessionalVideoFilters({
    required WatermarkSettings settings,
    required ScanEntry entry,
    required double scale,
    required int outW,
    required int outH,
  }) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');

    final layout = _StyleLayout.forStyle(WatermarkStyle.professional, settings.position, scale);
    final fontSpec = _fontSpec;
    final H = outH.toDouble();

    final fontBody = (H * 0.024).clamp(12.0, 46.0);
    final fontTitle = WatermarkTypography.title(fontBody).clamp(16.0, 60.0);
    final fontCaption = WatermarkTypography.caption(fontBody).clamp(10.0, 34.0);
    // Nilai barcode ditekankan (lebih besar), meniru theme.barcodeFontSize.
    final fontBarcode = (fontBody * 1.35).clamp(14.0, 54.0);

    final blockPadding = (H * 0.018).clamp(10.0, 40.0);
    final labelGap = (H * 0.004).clamp(1.0, 6.0); // jarak label → value
    final fieldGap = (H * 0.010).clamp(4.0, 20.0); // jarak antar field
    final titleGap = (H * 0.012).clamp(4.0, 22.0);
    final shadowOff = math.max(1, (H * 0.0018).round());

    final barWidth = math.max(2, (4 * scale).round());
    final edgeGap = (18 * scale).round();
    final contentPadding = (edgeGap + barWidth + (10 * scale)).toDouble();

    // Lebar wrap nama lokasi (panel full-width, jadi lebar longgar).
    final maxBlockWidth = outW * 0.85;
    final approxCharWidth = fontTitle * 0.55;
    final maxLineChars = math.max(10, (maxBlockWidth / approxCharWidth).floor());
    final rawLocation = (entry.locationName ?? '').trim();
    final locationLines = rawLocation.isEmpty
        ? const <String>[]
        : wrapAddress(rawLocation, maxLineLen: maxLineChars).take(2).toList();

    final hasBarcode = entry.value.isNotEmpty;
    final hasOperator = settings.operatorName.isNotEmpty;
    final hasCoords = entry.latitude != null || entry.longitude != null;

    // ─── Hitung tinggi total blok ──────────────────────────
    double height = blockPadding * 2;
    for (var i = 0; i < locationLines.length; i++) {
      height += fontTitle + (i == locationLines.length - 1 ? titleGap : labelGap);
    }
    if (hasBarcode) height += fontCaption + labelGap + fontBarcode + fieldGap;
    if (hasOperator) height += fontCaption + labelGap + fontBody + fieldGap;
    height += fontCaption + labelGap + fontBody + fieldGap; // TANGGAL
    height += fontCaption + labelGap + fontBody; // JAM (field terakhir sebelum koordinat)
    if (hasCoords) {
      height += fieldGap;
      if (entry.latitude != null) height += fontCaption + labelGap;
      if (entry.longitude != null) height += fontCaption;
    }
    final blockHeight = height.clamp(0.0, H * 0.55);
    final blockHeightInt = blockHeight.toInt();

    final filters = <String>[];
    final bg = layout.buildBackground(blockHeight: blockHeight, opacity: settings.backgroundOpacity);
    if (bg != null) filters.add(bg);
    final accent = layout.buildAccentBar(blockHeight: blockHeight);
    if (accent != null) filters.add(accent);
    final divider = layout.buildDivider(blockHeight: blockHeight);
    if (divider != null) filters.add(divider);

    final x = layout.panelTextX(contentPadding: contentPadding);
    final topExpr = layout._isBottom ? 'h-$blockHeightInt' : '0';
    String yExpr(double cursor) => '($topExpr)+${cursor.round()}';

    double cursor = blockPadding;

    void addLine(String text, {required double fontSize, required String color, bool bold = false}) {
      filters.add(
        "drawtext=text='${escapeFFmpegText(text)}':"
        "$fontSpec:"
        "fontcolor=$color:"
        "fontsize=${fontSize.round()}:"
        "x=$x:"
        "y=${yExpr(cursor)}:"
        "shadowcolor=black@0.8:"
        "shadowx=$shadowOff:"
        "shadowy=$shadowOff"
        "${bold ? ':bordercolor=black@0.4:borderw=${math.max(1, (shadowOff * 1.4).round())}' : ''}",
      );
    }

    void addLabelValue(String label, String value, {required double valueSize, required String valueColor, bool bold = false}) {
      addLine(label, fontSize: fontCaption, color: 'white@0.45');
      cursor += fontCaption + labelGap;
      addLine(value, fontSize: valueSize, color: valueColor, bold: bold);
      cursor += valueSize + fieldGap;
    }

    // Lokasi (judul, aksen oranye)
    for (var i = 0; i < locationLines.length; i++) {
      addLine(locationLines[i], fontSize: fontTitle, color: 'orange', bold: true);
      cursor += fontTitle + (i == locationLines.length - 1 ? titleGap : labelGap);
    }

    if (hasBarcode) {
      addLabelValue('KODE BARANG', entry.value, valueSize: fontBarcode, valueColor: 'white', bold: true);
    }
    if (hasOperator) {
      addLabelValue('OPERATOR', settings.operatorName, valueSize: fontBody, valueColor: 'white@0.92');
    }
    addLabelValue('TANGGAL', ddmmyyyyFF(entry.timestamp), valueSize: fontBody, valueColor: 'white@0.85');
    // JAM ditulis manual (bukan lewat addLabelValue) karena tidak perlu
    // fieldGap tambahan sebelum baris koordinat.
    addLine('JAM', fontSize: fontCaption, color: 'white@0.45');
    cursor += fontCaption + labelGap;
    addLine('${hhmmFF(entry.timestamp)} WIB', fontSize: fontBody, color: 'white@0.80');
    cursor += fontBody;

    if (hasCoords) {
      cursor += fieldGap;
      if (entry.latitude != null) {
        addLine('Lat ${entry.latitude!.toStringAsFixed(6)}', fontSize: fontCaption, color: 'white@0.65');
        cursor += fontCaption + labelGap;
      }
      if (entry.longitude != null) {
        addLine('Lon ${entry.longitude!.toStringAsFixed(6)}', fontSize: fontCaption, color: 'white@0.65');
      }
    }

    return GeneralStyleResult(filters, layout.logoXY());
  }

  // ─── Precompute Timestamp ──────────────────────────────
  // Urutan dynamic filters: meta0, meta1, time, date, day, addr0, addr1, code
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
    final double barHeight = (padding * 2 + metaBlockH + timeRowH + addressBlockH).toDouble();
    final double effectiveBarHeight = maxHeight != null 
        ? math.min(barHeight, maxHeight * 0.28) 
        : barHeight;

    final fontSpec = _fontSpec;
    final staticParts = <String>[];

    // Background bar
    staticParts.add(
      "drawbox=x=0:y=ih-$effectiveBarHeight:w=iw:h=$effectiveBarHeight:"
      "color=black@${settings.backgroundOpacity.clamp(0.4, 1.0)}:t=fill",
    );

    // Brand name & tagline (statis)
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

    // ─── Dynamic filters ────────────────────────────────
    final dynamicTemplates = <FilterTemplate>[];

    // 1. meta0
    dynamicTemplates.add(
      FilterTemplate(
        '{{meta0}}',
        "drawtext=text='{{meta0}}':"
        "$fontSpec:fontcolor=white@0.9:fontsize=$metaFontSize:"
        "x=$padding:y=h-$effectiveBarHeight+${padding + 0 * (metaFontSize + gap8)}:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    // 2. meta1
    dynamicTemplates.add(
      FilterTemplate(
        '{{meta1}}',
        "drawtext=text='{{meta1}}':"
        "$fontSpec:fontcolor=white@0.9:fontsize=$metaFontSize:"
        "x=$padding:y=h-$effectiveBarHeight+${padding + 1 * (metaFontSize + gap8)}:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );

    final timeRowTop = (maxMetaLines > 0) ? padding + maxMetaLines * (metaFontSize + gap8) : padding;

    // 3. time
    dynamicTemplates.add(
      FilterTemplate(
        '{{time}}',
        "drawtext=text='{{time}}':"
        "$fontSpec:fontcolor=white:fontsize=$timeFontSize:"
        "x=$padding:y=h-$effectiveBarHeight+$timeRowTop:"
        "shadowcolor=black@0.85:shadowx=$shadow2:shadowy=$shadow2",
      ),
    );

    // Divider (statis)
    final dividerX = padding + (timeFontSize * 2.6).round();
    staticParts.add(
      "drawbox=x=$dividerX:y=ih-$effectiveBarHeight+$timeRowTop:w=$barWidth:h=$timeFontSize:"
      "color=$accentColor@0.95:t=fill",
    );

    final dateColX = dividerX + gap16;

    // 4. date
    dynamicTemplates.add(
      FilterTemplate(
        '{{date}}',
        "drawtext=text='{{date}}':"
        "$fontSpec:fontcolor=white:fontsize=$dateFontSize:"
        "x=$dateColX:y=h-$effectiveBarHeight+$timeRowTop:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    // 5. day
    dynamicTemplates.add(
      FilterTemplate(
        '{{day}}',
        "drawtext=text='{{day}}':"
        "$fontSpec:fontcolor=white@0.8:fontsize=$dayFontSize:"
        "x=$dateColX:y=h-$effectiveBarHeight+$timeRowTop+${dateFontSize + gap4}:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );

    final addressStartY = timeRowTop + timeRowH;

    // 6. addr0
    dynamicTemplates.add(
      FilterTemplate(
        '{{addr0}}',
        "drawtext=text='{{addr0}}':"
        "$fontSpec:fontcolor=white:fontsize=$addressFontSize:"
        "x=$padding:y=h-$effectiveBarHeight+$addressStartY:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    // 7. addr1
    dynamicTemplates.add(
      FilterTemplate(
        '{{addr1}}',
        "drawtext=text='{{addr1}}':"
        "$fontSpec:fontcolor=white:fontsize=$addressFontSize:"
        "x=$padding:y=h-$effectiveBarHeight+$addressStartY + ${addressFontSize + gap8}:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );

    // 8. code
    dynamicTemplates.add(
      FilterTemplate(
        '{{code}}',
        "drawtext=text='{{code}}  •  TERMULSCAN VERIFIED':"
        "$fontSpec:fontcolor=white@0.75:fontsize=$codeFontSize:"
        "x=w-text_w-$padding:y=h-$effectiveBarHeight-${codeFontSize + gap10}:"
        "shadowcolor=black@0.7:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );

    final logoXY = XY('W-w-$logoGap', 'H-h-$logoGap');

    return PrecomputedTimestamp(
      dynamicFilters: dynamicTemplates,
      staticFilters: staticParts,
      logoXY: logoXY,
      barHeight: effectiveBarHeight,
    );
  }

  // ─── Precompute FullInfo ──────────────────────────────
  // Urutan dynamic filters: barcode, date, time, operator, company, gps, location, code
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
    final double barHeight = (padding * 2 + totalRows).toDouble();
    final double effectiveBarHeight = maxHeight != null 
        ? math.min(barHeight, maxHeight * 0.28) 
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

    // 1. barcode
    dynamicTemplates.add(
      FilterTemplate(
        '{{barcode}}',
        "drawtext=text='{{barcode}}':"
        "$fontSpec:fontcolor=white:fontsize=$barcodeSize:"
        "x=$padding:y=h-$effectiveBarHeight+$cursorY:"
        "shadowcolor=black@0.85:shadowx=$shadow2:shadowy=$shadow2",
      ),
    );
    cursorY += barcodeSize + gap6;

    // 2. date & time (digabung menjadi satu filter)
    final dateTimeText = "{{date}}  {{time}} WIB";
    dynamicTemplates.add(
      FilterTemplate(
        '{{datetime}}',
        "drawtext=text='$dateTimeText':"
        "$fontSpec:fontcolor=white@0.95:fontsize=$dateSize:"
        "x=$padding:y=h-$effectiveBarHeight+$cursorY:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    cursorY += dateSize + gap8;

    // 3. operator & company (digabung)
    final opText = "{{operator}}  •  {{company}}";
    dynamicTemplates.add(
      FilterTemplate(
        '{{operator_company}}',
        "drawtext=text='$opText':"
        "$fontSpec:fontcolor=white@0.9:fontsize=$operatorSize:"
        "x=$padding:y=h-$effectiveBarHeight+$cursorY:"
        "shadowcolor=black@0.8:shadowx=$shadow1:shadowy=$shadow1",
      ),
    );
    cursorY += operatorSize + gap8;

    // 4. gps
    if (settings.showGps) {
      dynamicTemplates.add(
        FilterTemplate(
          '{{gps}}',
          "drawtext=text='GPS: {{gps}}':"
          "$fontSpec:fontcolor=white@0.85:fontsize=$gpsSize:"
          "x=$padding:y=h-$effectiveBarHeight+$cursorY:"
          "shadowcolor=black@0.7:shadowx=$shadow1:shadowy=$shadow1",
        ),
      );
      cursorY += gpsSize + gap4;
    }

    // 5. location
    if (settings.showLocation) {
      dynamicTemplates.add(
        FilterTemplate(
          '{{location}}',
          "drawtext=text='Lok: {{location}}':"
          "$fontSpec:fontcolor=white@0.8:fontsize=$locationSize:"
          "x=$padding:y=h-$effectiveBarHeight+$cursorY:"
          "shadowcolor=black@0.7:shadowx=$shadow1:shadowy=$shadow1",
        ),
      );
      cursorY += locationSize + gap4;
    }

    // 6. code (statis, tetapi pakai placeholder agar bisa di-render)
    staticParts.add(
      "drawtext=text='{{code}}  •  TERMULSCAN VERIFIED':"
      "$fontSpec:fontcolor=white@0.7:fontsize=$codeSize:"
      "x=w-text_w-$padding:y=h-$effectiveBarHeight-${codeSize + gap10}:"
      "shadowcolor=black@0.6:shadowx=$shadow1:shadowy=$shadow1",
    );

    // Karena code ditangani statis, kita perlu menambahkan FilterTemplate untuk code
    // agar buildFilters bisa mengganti placeholder-nya.
    dynamicTemplates.add(
      FilterTemplate(
        '{{code}}',
        "" // tidak digunakan karena sudah di staticParts, tapi placeholder harus tetap ada
      ),
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

  // Urutan HARUS: meta0, meta1, time, date, day, addr0, addr1, code
  List<String> getTimestampDynamicData(ScanEntry entry, WatermarkSettings settings, {int? maxLineLen}) {
    final metaLines = <String>[];
    if (entry.value.isNotEmpty) metaLines.add('Brg: ${entry.value}');
    if (settings.operatorName.isNotEmpty) metaLines.add('Op: ${settings.operatorName}');

    final addressText = (entry.locationName != null && entry.locationName!.isNotEmpty)
        ? entry.locationName!
        : (entry.latitude != null && entry.longitude != null)
            ? '${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}'
            : 'Lokasi tidak tersedia';
    final maxLen = maxLineLen ?? 42;
    final addressLines = wrapAddress(addressText, maxLineLen: maxLen);

    return [
      metaLines.isNotEmpty ? metaLines[0] : '',           // meta0
      metaLines.length > 1 ? metaLines[1] : '',           // meta1
      hhmmFF(entry.timestamp),                            // time
      ddmmyyyyFF(entry.timestamp),                        // date
      dayNameFF(entry.timestamp),                         // day
      addressLines.isNotEmpty ? addressLines[0] : '',     // addr0
      addressLines.length > 1 ? addressLines[1] : '',     // addr1
      generateVerificationCode(entry, settings),          // code
    ];
  }

  // Urutan HARUS: barcode, date, time, operator, company, gpsText, location, code
  // (sama dengan urutan di buildFilters FullInfo)
  List<String> getFullInfoData(ScanEntry entry, WatermarkSettings settings) {
    final dateStr = ddmmyyyyFF(entry.timestamp);
    final timeStr = hhmmFF(entry.timestamp);
    final gpsText = (entry.latitude != null && entry.longitude != null)
        ? '${entry.latitude!.toStringAsFixed(4)}, ${entry.longitude!.toStringAsFixed(4)}'
        : 'GPS tidak tersedia';
    final location = entry.locationName ?? '';
    final code = generateVerificationCode(entry, settings);
    return [
      entry.value,              // barcode
      dateStr,                  // date
      timeStr,                  // time
      settings.operatorName.isNotEmpty ? settings.operatorName : '-', // operator
      settings.companyName.isNotEmpty ? settings.companyName : '-',   // company
      gpsText,                  // gps
      location,                 // location
      code,                     // code
    ];
  }

  // ─── Akses Cache (dengan String key) ──────────────────

  PrecomputedTimestamp getTimestamp(double scale, {int? maxHeight}) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');
    final key = 'timestamp_${scale.toStringAsFixed(3)}_${maxHeight ?? 0}';
    return _timestampCache.putIfAbsent(
      key,
      () => _precomputeTimestamp(_settings!, scale, maxHeight: maxHeight),
    );
  }

  PrecomputedFullInfo getFullInfo(double scale, {int? maxHeight}) {
    if (!_initialized) throw StateError('Cache belum diinisialisasi');
    final key = 'fullinfo_${scale.toStringAsFixed(3)}_${maxHeight ?? 0}';
    return _fullInfoCache.putIfAbsent(
      key,
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

}
