enum WatermarkStyle {
  minimal,
  professional,
  polaroid,
  stamp,
  timestamp,
  fullInfo, // ← tambahkan ini
}

/// Kapabilitas tiap gaya watermark untuk pipeline VIDEO (FFmpeg drawtext/drawbox).
///
/// Renderer FOTO memakai Flutter Canvas (bisa rotasi teks, bingkai custom,
/// badge melingkar, dsb), sedangkan renderer VIDEO memakai filter FFmpeg
/// (drawtext/drawbox) yang jauh lebih terbatas — tidak bisa rotasi teks,
/// tidak bisa memperluas kanvas (bingkai Polaroid), dan tidak bisa bentuk
/// custom (badge Stamp). Hanya gaya dengan implementasi FFmpeg khusus &
/// teruji (timestamp, fullInfo) yang dianggap "video-safe". Gaya lain jatuh
/// ke fallback generik yang tidak merepresentasikan desain aslinya di video.
extension WatermarkStyleCapability on WatermarkStyle {
  bool get supportsVideo {
    switch (this) {
      case WatermarkStyle.timestamp:
      case WatermarkStyle.fullInfo:
        return true;
      case WatermarkStyle.minimal:
      case WatermarkStyle.professional:
      case WatermarkStyle.polaroid:
      case WatermarkStyle.stamp:
        return false;
    }
  }
}

enum VideoQuality {
  low,    // 2500 kbps
  medium, // 3500 kbps
  high,   // 4000 kbps
}

enum VideoResolution {
  original, // Pertahankan resolusi asli video sumber
  res1080p, // Sisi terpanjang di-scale ke 1920px
  res720p,  // Sisi terpanjang di-scale ke 1280px
}

enum ProcessingMode {
  fast,         // preset veryfast — proses cepat, ukuran/kompresi kurang optimal
  professional, // preset slow — proses lebih lama, kompresi & kualitas lebih baik
}

