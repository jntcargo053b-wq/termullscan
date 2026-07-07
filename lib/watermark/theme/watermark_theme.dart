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
          // ⚠️ `maxSize` di sini adalah RASIO kecil (bukan px absolut).
          // MinimalLayout/ProfessionalLayout menghitung logo final dengan
          // `effectiveBaseSize * logo.maxSize * logo.scaleFactor`, jadi
          // hasilnya otomatis proporsional terhadap resolusi foto asli.
          logo: const LogoTheme(
            maxSize: 0.20,
            scaleFactor: 0.70,
            opacity: 0.80,
            cardOpacity: 0.15,
            centerVertically: true,
          ),
          // ⚠️ SEMUA nilai di bawah adalah RASIO terhadap `baseSize`
          // (dimensi pendek foto ASLI dalam piksel), BUKAN nilai piksel
          // absolut. Sebelumnya nilai-nilai ini konstan absolut (mis.
          // fontSize: 11.0) sementara `baseSize` di-scale keliru (*0.8 dari
          // piksel foto asli) lalu dipakai sebagai `lineH = baseSize *
          // lineHeight(1.4)` — hasilnya panel watermark membengkak sampai
          // menutupi seluruh foto, sementara teks & logo tetap kecil/di
          // luar kanvas karena skalanya tidak konsisten satu sama lain.
          typography: TypographyTheme(
            baseSize: baseSize,
            padding: baseSize * 0.032,
            fontSize: baseSize * 0.028,
            lineHeight: 0.048, // rasio tinggi baris, BUKAN multiplier CSS
            captionFontSize: baseSize * 0.020,
            bodyFontSize: baseSize * 0.026,
            barcodeFontSize: baseSize * 0.034,
            titleFontSize: baseSize * 0.034,
            barcodeLineHeight: baseSize * 0.044,
            barcodeRowBonus: baseSize * 0.006,
            titleRowBonus: baseSize * 0.010,
            groupSpacing: baseSize * 0.007,
            coordSpacing: baseSize * 0.009,
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
          // Lihat catatan rasio pada style `minimal` di atas.
          logo: const LogoTheme(
            maxSize: 0.20,
            scaleFactor: 0.75,
            opacity: 0.85,
            cardOpacity: 0.18,
            centerVertically: true,
          ),
          typography: TypographyTheme(
            baseSize: baseSize,
            padding: baseSize * 0.038,
            fontSize: baseSize * 0.030,
            lineHeight: 0.054,
            captionFontSize: baseSize * 0.022,
            bodyFontSize: baseSize * 0.028,
            barcodeFontSize: baseSize * 0.038,
            titleFontSize: baseSize * 0.040,
            barcodeLineHeight: baseSize * 0.050,
            barcodeRowBonus: baseSize * 0.007,
            titleRowBonus: baseSize * 0.011,
            groupSpacing: baseSize * 0.008,
            coordSpacing: baseSize * 0.010,
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
        // Dipakai oleh Polaroid, Stamp, Timestamp, dan FullInfo.
        // Layout-layout ini membaca `theme.typography.baseSize` /
        // `theme.logo.maxSize` LANGSUNG sebagai basis rasio (baseSize di
        // sini tetap dimensi asli foto dalam piksel), jadi field lain pun
        // dibuat proporsional terhadap `baseSize`, bukan konstanta absolut
        // seperti sebelumnya (yang membuat lineH = baseSize(asli, besar) *
        // lineHeight(1.6, multiplier CSS) meledak menutupi foto).
        return WatermarkTheme(
          style: style,
          panel: const PanelTheme(),
          logo: LogoTheme(maxSize: baseSize * 0.14),
          typography: TypographyTheme(
            baseSize: baseSize,
            padding: baseSize * 0.040,
            fontSize: baseSize * 0.032,
            lineHeight: 0.052,
            captionFontSize: baseSize * 0.024,
            bodyFontSize: baseSize * 0.030,
            barcodeFontSize: baseSize * 0.038,
            titleFontSize: baseSize * 0.042,
            barcodeLineHeight: baseSize * 0.050,
            barcodeRowBonus: baseSize * 0.007,
            titleRowBonus: baseSize * 0.011,
            groupSpacing: baseSize * 0.009,
            coordSpacing: baseSize * 0.011,
          ),
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
