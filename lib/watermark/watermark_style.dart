// lib/watermark/watermark_style.dart

enum WatermarkStyle {
  minimal,
  professional,
  polaroid,
  stamp,
  timestamp,
  fullInfo,
}

/// Kapabilitas tiap gaya watermark untuk pipeline VIDEO (FFmpeg drawtext/drawbox).
///
/// Efek yang murni Canvas-only (rotasi teks, bingkai Polaroid yang
/// memperluas kanvas, badge melingkar Stamp) disederhanakan jadi panel/box
/// persegi di video, tapi kontennya sudah representatif dan konsisten.
extension WatermarkStyleCapability on WatermarkStyle {
  /// Apakah gaya ini kompatibel dengan video.
  /// 
  /// [polaroid] menghasilkan bingkai full‑frame yang opaque dan menutupi
  /// seluruh video, sehingga tidak cocok untuk video. Gaya ini akan
  /// disembunyikan dari pilihan di layar video.
  bool get supportsVideo {
    switch (this) {
      case WatermarkStyle.polaroid:
        return false; // ❌ Tidak kompatibel video (bingkai full‑frame)
      // case WatermarkStyle.fullInfo:
      //   return false; // ❌ Jika fullInfo juga full‑frame
      default:
        return true; // ✅ Kompatibel video
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
