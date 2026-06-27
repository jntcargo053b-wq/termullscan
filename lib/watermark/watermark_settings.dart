import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'watermark_style.dart';

enum WatermarkPosition {
  bottomRight,
  bottomLeft,
  topRight,
  topLeft,
}

class WatermarkSettings {
  static const String _keyOperatorName = 'watermark_operator_name';
  static const String _keyStyle = 'watermark_style';
  static const String _keyLogoPath = 'watermark_logo_path';
  static const String _keyHasLogo = 'watermark_has_logo';
  static const String _keyPosition = 'watermark_position';
  static const String _keyFontSize = 'watermark_font_size';
  static const String _keyBgOpacity = 'watermark_bg_opacity';
  static const String _keyFontFamily = 'watermark_font_family';

  // ✅ Semua field memiliki nilai default (tidak late)
  String operatorName;
  WatermarkStyle style;
  String? logoPath;
  bool hasLogo;
  WatermarkPosition position;
  double fontSize;
  double backgroundOpacity;
  String fontFamily;

  bool _loaded = false;

  WatermarkSettings()
      : operatorName = '',
        style = WatermarkStyle.professional,
        logoPath = null,
        hasLogo = false,
        position = WatermarkPosition.bottomRight,
        fontSize = 14.0,
        backgroundOpacity = 0.85,
        fontFamily = 'Roboto' {
    load(); // load async, tapi field sudah punya default
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      operatorName = prefs.getString(_keyOperatorName) ?? '';
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
      _loaded = true;
      debugPrint('✅ Watermark settings loaded');
    } catch (e) {
      debugPrint('⚠️ Error loading watermark settings: $e, using defaults');
      // Semua field sudah memiliki default, tidak crash
      _loaded = true;
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyOperatorName, operatorName);
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
      debugPrint('✅ Watermark settings saved');
    } catch (e) {
      debugPrint('⚠️ Error saving watermark settings: $e');
    }
  }

  // ─── Setter ────────────────────────────────────────────────

  Future<void> setOperatorName(String name) async {
    operatorName = name;
    await save();
  }

  Future<void> setStyle(WatermarkStyle newStyle) async {
    style = newStyle;
    await save();
  }

  Future<void> setPosition(WatermarkPosition newPosition) async {
    position = newPosition;
    await save();
  }

  Future<void> setFontSize(double size) async {
    fontSize = size.clamp(8.0, 48.0);
    await save();
  }

  Future<void> setBackgroundOpacity(double opacity) async {
    backgroundOpacity = opacity.clamp(0.1, 1.0);
    await save();
  }

  Future<void> setFontFamily(String family) async {
    fontFamily = family;
    await save();
  }

  Future<void> setLogoPath(String? path) async {
    logoPath = path;
    hasLogo = path != null && path.isNotEmpty;
    await save();
  }

  Future<void> clearLogo() async {
    logoPath = null;
    hasLogo = false;
    await save();
  }
}
