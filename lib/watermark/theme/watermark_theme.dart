// lib/watermark/theme/watermark_theme.dart
import 'dart:math' as math; // ← WAJIB ditambahkan
import 'package:flutter/material.dart';
import '../watermark_style.dart';
import '../watermark_settings.dart';
import '../models/watermark_data.dart';

// ─── SUB‑THEME: Panel ───────────────────────────────────────────
class PanelTheme {
  final Color backgroundColor;
  final double backgroundOpacity;
  final double gradientStartOpacity;
  final double gradientEndOpacity;
  final bool showBorder;
  final double borderWidth;
  final Color borderColor;
  final double borderOpacity;
  final double borderRadius;
  final bool showHighlight;
  final Color highlightColor;
  final double highlightOpacity;

  const PanelTheme({
    this.backgroundColor = Colors.black,
    this.backgroundOpacity = 0.55,
    this.gradientStartOpacity = 0.35,
    this.gradientEndOpacity = 0.70,
    this.showBorder = true,
    this.borderWidth = 1.5,
    this.borderColor = Colors.white,
    this.borderOpacity = 0.10,
    this.borderRadius = 12.0,
    this.showHighlight = true,
    this.highlightColor = Colors.white,
    this.highlightOpacity = 0.08,
  });
}

// ─── SUB‑THEME: Logo ────────────────────────────────────────────
class LogoTheme {
  final double maxSize;          // ukuran dasar (sebelum scaling)
  final double scaleFactor;      // faktor penskalaan (0.0–1.0)
  final double opacity;          // opacity logo
  final double cardOpacity;      // opacity background card
  final bool centerVertically;   // posisi di tengah vertikal panel

  const LogoTheme({
    this.maxSize = 52.0,
    this.scaleFactor = 0.75,
    this.opacity = 0.85,
    this.cardOpacity = 0.18,
    this.centerVertically = true,
  });
}

// ─── SUB‑THEME: Tipografi ──────────────────────────────────────
class TypographyTheme {
  final double baseSize;          // ukuran dasar untuk scaling
  final double padding;           // padding internal panel
  final double fontSize;          // ukuran font standar
  final double lineHeight;        // tinggi baris (multiplier)
  final double captionFontSize;   // untuk label/keterangan
  final double bodyFontSize;      // untuk nilai biasa
  final double barcodeFontSize;   // untuk nilai barcode
  final double titleFontSize;     // untuk judul lokasi
  final double barcodeLineHeight; // tinggi baris barcode
  final double barcodeRowBonus;   // extra spacing baris barcode
  final double titleRowBonus;     // extra spacing judul
  final double groupSpacing;      // jarak antar grup
  final double coordSpacing;      // jarak ekstra sebelum koordinat
  final bool useSpacedLabels;     // aktifkan hair‑space pada label tertentu
  final Set<String> spacedLabelKeys; // label yang diberi spacing

  const TypographyTheme({
    this.baseSize = 14.0,
    this.padding = 14.0,
    this.fontSize = 12.0,
    this.lineHeight = 1.6,
    this.captionFontSize = 8.5,
    this.bodyFontSize = 11.5,
    this.barcodeFontSize = 15.0,
    this.titleFontSize = 16.0,
    this.barcodeLineHeight = 19.0,
    this.barcodeRowBonus = 5.0,
    this.titleRowBonus = 7.0,
    this.groupSpacing = 5.0,
    this.coordSpacing = 6.0,
    this.useSpacedLabels = true,
    this.spacedLabelKeys = const {'TANGGAL', 'JAM', 'OPERATOR'},
  });
}

// ─── SUB‑THEME: Aksen ──────────────────────────────────────────
class AccentTheme {
  final Color color;
  final double barWidth;
  final double barOpacity;
  final bool showBar;

  const AccentTheme({
    this.color = const Color(0xFFFFA726),
    this.barWidth = 2.5,
    this.barOpacity = 0.70,
    this.showBar = true,
  });
}

// ─── WATERMARK THEME UTAMA ─────────────────────────────────────
class WatermarkTheme {
  final WatermarkStyle style;
  final PanelTheme panel;
  final LogoTheme logo;
  final TypographyTheme typography;
  final AccentTheme accent;

  // Properti lain yang tidak masuk sub‑tema
  final double minPanelHeightFraction;
  final double portraitScaleFactor;
  final bool usePortraitScaling;

  const WatermarkTheme({
    required this.style,
    required this.panel,
    required this.logo,
    required this.typography,
    required this.accent,
    this.minPanelHeightFraction = 0.10,
    this.portraitScaleFactor = 0.85,
    this.usePortraitScaling = true,
  });

  // ─── Factory untuk membuat tema berdasarkan style ──────────
  factory WatermarkTheme.of({
    required WatermarkStyle style,
    required WatermarkData data,
    required double baseSize,
  }) {
    switch (style) {
      case WatermarkStyle.minimal:
        return WatermarkTheme(
          style: style,
          panel: const PanelTheme(
            backgroundOpacity: 0.55,
            gradientStartOpacity: 0.30,
            gradientEndOpacity: 0.60,
            borderWidth: 1.0,
            borderOpacity: 0.08,
            borderRadius: 8.0,
            highlightOpacity: 0.06,
          ),
          logo: const LogoTheme(
            maxSize: 40.0,
            scaleFactor: 0.70,
            opacity: 0.80,
            cardOpacity: 0.15,
            centerVertically: true,
          ),
          typography: TypographyTheme(
            baseSize: baseSize * 0.8,
            padding: 10.0,
            fontSize: 11.0,
            lineHeight: 1.4,
            captionFontSize: 8.0,
            bodyFontSize: 10.0,
            barcodeFontSize: 13.0,
            titleFontSize: 13.0,
            barcodeLineHeight: 16.0,
            barcodeRowBonus: 2.0,
            titleRowBonus: 4.0,
            groupSpacing: 3.0,
            coordSpacing: 4.0,
            useSpacedLabels: false,
            spacedLabelKeys: const {},
          ),
          accent: const AccentTheme(
            color: Colors.white,
            barWidth: 0,
            barOpacity: 0,
            showBar: false,
          ),
          minPanelHeightFraction: 0.08,
          portraitScaleFactor: 0.80,
          usePortraitScaling: true,
        );

      case WatermarkStyle.professional:
        return WatermarkTheme(
          style: style,
          panel: const PanelTheme(
            backgroundOpacity: 0.55,
            gradientStartOpacity: 0.35,
            gradientEndOpacity: 0.70,
            borderWidth: 1.5,
            borderOpacity: 0.10,
            borderRadius: 12.0,
            highlightOpacity: 0.08,
          ),
          logo: const LogoTheme(
            maxSize: 52.0,
            scaleFactor: 0.75,
            opacity: 0.85,
            cardOpacity: 0.18,
            centerVertically: true,
          ),
          typography: TypographyTheme(
            baseSize: baseSize * 0.9,
            padding: 14.0,
            fontSize: 12.0,
            lineHeight: 1.6,
            captionFontSize: 8.5,
            bodyFontSize: 11.5,
            barcodeFontSize: 15.0,
            titleFontSize: 16.0,
            barcodeLineHeight: 19.0,
            barcodeRowBonus: 5.0,
            titleRowBonus: 7.0,
            groupSpacing: 5.0,
            coordSpacing: 6.0,
            useSpacedLabels: true,
            spacedLabelKeys: const {'TANGGAL', 'JAM', 'OPERATOR'},
          ),
          accent: const AccentTheme(
            color: Color(0xFFFFA726),
            barWidth: 2.5,
            barOpacity: 0.70,
            showBar: true,
          ),
          minPanelHeightFraction: 0.10,
          portraitScaleFactor: 0.85,
          usePortraitScaling: true,
        );

      default:
        // fallback
        return WatermarkTheme(
          style: style,
          panel: const PanelTheme(),
          logo: const LogoTheme(),
          typography: TypographyTheme(baseSize: baseSize),
          accent: const AccentTheme(),
        );
    }
  }

  // ─── Helper untuk padding/radius logo ──────────────────────
  double logoCardPadding(double drawSize) {
    return math.max(4.0, drawSize * 0.08);
  }

  double logoCardRadius(double padding) {
    return math.min(6.0, padding * 0.8);
  }
}
