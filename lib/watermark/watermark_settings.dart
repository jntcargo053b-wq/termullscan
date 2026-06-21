import 'package:shared_preferences/shared_preferences.dart';
import 'models/watermark_style.dart';

class WatermarkSettings {
  static const String _keyOperatorName = 'watermark_operator_name';
  static const String _keyStyle = 'watermark_style';
  static const String _keyLogoPath = 'watermark_logo_path';
  static const String _keyHasLogo = 'watermark_has_logo';

  String operatorName = '';
  WatermarkStyle style = WatermarkStyle.standard;
  String? logoPath;
  bool hasLogo = false;

  WatermarkSettings() {
    load();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      operatorName = prefs.getString(_keyOperatorName) ?? '';
      final styleIndex = prefs.getInt(_keyStyle) ?? 0;
      style = WatermarkStyle.values[styleIndex.clamp(0, WatermarkStyle.values.length - 1)];
      logoPath = prefs.getString(_keyLogoPath);
      hasLogo = prefs.getBool(_keyHasLogo) ?? false;
      debugPrint('✅ Watermark settings loaded: operator=$operatorName, hasLogo=$hasLogo');
    } catch (e) {
      debugPrint('⚠️ Error loading watermark settings: $e');
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
      debugPrint('✅ Watermark settings saved');
    } catch (e) {
      debugPrint('⚠️ Error saving watermark settings: $e');
    }
  }

  Future<void> setOperatorName(String name) async {
    operatorName = name;
    await save();
  }

  Future<void> setStyle(WatermarkStyle newStyle) async {
    style = newStyle;
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
