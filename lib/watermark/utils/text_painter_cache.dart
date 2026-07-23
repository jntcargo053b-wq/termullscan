import 'package:flutter/material.dart';

/// Cache terpusat untuk TextPainter, TextStyle, dan Shadow
/// Digunakan oleh TextHelper dan LayoutHelper secara bersama
class TextPainterCache {
  static final Map<String, TextPainter> _painterCache = {};
  static final Map<String, TextStyle> _styleCache = {};
  static final Map<String, List<Shadow>> _shadowCache = {};
  
  static const int _maxCacheSize = 100;
  static const int _maxShadowCacheSize = 20;

  // ─── TEXT STYLE CACHE ──────────────────────────────────────────

  static TextStyle getStyle({
    Color color = Colors.black,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.normal,
    String fontFamily = 'Roboto',
    double letterSpacing = 0,
    List<Shadow>? shadows,
    Paint? foreground,
  }) {
    final key = '$color-$fontSize-${fontWeight.index}-$fontFamily-$letterSpacing-${shadows.hashCode}-${foreground.hashCode}';
    
    if (_styleCache.containsKey(key)) {
      return _styleCache[key]!;
    }

    final style = TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontFamily: fontFamily,
      letterSpacing: letterSpacing,
      shadows: shadows,
      foreground: foreground,
    );

    // Limit cache size
    if (_styleCache.length >= _maxCacheSize) {
      final firstKey = _styleCache.keys.first;
      _styleCache.remove(firstKey);
    }

    _styleCache[key] = style;
    return style;
  }

  // ─── SHADOW CACHE ─────────────────────────────────────────────

  static List<Shadow> getSoftShadow({
    double opacity = 0.55,
    double blur = 3,
    double dx = 0,
    double dy = 1,
  }) {
    final key = 'soft-$opacity-$blur-$dx-$dy';
    
    if (_shadowCache.containsKey(key)) {
      return _shadowCache[key]!;
    }

    final shadows = [
      Shadow(
        color: Colors.black.withOpacity(opacity),
        blurRadius: blur,
        offset: Offset(dx, dy),
      ),
    ];

    if (_shadowCache.length >= _maxShadowCacheSize) {
      final firstKey = _shadowCache.keys.first;
      _shadowCache.remove(firstKey);
    }

    _shadowCache[key] = shadows;
    return shadows;
  }

  static List<Shadow> getHeavyShadow({
    double opacity = 0.8,
    double blur = 8,
  }) {
    final key = 'heavy-$opacity-$blur';
    
    if (_shadowCache.containsKey(key)) {
      return _shadowCache[key]!;
    }

    final shadows = [
      Shadow(
        color: Colors.black.withOpacity(opacity),
        blurRadius: blur,
        offset: const Offset(0, 2),
      ),
      Shadow(
        color: Colors.black.withOpacity(opacity * 0.6),
        blurRadius: blur * 0.5,
        offset: const Offset(0, 0),
      ),
    ];

    if (_shadowCache.length >= _maxShadowCacheSize) {
      final firstKey = _shadowCache.keys.first;
      _shadowCache.remove(firstKey);
    }

    _shadowCache[key] = shadows;
    return shadows;
  }

  static List<Shadow> getNoShadow() => const [];

  // ─── TEXT PAINTER CACHE ──────────────────────────────────────

  static TextPainter getPainter({
    required String text,
    required TextStyle style,
    double? maxWidth,
    int maxLines = 1,
    TextAlign textAlign = TextAlign.left,
    String? ellipsis,
  }) {
    final key = '$text-${style.hashCode}-$maxWidth-$maxLines-$textAlign-${ellipsis ?? '…'}';
    
    if (_painterCache.containsKey(key)) {
      return _painterCache[key]!;
    }

    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: ellipsis ?? '…',
      textAlign: textAlign,
    );

    // Handle nullable maxWidth
    if (maxWidth != null) {
      painter.layout(maxWidth: maxWidth);
    } else {
      painter.layout();
    }

    // Limit cache size
    if (_painterCache.length >= _maxCacheSize) {
      final firstKey = _painterCache.keys.first;
      _painterCache.remove(firstKey);
    }

    _painterCache[key] = painter;
    return painter;
  }

  /// Mendapatkan TextPainter untuk multi-line text (tanpa batas baris)
  static TextPainter getMultiLinePainter({
    required String text,
    required TextStyle style,
    double? maxWidth,
    TextAlign textAlign = TextAlign.left,
    String? ellipsis,
  }) {
    final key = 'multi-$text-${style.hashCode}-$maxWidth-$textAlign-${ellipsis ?? '…'}';
    
    if (_painterCache.containsKey(key)) {
      return _painterCache[key]!;
    }

    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: null, // Tidak ada batas
      ellipsis: ellipsis ?? '…',
      textAlign: textAlign,
    );

    // Handle nullable maxWidth
    if (maxWidth != null) {
      painter.layout(maxWidth: maxWidth);
    } else {
      painter.layout();
    }

    // Limit cache size
    if (_painterCache.length >= _maxCacheSize) {
      final firstKey = _painterCache.keys.first;
      _painterCache.remove(firstKey);
    }

    _painterCache[key] = painter;
    return painter;
  }

  /// Menghitung jumlah baris teks (menggunakan computeLineMetrics)
  // ✅ FIX: dulu method ini SELALU bikin TextPainter baru & layout baru,
  // beda sendiri dari getPainter/getMultiLinePainter di atas yang
  // konsisten lewat cache — padahal untuk teks yang tidak berubah
  // (mis. alamat yang sama dicek ulang tiap paintOnCanvas untuk
  // menentukan wrap 1/2 baris), ini kerja layout dobel yang sia-sia.
  // Sekarang pakai getMultiLinePainter() yang sama, supaya hasil
  // layout-nya benar-benar dipakai ulang dari cache kalau teks & style
  // sama seperti pemanggilan sebelumnya.
  static int countLines({
    required String text,
    required TextStyle style,
    double? maxWidth,
  }) {
    final painter = getMultiLinePainter(
      text: text,
      style: style,
      maxWidth: maxWidth,
    );
    return painter.computeLineMetrics().length;
  }

  // ─── UTILITY ──────────────────────────────────────────────────

  static void clearAll() {
    _painterCache.clear();
    _styleCache.clear();
    _shadowCache.clear();
  }

  static int get totalCacheSize => 
      _painterCache.length + _styleCache.length + _shadowCache.length;

  static Map<String, int> getCacheStats() => {
    'painterCache': _painterCache.length,
    'styleCache': _styleCache.length,
    'shadowCache': _shadowCache.length,
  };
}
