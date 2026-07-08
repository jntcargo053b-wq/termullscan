import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'watermark_style.dart';

enum WatermarkPosition {
  bottomRight,
  bottomLeft,
  topRight,
  topLeft,
}

class WatermarkSettings extends ChangeNotifier {
  // ========== SINGLETON ==========
  static final WatermarkSettings _instance = WatermarkSettings._internal();
  factory WatermarkSettings() => _instance;
  WatermarkSettings._internal();

  // ========== KEYS ==========
  static const String _keyOperatorName = 'watermark_operator_name';
  static const String _keyCompanyName = 'watermark_company_name';
  static const String _keyStyle = 'watermark_style';
  static const String _keyLogoPath = 'watermark_logo_path';
  static const String _keyHasLogo = 'watermark_has_logo';
  static const String _keyPosition = 'watermark_position';
  static const String _keyFontSize = 'watermark_font_size';
  static const String _keyBgOpacity = 'watermark_bg_opacity';
  static const String _keyFontFamily = 'watermark_font_family';

  // ─── VIDEO ENCODING KEYS ──────────────────────────────
  static const String _keyVideoBitrate = 'watermark_video_bitrate';
  static const String _keyVideoCrf = 'watermark_video_crf';
  static const String _keyX264Preset = 'watermark_x264_preset';

  // ─── DELETE LOCAL COPY ────────────────────────────────
  static const String _keyDeleteLocalVideo = 'watermark_delete_local_video';

  // ========== PROPERTIES ==========
  String operatorName = '';
  String companyName = '';
  WatermarkStyle style = WatermarkStyle.professional;
  String? logoPath;
  bool hasLogo = false;
  WatermarkPosition position = WatermarkPosition.bottomRight;
  double fontSize = 14.0;
  double backgroundOpacity = 0.85;
  String fontFamily = 'Roboto';

  // ─── VIDEO ENCODING ────────────────────────────────────
  int videoBitrateKbps = 2000;      // 2 Mbps
  int videoCrf = 23;                // 18–28
  String x264Preset = 'medium';     // ultrafast … veryslow

  // ─── DELETE LOCAL COPY AFTER GALLERY EXPORT ──────────
  bool deleteLocalVideoAfterGalleryExport = true;

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      operatorName = prefs.getString(_keyOperatorName) ?? '';
      companyName = prefs.getString(_keyCompanyName) ?? '';
      final styleIndex = prefs.getInt(_keyStyle) ?? WatermarkStyle.professional.index;
      final values = WatermarkStyle.values;
      style = (styleIndex >= 0 && styleIndex < values.length)
          ? values[styleIndex]
          : WatermarkStyle.professional;
      logoPath = prefs.getString(_keyLogoPath);
      hasLogo = prefs.getBool(_keyHasLogo) ?? false;
      final posIndex = prefs.getInt(_keyPosition) ?? WatermarkPosition.bottomRight.index;
      final posValues = WatermarkPosition.values;
      position = (posIndex >= 0 && posIndex < posValues.length)
          ? posValues[posIndex]
          : WatermarkPosition.bottomRight;
      fontSize = prefs.getDouble(_keyFontSize) ?? 14.0;
      backgroundOpacity = prefs.getDouble(_keyBgOpacity) ?? 0.85;
      fontFamily = prefs.getString(_keyFontFamily) ?? 'Roboto';

      // ─── VIDEO ENCODING ──────────────────────────────
      videoBitrateKbps = prefs.getInt(_keyVideoBitrate) ?? 2000;
      videoCrf = prefs.getInt(_keyVideoCrf) ?? 23;
      x264Preset = prefs.getString(_keyX264Preset) ?? 'medium';

      // ─── DELETE LOCAL COPY ────────────────────────────
      deleteLocalVideoAfterGalleryExport = prefs.getBool(_keyDeleteLocalVideo) ?? true;

      _loaded = true;
      debugPrint('✅ Watermark settings loaded');
    } catch (e) {
      debugPrint('⚠️ Error loading watermark settings: $e, using defaults');
      _loaded = true;
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyOperatorName, operatorName);
      await prefs.setString(_keyCompanyName, companyName);
      await prefs.setInt(_keyStyle, style.index);
      if (logoPath != null) {
        await prefs.setString(_keyLogoPath, logoPath!);
      } else {
        await prefs.remove(_keyLogoPath);
      }
      await prefs.setBool(_keyHasLogo, hasLogo);
      await prefs.setInt(_keyPosition, position.index);
      await prefs.setDouble(_keyFontSize, fontSize);
      await prefs.setDouble(_keyBgOpacity, backgroundOpacity);
      await prefs.setString(_keyFontFamily, fontFamily);

      // ─── VIDEO ENCODING ──────────────────────────────
      await prefs.setInt(_keyVideoBitrate, videoBitrateKbps);
      await prefs.setInt(_keyVideoCrf, videoCrf);
      await prefs.setString(_keyX264Preset, x264Preset);

      // ─── DELETE LOCAL COPY ────────────────────────────
      await prefs.setBool(_keyDeleteLocalVideo, deleteLocalVideoAfterGalleryExport);

      debugPrint('✅ Watermark settings saved');
    } catch (e) {
      debugPrint('⚠️ Error saving watermark settings: $e');
    }
  }

  // ========== SETTERS ==========
  Future<void> setOperatorName(String name) async {
    operatorName = name;
    notifyListeners();
    await save();
  }

  Future<void> setCompanyName(String name) async {
    companyName = name;
    notifyListeners();
    await save();
  }

  Future<void> setStyle(WatermarkStyle newStyle) async {
    style = newStyle;
    notifyListeners();
    await save();
  }

  Future<void> setPosition(WatermarkPosition newPosition) async {
    position = newPosition;
    notifyListeners();
    await save();
  }

  Future<void> setFontSize(double size) async {
    fontSize = size.clamp(8.0, 48.0);
    notifyListeners();
    await save();
  }

  Future<void> setBackgroundOpacity(double opacity) async {
    backgroundOpacity = opacity.clamp(0.1, 1.0);
    notifyListeners();
    await save();
  }

  Future<void> setFontFamily(String family) async {
    fontFamily = family;
    notifyListeners();
    await save();
  }

  Future<void> setLogoPath(String? path) async {
    logoPath = path;
    hasLogo = path != null && path.isNotEmpty;
    notifyListeners();
    await save();
  }

  Future<void> clearLogo() async {
    logoPath = null;
    hasLogo = false;
    notifyListeners();
    await save();
  }

  // ─── VIDEO ENCODING SETTERS ──────────────────────────
  Future<void> setVideoBitrate(int bitrate) async {
    videoBitrateKbps = bitrate.clamp(500, 50000);
    notifyListeners();
    await save();
  }

  Future<void> setVideoCrf(int crf) async {
    videoCrf = crf.clamp(18, 30);
    notifyListeners();
    await save();
  }

  Future<void> setX264Preset(String preset) async {
    final allowed = ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'];
    if (allowed.contains(preset)) {
      x264Preset = preset;
      notifyListeners();
      await save();
    }
  }

  // ─── DELETE LOCAL COPY SETTER ────────────────────────
  Future<void> setDeleteLocalVideoAfterGalleryExport(bool value) async {
    deleteLocalVideoAfterGalleryExport = value;
    notifyListeners();
    await save();
  }
}
