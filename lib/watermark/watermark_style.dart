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
/// Sejak unifikasi engine hierarki info (lokasi/tanggal/jam/koordinat),
/// SEMUA gaya kini punya implementasi video (lihat
/// `WatermarkCache.buildGeneralStyleFilters` untuk minimal/professional/
/// polaroid/stamp, dan `getTimestamp`/`getFullInfo` untuk 2 gaya lainnya).
/// Efek yang murni Canvas-only (rotasi teks, bingkai Polaroid yang
/// memperluas kanvas, badge melingkar Stamp) disederhanakan jadi panel/box
/// persegi di video, tapi kontennya sudah representatif dan konsisten.
extension WatermarkStyleCapability on WatermarkStyle {
  bool get supportsVideo => true;
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

