import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/watermark_style.dart';

class WatermarkSettings extends ChangeNotifier {
  static const _keyOperator = 'wm_operator_name';
  static const _keyLogoPath = 'wm_logo_path';
  static const _keyStyle = 'wm_style';

  String _operatorName = '';
  String? _logoPath;
  WatermarkStyle _style = WatermarkStyle.polaroid;
  bool _isLoaded = false;

  String get operatorName => _operatorName;
  String? get logoPath => _logoPath;
  WatermarkStyle get style => _style;
  bool get isLoaded => _isLoaded;

  bool get hasLogo {
    if (_logoPath == null) return false;
    try {
      return File(_logoPath!).existsSync();
    } catch (_) {
      return false;
    }
  }

  File? get logoFile {
    if (_logoPath == null) return null;
    try {
      final file = File(_logoPath!);
      if (file.existsSync()) return file;
      return null;
    } catch (_) {
      return null;
    }
  }

  static final WatermarkSettings _instance = WatermarkSettings._internal();
  factory WatermarkSettings() => _instance;
  WatermarkSettings._internal();

  Future<void> load() async {
    if (_isLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _operatorName = prefs.getString(_keyOperator) ?? '';
      _logoPath = prefs.getString(_keyLogoPath);
      final styleName = prefs.getString(_keyStyle);
      _style = WatermarkStyle.values.firstWhere(
        (s) => s.name == styleName,
        orElse: () => WatermarkStyle.polaroid,
      );
      _isLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Error loading WatermarkSettings: $e');
      _isLoaded = true; // tetap set true agar tidak infinite loop
    }
  }

  Future<void> setStyle(WatermarkStyle style) async {
    _style = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyStyle, style.name);
    notifyListeners();
  }

  Future<void> setOperatorName(String name) async {
    _operatorName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyOperator, name);
    notifyListeners();
  }

  Future<void> setLogoPath(String? path) async {
    // ✅ Hapus logo lama jika ada
    if (_logoPath != null && path != _logoPath) {
      try {
        final oldFile = File(_logoPath!);
        if (await oldFile.exists()) {
          await oldFile.delete();
          debugPrint('🗑️ Old logo deleted: $_logoPath');
        }
      } catch (e) {
        debugPrint('⚠️ Could not delete old logo: $e');
      }
    }

    _logoPath = path;
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove(_keyLogoPath);
    } else {
      await prefs.setString(_keyLogoPath, path);
    }
    notifyListeners();
  }
}
