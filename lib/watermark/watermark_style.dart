enum WatermarkStyle {
  minimal,
  professional,
  polaroid,
  stamp,
  timestamp,
  fullInfo, // ← tambahkan ini
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

