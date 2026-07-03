// lib/watermark/watermark_settings.dart
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
  static const String _keyShowGps = 'watermark_show_gps';       // baru
  static const String _keyShowLocation = 'watermark_show_location'; // baru

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
  bool showGps = true;       // baru
  bool showLocation = true;  // baru

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
      showGps = prefs.getBool(_keyShowGps) ?? true;
      showLocation = prefs.getBool(_keyShowLocation) ?? true;
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
      await prefs.setBool(_keyShowGps, showGps);
      await prefs.setBool(_keyShowLocation, showLocation);
      debugPrint('✅ Watermark settings saved');
    } catch (e) {
      debugPrint('⚠️ Error saving watermark settings: $e');
    }
  }

  // ========== SETTERS (tambahkan untuk flags baru) ==========
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

  // ========== SETTERS UNTUK FLAGS ==========
  Future<void> setShowGps(bool value) async {
    showGps = value;
    notifyListeners();
    await save();
  }

  Future<void> setShowLocation(bool value) async {
    showLocation = value;
    notifyListeners();
    await save();
  }
}
