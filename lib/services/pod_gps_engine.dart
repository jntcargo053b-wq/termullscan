// lib/services/pod_gps_engine.dart
// ============================================================
// POD GPS ENGINE — Simple & Fast
// ============================================================
// Spec:
//   accuracy threshold (terima sample) : 25m
//   capture threshold (status Good)    : 20m
//   excellent threshold                : 10m
//   excellent max stdDev (cluster)     : 8m
//   excellent max radius (cluster)     : 12m
//   outlier rejection (MAD-based)      : BARU
//   confidence score (0–1)             : BARU
//   timeout            : adaptif — 5 detik outdoor, 10 detik indoor
//                         (dideteksi dari sample pertama: GNSS sat/CN0
//                         kalau ada, fallback ke accuracy OS)
//   target samples     : 3 (fast lock), max 10 untuk refine
//   min sampel utk Excellent : 3
//   centroid           : weighted (bobot 1/accuracy²)
//   avgAccuracy        : weighted (bobot 1/accuracy²)
//   provider           : fused
//   startup            : lastKnownPosition (OS cache + SharedPrefs)
//   distanceFilter     : 0 (stream berhenti total begitu locked — tidak
//                         ada fase post-lock yang perlu distanceFilter)
//   mock GPS           : ditolak (raw.isMocked) + heuristik spoofing lanjutan (teleport speed,
//                         timestamp mundur, 0 satelit tapi ada fix,
//                         accuracy vs HDOP tidak konsisten, streak fix
//                         identik persis) — lihat _evaluateSpoofHeuristics
//   DOP                : HDOP/PDOP dari NMEA GSA (opsional, Android),
//                         ikut menyaring gate GNSS kalau tersedia
//   accuracy gate      : adaptif — 25m outdoor, 40m indoor (gate admisi
//                         window & tier "fair" saja; captureThreshold/
//                         excellentThreshold TETAP fixed, tidak ikut turun).
//                         BARU: dievaluasi ULANG di setiap sample (bukan
//                         dibekukan dari sample pertama) — mengikuti kalau
//                         operator pindah indoor↔outdoor sebelum lock.
//                         Durasi timeout sesi tetap dideteksi sekali saja.
//   velocity filter    : raw.speed/speedAccuracy (Doppler, dari OS) —
//                         (a) motion gate: good/excellent tidak terkunci
//                         selama device masih bergerak (kurir belum
//                         berhenti); (b) heuristik spoofing #6: speed
//                         Doppler vs kecepatan implisit posisi mismatch
//   convergence lock   : BARU — tier "excellent" sekarang juga
//                         mensyaratkan histori CENTROID (bukan cuma
//                         sample mentah) stabil antar-evaluasi
//                         (convergenceMaxDriftMeters, over
//                         convergenceMinTimeSpanMs), bukan hanya
//                         accuracy/stdDev/radius dari satu snapshot.
//                         Timeout juga tidak lagi mutlak: kalau cluster
//                         terlihat trending menuju konvergen tepat saat
//                         timeout jatuh, diberi satu kali grace
//                         extension singkat sebelum force-lock.
//   soft-unlock debounce: BARU — soft-unlock (gerak >= moveThreshold)
//                         sekarang butuh softUnlockDebounceSamples
//                         (default 2) sample BERTURUT-TURUT sebelum
//                         benar-benar terpicu, supaya 1 sample yang
//                         menyimpang sesaat (nanti dibuang outlier
//                         rejection) tidak bikin confidence flicker.
// ============================================================

import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

// ── GPS Configuration ──────────────────────────────────────────
class GpsConfig {
  // ── Threshold admisi sample, adaptif indoor/outdoor (BARU) ───
  // Ini HANYA gate admisi window + tier "fair" (lihat toString di
  // PodConfidence) — TIDAK menggerbang izin capture. Izin capture
  // (tier good/excellent) tetap digerbang [captureThreshold] &
  // [excellentThreshold] yang FIXED, sengaja tidak ikut adaptif,
  // supaya standar bukti POD saat capture tidak pernah turun hanya
  // karena terdeteksi indoor.
  //
  // Alasan dibuat adaptif: di gudang/indoor dengan multipath berat,
  // chip GPS sering lapor accuracy 40-80m terus-menerus. Kalau gate
  // admisi tetap ketat (25m), window bisa kosong SEPANJANG sesi →
  // saat timeout, _forceLock() tidak punya sample apa pun untuk
  // dirata-rata (lihat _onTimeout: window kosong = tidak ada fallback
  // sama sekali, bukan cuma fallback yang jelek). Melonggarkan gate
  // admisi indoor memberi _forceLock() bahan seadanya — outlier
  // rejection (MAD-based, lihat outlierMadFactor) tetap jadi jaring
  // pengaman dari sample yang kelewat liar.
  //
  // Lingkungan dideteksi sekali dari sample PERTAMA (reuse _looksIndoor,
  // logika sama seperti outdoorTimeout/indoorTimeout).
  final double outdoorAccuracyThreshold;
  final double indoorAccuracyThreshold;

  final double captureThreshold;
  final double excellentThreshold;

  // ── Fast path (BARU) ──────────────────────────────────────────
  // Jalan pintas ketika kondisi SUDAH sangat bagus di sample pertama
  // — bukan pengganti algoritma normal (3 sample + convergence untuk
  // excellent, dst), cuma shortcut: kalau satu sample sudah punya
  // akurasi <= fastPathAccuracy, tidak perlu nunggu n>=targetSamples
  // atau _isConverged untuk lock sebagai excellent. Gate anti-spoof
  // (GNSS/velocity) TETAP wajib lolos — shortcut ini cuma melewati
  // syarat jumlah-sample & convergence, bukan syarat keaslian fix.
  final double fastPathAccuracy;
  final double excellentMaxStdDev;
  final double excellentMaxRadius;
  final int targetSamples;
  // ── Quick-lock sample count (BARU) ───────────────────────────
  // Sebelumnya tier "good" (siap foto) mensyaratkan jumlah sample
  // yang SAMA dengan tier "excellent" (targetSamples=3) DAN gate
  // GNSS/velocity yang sama ketatnya — padahal "good" cuma perlu
  // cukup layak untuk dipakai sebagai bukti, bukan presisi maksimal.
  // Dipisah supaya lock awal (status "Siap Foto") bisa lebih cepat
  // seperti Google Maps/kamera timestamp, sementara "excellent" tetap
  // butuh 3 sample + semua gate seperti sebelumnya.
  final int quickLockSamples;
  final int maxWindow;

  // ── Timeout adaptif indoor/outdoor (BARU) ────────────────────
  // Di luar/langit terbuka, GPS lock cepat (3-5 detik) → timeout
  // pendek supaya capture tidak terasa lambat. Di gudang/indoor,
  // sinyal lemah & multipath butuh waktu lebih lama untuk kumpul
  // sample yang layak sebelum force-lock — timeout diperpanjang.
  // Lingkungan dideteksi dari sample PERTAMA yang masuk window:
  //   - Android + data GNSS tersedia → pakai satelit/C-N0 (akurat)
  //   - Selain itu (iOS, atau GNSS native belum sempat kirim data)
  //     → fallback ke accuracy sample pertama vs [indoorAccuracyHint]
  final Duration outdoorTimeout;
  final Duration indoorTimeout;
  final double indoorAccuracyHint;

  final double moveThreshold;
  final double resetThreshold;
  final int outlierMinSamples;
  final double outlierMadFactor;
  final double outlierMinThreshold;

  // ── Soft-unlock debounce (BARU, saran performa #4) ───────────
  // Soft-unlock dulu terpicu dari SATU sample raw yang kebetulan
  // bergeser >= moveThreshold — termasuk kalau sample itu sendiri
  // nanti ternyata outlier sesaat (dibuang MAD-based rejection) yang
  // tidak pernah benar-benar menggeser centroid robust. Convergence
  // history sudah bikin lock ini "self-heal" cepat (lihat catatan di
  // _softUnlock), tapi confidence tetap sempat flicker ke "fair" satu
  // evaluasi sebelum re-lock — kelihatan di badge UI walau cuma
  // sesaat. Debounce ini mensyaratkan [softUnlockDebounceSamples]
  // sample BERTURUT-TURUT yang sama-sama >= moveThreshold sebelum
  // benar-benar soft-unlock — noise/multipath sesaat (yang biasanya
  // cuma 1 sample menyimpang lalu balik normal) tersaring di sini,
  // pergerakan asli (yang konsisten menjauh beberapa sample berturut)
  // tetap terdeteksi secepat sebelumnya + 1 sample. TIDAK berlaku
  // untuk resetThreshold (hard reset) — lompatan sebesar itu cukup
  // jelas untuk direspons segera tanpa debounce.
  final int softUnlockDebounceSamples;

  // ── GNSS quality gate (BARU) ─────────────────────────────────
  // Hanya aktif di Android & hanya jika native side benar-benar
  // mengirim data (lihat PodSample.passesGnssGate). Tujuannya
  // menyaring fix yang accuracy-nya *terlihat* bagus tapi sinyalnya
  // sebenarnya lemah/multipath (umum terjadi di gudang beratap logam).
  final int minGnssSatellitesUsed;
  final double minGnssAvgCn0DbHz;

  // ── Dilution of Precision gate (BARU) ────────────────────────
  // HDOP/PDOP dari sentence NMEA GSA (lihat gnss_quality_service.dart).
  // null di sample → gate ini otomatis lolos (fallback ke satelit/CN0/
  // accuracy). Skala umum: <1 ideal, 1-2 excellent, 2-5 good, 5-10
  // moderate, >10 buruk (geometri satelit lemah/mengelompok).
  final double maxHdop;
  final double maxPdop;

  // ── Deteksi spoofing (BARU) ──────────────────────────────────
  // Selain raw.isMocked (flag OS, gampang dilewati aplikasi fake-GPS
  // yang tidak set flag ini), dipakai beberapa heuristik independen:
  //   1. Kecepatan implisit antar-sample (dari delta posisi) >
  //      maxPlausibleSpeedMps → teleport
  //   2. Timestamp mundur dari sample terakhir → jam dimanipulasi
  //   3. GNSS lapor 0 satelit dipakai tapi OS tetap kasih fix → mustahil
  //      untuk fix asli, indikasi kuat lokasi disuntik dari luar GNSS
  //   4. Accuracy sangat bagus tapi HDOP sangat buruk → tidak konsisten
  //      secara fisik (accuracy asli berkorelasi dengan geometri satelit)
  //   5. N sample terakhir punya lat/lon/accuracy IDENTIK persis →
  //      GPS asli selalu punya jitter kecil, replay statis mencurigakan
  //   6. Kecepatan Doppler (raw.speed, dari chip GPS) tidak cocok
  //      dengan kecepatan implisit dari delta posisi → lihat catatan
  //      Velocity Filter di bawah
  //   7. (BARU) Delta wall-clock vs delta jam monotonic
  //      (elapsedRealtimeNanos, Android native) antar-sample tidak
  //      sinkron → indikasi jam device diubah manual (lihat
  //      spoofClockDriftTolerance)
  final double maxPlausibleSpeedMps;
  final double spoofDopMismatchHdop;
  final double spoofDopMismatchMaxAccuracy;
  final int spoofIdenticalStreak;
  final double spoofVelocityMismatchMps;

  // ── Clock drift check (BARU, review GPS mendalam #2) ─────────
  // Membandingkan delta WALL-CLOCK (timestampMs, bisa diubah manual
  // lewat Setting > Tanggal & Waktu) vs delta MONOTONIC
  // (elapsedRealtimeNanos, dari SystemClock, tidak bisa diubah user)
  // antara dua sample berturut-turut. Hanya aktif kalau KEDUA sample
  // punya elapsedRealtimeNanos (Android native path saja — di iOS/
  // fallback geolocator otomatis nonaktif, sama pola gate lain).
  // Toleransi diberi cukup longgar untuk menyerap jitter NTP kecil
  // dari OS (resync latar belakang beberapa ratus ms itu wajar);
  // drift dalam orde detik+ pada sesi akuisisi yang cuma berlangsung
  // beberapa detik adalah indikasi kuat jam device diubah manual.
  final Duration spoofClockDriftTolerance;

  // ── Velocity Filter (BARU) ───────────────────────────────────
  // `raw.speed`/`raw.speedAccuracy` (Position dari geolocator) SEBELUM
  // ini tidak pernah dipakai sama sekali — padahal ini sumber sinyal
  // yang independen dari lat/lon: speed dihitung chip GPS dari geseran
  // Doppler carrier, bukan diturunkan dari posisi. Dua kegunaan:
  //
  // (a) MOTION GATE (kualitas): sample yang direkam saat device masih
  //     bergerak (mis. kurir belum benar-benar berhenti) TIDAK boleh
  //     mengunci tier good/excellent — GPS saat bergerak lebih rentan
  //     smearing & posisi yang terekam bisa jadi bukan titik berhenti
  //     yang sebenarnya. Sample tetap masuk window (tidak ditolak
  //     admisinya) supaya tidak mengosongkan window seperti kasus
  //     accuracy — cuma tidak dihitung capturable sampai device diam.
  //     Gate hanya aktif kalau speedAccuracy cukup dipercaya (di bawah
  //     [maxSpeedAccuracyForGate]); kalau tidak, gate lolos otomatis
  //     (fallback aman, sama pola dengan gate GNSS/DOP).
  //
  // (b) DETEKSI SPOOFING (heuristik #6 di atas): fake-GPS berbasis
  //     injeksi lat/lon biasanya TIDAK ikut mensimulasikan sinyal
  //     Doppler yang konsisten — raw.speed sering diam di 0 (atau
  //     nilai tetap) walau posisi "melompat" jauh antar-sample. Kalau
  //     speedAccuracy dipercaya tapi selisih |impliedSpeed - raw.speed|
  //     jauh, itu indikasi kuat posisi disuntik dari luar chip GPS.
  final double maxPlausibleStationarySpeedMps;
  final double maxSpeedAccuracyForGate;

  // ── Convergence-based lock (BARU) ────────────────────────────
  // Sebelumnya tier "excellent" HANYA menilai satu snapshot cluster
  // (stdDev/radius dari window SAAT evaluasi) — cluster yang kebetulan
  // rapat di SATU evaluasi tetap lolos gate walau sebenarnya masih
  // trending/bergeser (mis. chip GPS baru mulai settle setelah
  // warm-up). Convergence menambah dimensi WAKTU: melacak histori
  // CENTROID (bukan histori sample mentah) dari beberapa evaluasi
  // terakhir, dan baru dianggap "konvergen" kalau estimasi ITU SENDIRI
  // sudah berhenti bergeser signifikan antar-evaluasi — sinyal jauh
  // lebih kuat daripada sekadar "3 sample kebetulan berdekatan".
  final int convergenceHistorySize;
  final int convergenceMinSamples;
  final double convergenceMaxDriftMeters;
  final int convergenceMinTimeSpanMs;

  // ── Timeout grace extension (BARU) ───────────────────────────
  // Force-lock via timeout dulu murni "waktu habis, pakai apa adanya"
  // — walau drift centroid kelihatan JELAS masih menyempit (tren makin
  // presisi), timeout tetap memotong di detik yang sama. Sekarang:
  // kalau timeout jatuh tepat saat cluster terlihat sedang mengarah ke
  // konvergen (lihat _isTrendingTowardConvergence), diberi SATU kali
  // perpanjangan singkat supaya sampel yang nyaris konvergen sempat
  // benar-benar lock, bukan dipotong tepat di titik paling sayang.
  // Kalau perpanjangan ini juga habis tanpa konvergen, force-lock
  // berjalan seperti biasa (tidak ada perpanjangan kedua — mencegah
  // sesi akuisisi molor tanpa batas).
  final Duration timeoutGraceExtension;

  const GpsConfig({
    this.outdoorAccuracyThreshold = 25.0,
    this.indoorAccuracyThreshold = 40.0,
    this.captureThreshold = 20.0,
    this.excellentThreshold = 12.0,
    this.fastPathAccuracy = 6.0,
    this.excellentMaxStdDev = 8.0,
    this.excellentMaxRadius = 12.0,
    this.targetSamples = 3,
    this.quickLockSamples = 2,
    this.maxWindow = 10,
    this.outdoorTimeout = const Duration(seconds: 5),
    this.indoorTimeout = const Duration(seconds: 10),
    this.indoorAccuracyHint = 20.0,
    this.moveThreshold = 20.0,
    this.resetThreshold = 50.0,
    this.softUnlockDebounceSamples = 2,
    this.outlierMinSamples = 4,
    this.outlierMadFactor = 3.0,
    this.outlierMinThreshold = 5.0,
    this.minGnssSatellitesUsed = 6,
    this.minGnssAvgCn0DbHz = 22.0,
    this.maxHdop = 6.0,
    this.maxPdop = 8.0,
    this.maxPlausibleSpeedMps = 55.0, // ~198 km/h, generi utk motor/mobil
    this.spoofDopMismatchHdop = 8.0,
    this.spoofDopMismatchMaxAccuracy = 5.0,
    this.spoofIdenticalStreak = 3,
    this.spoofVelocityMismatchMps = 15.0,
    this.spoofClockDriftTolerance = const Duration(seconds: 2),
    this.maxPlausibleStationarySpeedMps = 3.0, // ~10.8 km/h, longgar utk jalan kaki bawa paket
    this.maxSpeedAccuracyForGate = 3.0,
    this.convergenceHistorySize = 5,
    this.convergenceMinSamples = 3,
    this.convergenceMaxDriftMeters = 4.0,
    this.convergenceMinTimeSpanMs = 900,
    this.timeoutGraceExtension = const Duration(seconds: 2),
  });
}

// ── Log Level ──────────────────────────────────────────────────
enum GpsLogLevel { none, error, info, debug }

// ── Confidence ─────────────────────────────────────────────────
enum PodConfidence {
  searching,
  poor,
  fair,
  good,
  excellent,
}

extension PodConfidenceLabel on PodConfidence {
  String get label {
    switch (this) {
      case PodConfidence.searching: return '🔍 Mencari…';
      case PodConfidence.poor:      return '📡 Sinyal Lemah';
      case PodConfidence.fair:      return '⚡ Stabilisasi…';
      case PodConfidence.good:      return '✅ Siap Foto';
      case PodConfidence.excellent: return '🎯 Terkunci';
    }
  }

  bool get canCapture => this == PodConfidence.good || this == PodConfidence.excellent;
  bool get isLocked => this == PodConfidence.excellent;
}

// ── Sample ─────────────────────────────────────────────────────
class PodSample {
  final double lat;
  final double lon;
  final double accuracy;
  final int timestampMs;

  // ── GNSS quality (BARU, opsional) ────────────────────────────
  // null jika platform tidak mendukung (iOS) atau native side belum
  // sempat kirim data GNSS untuk sample ini. Saat null, sample ini
  // TIDAK ikut menyaring (gate dianggap lolos) — sistem fallback
  // penuh ke logika accuracy-only lama.
  final int? gnssSatellitesUsed;
  final double? gnssAvgCn0DbHz;

  // ── Dilution of Precision (BARU, opsional, dari NMEA GSA) ────
  final double? hdop;
  final double? pdop;

  // ── Velocity (BARU, opsional, dari Position.speed/speedAccuracy) ──
  // null jika speedAccuracy dari OS <= 0 (indikasi provider tidak
  // mendukung/tidak melaporkan kecepatan Doppler untuk fix ini) —
  // dikonversi jadi null di processSample(), bukan disimpan 0 mentah.
  final double? speed;
  final double? speedAccuracy;

  // ── Jam monotonic (BARU, review GPS mendalam #2, opsional) ──────
  // Dari SystemClock.elapsedRealtimeNanos() native (Android saja, via
  // FusedLocationStreamHandler.kt) — TIDAK BISA diubah user lewat
  // Setting > Tanggal & Waktu, beda dari [timestampMs] (wall-clock)
  // yang bisa. null di iOS / getLastLocation() cache / geolocator
  // fallback path — heuristik terkait otomatis fallback ke wall-clock
  // (perilaku lama, tidak ada regresi untuk platform yang tidak
  // mendukungnya).
  final int? elapsedRealtimeNanos;

  const PodSample({
    required this.lat,
    required this.lon,
    required this.accuracy,
    required this.timestampMs,
    this.gnssSatellitesUsed,
    this.gnssAvgCn0DbHz,
    this.hdop,
    this.pdop,
    this.speed,
    this.speedAccuracy,
    this.elapsedRealtimeNanos,
  });

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(timestampMs);

  bool get hasGnssData =>
      gnssSatellitesUsed != null && gnssAvgCn0DbHz != null;

  bool get hasDopData => hdop != null || pdop != null;

  /// true jika speed dari OS cukup dipercaya untuk dipakai gating
  /// (speedAccuracy tersedia & di bawah ambang [GpsConfig.maxSpeedAccuracyForGate]).
  bool hasReliableSpeed(GpsConfig config) =>
      speed != null &&
      speedAccuracy != null &&
      speedAccuracy! <= config.maxSpeedAccuracyForGate;

  /// Lolos gate jika: speed tidak dipercaya/tidak tersedia (tidak
  /// digating, fallback aman), ATAU device dianggap diam (speed di
  /// bawah [GpsConfig.maxPlausibleStationarySpeedMps]).
  bool passesVelocityGate(GpsConfig config) {
    if (!hasReliableSpeed(config)) return true;
    return speed! <= config.maxPlausibleStationarySpeedMps;
  }

  /// Lolos gate jika: tidak ada data GNSS (tidak digating), ATAU
  /// jumlah satelit & C/N0 memenuhi ambang minimum DAN (kalau ada)
  /// HDOP/PDOP masih di bawah ambang geometri satelit yang wajar.
  bool passesGnssGate(GpsConfig config) {
    final sats = gnssSatellitesUsed;
    final cn0 = gnssAvgCn0DbHz;
    if (sats == null || cn0 == null) return true;
    final satOk = sats >= config.minGnssSatellitesUsed &&
        cn0 >= config.minGnssAvgCn0DbHz;
    if (!satOk) return false;

    final h = hdop;
    final p = pdop;
    if (h != null && h > config.maxHdop) return false;
    if (p != null && p > config.maxPdop) return false;
    return true;
  }

  @override
  String toString() =>
      'PodSample(lat=$lat, lon=$lon, acc=${accuracy.toStringAsFixed(1)}m, '
      'time=$time, gnss=${hasGnssData ? "$gnssSatellitesUsed sat/"
          "${gnssAvgCn0DbHz!.toStringAsFixed(1)}dBHz" : "n/a"}, '
      'dop=${hasDopData ? "hdop=${hdop?.toStringAsFixed(1) ?? "-"}/"
          "pdop=${pdop?.toStringAsFixed(1) ?? "-"}" : "n/a"}, '
      'speed=${speed != null ? "${speed!.toStringAsFixed(1)}m/s" : "n/a"})';
}

// ── Lock Result ────────────────────────────────────────────────
class PodLockResult {
  final double centroidLat;
  final double centroidLon;
  final double accuracy;
  final double confidenceScore;
  final PodConfidence confidence;
  final PodSample bestRaw;
  final int samplesUsed;
  final double clusterStdDevMeters;
  final double clusterRadiusMeters;
  final int outliersRejected;
  final DateTime lockedAt;

  String get qualityLabel {
    if (confidence == PodConfidence.excellent) return 'Excellent';
    if (confidence == PodConfidence.good) return 'Good';
    if (confidence == PodConfidence.fair) return 'Fair';
    return 'Poor';
  }

  const PodLockResult({
    required this.centroidLat,
    required this.centroidLon,
    required this.accuracy,
    required this.confidenceScore,
    required this.confidence,
    required this.bestRaw,
    required this.samplesUsed,
    required this.clusterStdDevMeters,
    required this.clusterRadiusMeters,
    this.outliersRejected = 0,
    required this.lockedAt,
  });

  PodLockResult copyWith({
    double? accuracy,
    double? confidenceScore,
    PodConfidence? confidence,
    PodSample? bestRaw,
  }) =>
      PodLockResult(
        centroidLat: centroidLat,
        centroidLon: centroidLon,
        accuracy: accuracy ?? this.accuracy,
        confidenceScore: confidenceScore ?? this.confidenceScore,
        confidence: confidence ?? this.confidence,
        bestRaw: bestRaw ?? this.bestRaw,
        samplesUsed: samplesUsed,
        clusterStdDevMeters: clusterStdDevMeters,
        clusterRadiusMeters: clusterRadiusMeters,
        outliersRejected: outliersRejected,
        lockedAt: lockedAt,
      );
}

// ── Cluster stats (internal) ──────────────────────────────────
class _ClusterStats {
  final double centroidLat;
  final double centroidLon;
  final double avgAccuracy;
  final double stdDevMeters;
  final double radiusMeters;
  final PodSample best;

  const _ClusterStats({
    required this.centroidLat,
    required this.centroidLon,
    required this.avgAccuracy,
    required this.stdDevMeters,
    required this.radiusMeters,
    required this.best,
  });
}

// ── Centroid history point (internal, BARU) ───────────────────
/// Titik histori CENTROID (hasil agregat), bukan sample mentah —
/// dipakai untuk mengukur pergerakan ESTIMASI dari waktu ke waktu.
/// Lihat catatan Convergence-based lock di [GpsConfig].
class _CentroidPoint {
  final double lat;
  final double lon;
  final int timeMs;
  const _CentroidPoint(this.lat, this.lon, this.timeMs);
}

// ═══════════════════════════════════════════════════════════════
// PodGpsEngine
// ═══════════════════════════════════════════════════════════════
class PodGpsEngine {
  // ─── Distance Filter Constants ──────────────────────────────
  // ✅ CLEANUP: `distanceFilterLocked` (dulu 5.0) dihapus — dead code,
  // tidak pernah benar-benar dipakai. Begitu engine locked, PodLocationService
  // langsung _stopStream() total (lihat _onPosition), jadi tidak pernah ada
  // fase "streaming pasca-lock" untuk distanceFilter itu berlaku. Komentar
  // lama di header file ("distanceFilter: 0 saat acquiring, 5 setelah
  // locked") tidak akurat — sekarang cuma ada satu fase: acquiring, selalu
  // distanceFilter 0 (setiap update GPS diterima, tidak ada throttle jarak).
  static const double distanceFilterAcquiring = 0.0;

  final GpsConfig _config;
  GpsLogLevel _logLevel = kDebugMode ? GpsLogLevel.debug : GpsLogLevel.error;

  // ─── State ────────────────────────────────────────────────────
  /// FIFO — urutan waktu (TIDAK PERNAH DI-SORT)
  final List<PodSample> _window = [];

  /// Cache — sampel terbaik (tidak mempengaruhi FIFO)
  final List<PodSample> _bestSamples = [];

  PodLockResult? _lockResult;
  PodConfidence _confidence = PodConfidence.searching;
  Timer? _timeoutTimer;

  /// Timeout yang benar-benar dipakai untuk sesi akuisisi berjalan,
  /// hasil deteksi indoor/outdoor dari sample pertama. Direset ke
  /// [GpsConfig.outdoorTimeout] setiap [_hardReset] supaya lingkungan
  /// dideteksi ulang dari nol (mis. user pindah dari luar ke gudang).
  late Duration _activeTimeout;
  Duration get activeTimeout => _activeTimeout;

  /// Klasifikasi lingkungan SESI (dipakai untuk durasi timeout) —
  /// dideteksi SEKALI dari sample pertama, tidak berubah lagi sampai
  /// [_hardReset]. Beda dengan [isIndoorNow] yang dinamis per-sample.
  bool get isIndoorDetected => _activeTimeout == _config.indoorTimeout;

  /// Threshold admisi sample (gate accuracy) yang aktif SAAT INI —
  /// ⭐ BARU: dievaluasi ulang di setiap sample (lihat processSample),
  /// bukan dibekukan dari sample pertama seperti [isIndoorDetected]/
  /// [_activeTimeout]. TIDAK mempengaruhi captureThreshold/
  /// excellentThreshold.
  late double _activeAccuracyThreshold;
  double get activeAccuracyThreshold => _activeAccuracyThreshold;

  /// Klasifikasi lingkungan TERKINI (dinamis, per-sample) yang
  /// menggerbang [_activeAccuracyThreshold]. UI bisa memakai ini untuk
  /// mencerminkan kondisi sekarang, berbeda dari [isIndoorDetected]
  /// yang tetap berdasar sample pertama sesi.
  bool get isIndoorNow =>
      _activeAccuracyThreshold == _config.indoorAccuracyThreshold;

  double _lastLat = 0, _lastLon = 0;
  int? _lastSampleTimeMs;
  int? _lastElapsedRealtimeNanos;
  bool _posInit = false;
  bool _locked = false;
  bool _isFallbackLock = false;

  /// 🔥 FIX: Fast-path (lihat _evaluate) mestinya cuma berlaku untuk
  /// LOCK PERTAMA DALAM SATU SESI, bukan "setiap kali _locked sedang
  /// false". Sebelum fix ini, fast-path dicek pakai `!_locked`
  /// LANGSUNG SETELAH `_softUnlock()` men-set `_locked = false` di
  /// pemanggilan `processSample` YANG SAMA (lihat blok "Cek pergerakan"
  /// di atas _window.add) — akibatnya sample penyebab soft-unlock itu
  /// sendiri (kalau kebetulan akurasinya <= fastPathAccuracy) langsung
  /// me-relock jadi "excellent" lagi PADA EVALUASI YANG SAMA, membuat
  /// debounce soft-unlock terasa jalan tapi confidence tidak pernah
  /// benar-benar sempat turun (test "2 sample berturut-turut menyimpang
  /// ... memicu soft-unlock" gagal karena isLocked tetap true & confidence
  /// tetap excellent). Flag ini HANYA di-set true saat lock pertama kali
  /// terjadi (fast-path atau jalur normal/quick-lock), dan HANYA
  /// direset oleh hard reset / reset penuh sesi — TIDAK oleh soft-unlock.
  bool _hasLockedThisSession = false;

  /// Hitung sample BERTURUT-TURUT yang geser >= moveThreshold (tapi <
  /// resetThreshold) — dipakai debounce soft-unlock (BARU, saran
  /// performa #4). Reset ke 0 begitu sample "diam" lagi, atau begitu
  /// soft-unlock benar-benar terpicu.
  int _moveExceedStreak = 0;

  /// true jika native side pernah kirim data GNSS untuk window
  /// saat ini (dipakai UI untuk menampilkan info "menunggu sinyal
  /// GNSS lebih kuat" saat gate belum lolos).
  bool _gnssGateActive = false;
  bool get gnssGateActive => _gnssGateActive;

  /// true jika ada sample dengan speedAccuracy dipercaya di window
  /// DAN confidence belum tembus good/excellent karena device masih
  /// terdeteksi bergerak (bukan karena accuracy/GNSS). UI bisa pakai
  /// ini untuk pesan "berhenti dulu untuk mengunci lokasi".
  bool _velocityGateActive = false;
  bool get velocityGateActive => _velocityGateActive;

  /// Latch — sekali true, tetap true sampai [_hardReset] (pindah lokasi
  /// jauh) atau [reset] manual. Mencegah flicker UI kalau cuma 1 sample
  /// aneh di tengah rangkaian sample yang sah.
  bool _spoofSuspected = false;
  bool get spoofSuspected => _spoofSuspected;

  /// Alasan (untuk log/debug) kenapa sample terakhir dianggap
  /// mencurigakan. Kosong kalau [spoofSuspected] false.
  final List<String> _spoofReasons = [];
  List<String> get spoofReasons => List.unmodifiable(_spoofReasons);

  // ─── Convergence tracking (BARU) ───────────────────────────────
  /// Histori centroid, dicatat tiap [_evaluate]/[_forceLock] — dipakai
  /// oleh [_isConverged]/[_isTrendingTowardConvergence]. Beda dari
  /// [_window] (sample mentah individual): ini histori hasil AGREGAT
  /// (centroid) dari waktu ke waktu, mengukur pergerakan ESTIMASI,
  /// bukan sebaran sample dalam satu snapshot.
  final List<_CentroidPoint> _centroidHistory = [];

  /// true jika histori centroid menunjukkan estimasi sudah berhenti
  /// bergeser signifikan antar-evaluasi — lihat GpsConfig.
  bool get isConverged => _isConverged;
  bool _isConverged = false;

  /// Jarak (meter) terjauh antar-pasangan centroid dalam histori
  /// convergence saat ini — null kalau histori belum cukup panjang/
  /// belum cukup rentang waktu untuk dinilai.
  double? get convergenceDriftMeters => _convergenceDriftMeters;
  double? _convergenceDriftMeters;

  /// Latch — perpanjangan grace timeout (lihat
  /// [GpsConfig.timeoutGraceExtension]) hanya diberikan SATU kali per
  /// sesi akuisisi, tidak berulang.
  bool _graceExtensionUsed = false;

  // ─── Constructor ──────────────────────────────────────────────
  PodGpsEngine({GpsConfig? config}) : _config = config ?? const GpsConfig() {
    _activeTimeout = _config.outdoorTimeout;
    _activeAccuracyThreshold = _config.outdoorAccuracyThreshold;
  }

  // ─── Public getters ──────────────────────────────────────────
  PodConfidence get confidence => _confidence;
  PodLockResult? get lockResult => _lockResult;
  bool get canCapture => _confidence.canCapture;
  bool get isLocked => _locked;
  bool get isFallbackLock => _isFallbackLock;
  int get sampleCount => _window.length;
  int get samplesNeeded => _config.quickLockSamples;

  /// Finalisasi sample terbaik yang sudah ada saat deadline service habis.
  /// Window hanya berisi sample GPS live (OS lastKnownPosition tidak pernah
  /// di-processSample, lihat pod_location_service.dart), jadi hasil ini
  /// selalu berbasis data live meski dipaksa oleh deadline.
  bool forceLockIfPossible() {
    if (_locked) return true;
    if (_window.isEmpty) return false;
    _forceLock();
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    return true;
  }

  double get lockProgress {
    if (_window.isEmpty) return 0.0;
    return (_window.length / _config.quickLockSamples).clamp(0.0, 1.0);
  }

  // ─── Logging ──────────────────────────────────────────────────
  void setLogLevel(GpsLogLevel level) => _logLevel = level;

  void _log(String msg, {GpsLogLevel level = GpsLogLevel.info}) {
    if (level.index <= _logLevel.index) {
      debugPrint('PodGpsEngine: $msg');
    }
  }

  // ─── Proses satu sample dari OS ──────────────────────────────
  /// [gnssSatellitesUsed]/[gnssAvgCn0DbHz]/[hdop]/[pdop]: hasil
  /// GnssQualitySample terbaru (jika ada dan cukup baru) untuk sample
  /// posisi ini. Biarkan null bila platform tidak mendukung (iOS) atau
  /// data GNSS terlalu basi untuk dipasangkan dengan sample ini.
  bool processSample(
    Position raw, {
    int? gnssSatellitesUsed,
    double? gnssAvgCn0DbHz,
    double? hdop,
    double? pdop,
    // 🔥 BARU (review GPS mendalam #2): jam monotonic dari native
    // Android bridge (SystemClock.elapsedRealtimeNanos) — lihat
    // NativeFusedPosition.elapsedRealtimeNanos & PodSample untuk
    // kenapa ini penting untuk integritas timestamp. null di jalur
    // geolocator/iOS — heuristik terkait fallback otomatis ke
    // wall-clock (perilaku lama).
    int? elapsedRealtimeNanos,
  }) {
    // Mock GPS (flag eksplisit dari OS) → tolak
    if (raw.isMocked) {
      _flagSpoof(['OS melaporkan isMocked=true']);
      _log('mock GPS terdeteksi (isMocked), skip', level: GpsLogLevel.info);
      return false;
    }

    // Heuristik dasar: akurasi 0.0 mencurigakan (spoofed)
    if (raw.accuracy <= 0.0) {
      _flagSpoof(['akurasi=0 (mustahil untuk fix asli)']);
      _log('akurasi=0 mencurigakan (kemungkinan spoofed), skip', level: GpsLogLevel.info);
      return false;
    }

    final sample = PodSample(
      lat: raw.latitude,
      lon: raw.longitude,
      accuracy: raw.accuracy,
      timestampMs: raw.timestamp.millisecondsSinceEpoch,
      gnssSatellitesUsed: gnssSatellitesUsed,
      gnssAvgCn0DbHz: gnssAvgCn0DbHz,
      hdop: hdop,
      pdop: pdop,
      // speedAccuracy<=0 dianggap "provider tidak melaporkan speed
      // Doppler" (bukan bacaan valid) — simpan null, bukan 0 mentah,
      // supaya hasReliableSpeed()/gate otomatis skip (fallback aman).
      speed: raw.speedAccuracy > 0 ? raw.speed : null,
      speedAccuracy: raw.speedAccuracy > 0 ? raw.speedAccuracy : null,
      elapsedRealtimeNanos: elapsedRealtimeNanos,
    );

    // ── Deteksi spoofing lanjutan (BARU) ────────────────────────
    // Dijalankan SEBELUM filter accuracyThreshold karena fix palsu
    // sering justru melaporkan accuracy yang "bagus" — kalau dicek
    // setelah filter, sample seperti itu malah lolos begitu saja.
    final spoofReasons = _evaluateSpoofHeuristics(sample);
    if (spoofReasons.isNotEmpty) {
      _flagSpoof(spoofReasons);
      _log('spoofing dicurigai: ${spoofReasons.join("; ")}, skip', level: GpsLogLevel.info);
      return false;
    }

    // Deteksi lingkungan (indoor/outdoor) dilakukan SEBELUM filter
    // accuracyThreshold. Ini penting: kalau deteksi dilakukan setelah
    // filter (seperti timeout dulu), sample indoor yang accuracy-nya
    // 30-40m akan selalu ditolak duluan oleh asumsi threshold outdoor
    // (25m) sebelum sempat terdeteksi sebagai indoor — deadlock, gate
    // tidak pernah melonggar.
    //
    // Durasi timeout sesi HANYA dideteksi sekali dari sample pertama —
    // deadline yang terus bergerak (di-reset tiap sample) akan membuat
    // sesi akuisisi bisa molor tanpa batas kalau lingkungan "indoor"
    // terdeteksi berulang. Timer tetap fixed dari titik ini.
    if (_timeoutTimer == null) {
      final indoorAtStart = _looksIndoor(sample);
      _activeTimeout =
          indoorAtStart ? _config.indoorTimeout : _config.outdoorTimeout;
      _log(
        'timeout sesi terdeteksi ${indoorAtStart ? "INDOOR" : "OUTDOOR"} '
        '(gnss=${sample.hasGnssData}, acc=${sample.accuracy.toStringAsFixed(1)}m) '
        '→ timeout=${_activeTimeout.inSeconds}s',
        level: GpsLogLevel.info,
      );
      _timeoutTimer = Timer(_activeTimeout, _onTimeout);
    }

    // ⭐ BARU: threshold admisi (gate accuracy) dievaluasi ULANG di
    // setiap sample — TIDAK dibekukan dari sample pertama seperti
    // sebelumnya. Ini memperbaiki kasus operator berpindah lingkungan
    // (indoor → outdoor atau sebaliknya) SEBELUM lock: dulu kalau
    // sample pertama kebetulan indoor (gate 40m), gate tetap longgar
    // 40m sepanjang sesi walau operator sudah keluar ke area terbuka
    // (mestinya balik ketat 25m) — begitu juga sebaliknya. Sekarang
    // gate selalu mengikuti klasifikasi sample TERKINI. Timeout/durasi
    // sesi tidak ikut berubah (lihat komentar di atas).
    final indoorNow = _looksIndoor(sample);
    _activeAccuracyThreshold = indoorNow
        ? _config.indoorAccuracyThreshold
        : _config.outdoorAccuracyThreshold;

    // Filter akurasi (threshold adaptif indoor/outdoor — lihat di atas.
    // TIDAK mempengaruhi captureThreshold/excellentThreshold, cuma
    // gate admisi window + tier "fair").
    if (raw.accuracy > _activeAccuracyThreshold) {
      _log(
        'acc=${raw.accuracy.toStringAsFixed(1)}m > ${_activeAccuracyThreshold.toStringAsFixed(0)}m, skip',
        level: GpsLogLevel.debug,
      );
      if (_confidence == PodConfidence.searching) _confidence = PodConfidence.poor;
      return false;
    }

    // Cek pergerakan
    if (_posInit) {
      final moved = _haversine(_lastLat, _lastLon, raw.latitude, raw.longitude);
      if (moved >= _config.resetThreshold) {
        // Lompatan besar — cukup jelas untuk direspons segera, tidak
        // perlu debounce (beda dengan soft-unlock di bawah).
        _moveExceedStreak = 0;
        _hardReset();
        _log('hard reset, moved ${moved.toStringAsFixed(1)}m', level: GpsLogLevel.info);
      } else if (moved >= _config.moveThreshold && _locked) {
        // ⭐ BARU (saran performa #4): debounce — butuh
        // softUnlockDebounceSamples (default 2) sample BERTURUT-TURUT
        // yang sama-sama melebihi moveThreshold sebelum benar-benar
        // soft-unlock. Noise/multipath sesaat (1 sample menyimpang
        // lalu balik normal) tersaring di sini tanpa bikin confidence
        // flicker; pergerakan asli tetap terdeteksi, cuma mundur 1
        // sample dari sebelumnya.
        _moveExceedStreak++;
        if (_moveExceedStreak >= _config.softUnlockDebounceSamples) {
          _softUnlock();
          _log(
            'soft unlock (debounced, streak=$_moveExceedStreak), '
            'moved ${moved.toStringAsFixed(1)}m',
            level: GpsLogLevel.info,
          );
          _moveExceedStreak = 0;
        } else {
          _log(
            'pergerakan ${moved.toStringAsFixed(1)}m terdeteksi, belum '
            'debounce (streak=$_moveExceedStreak/${_config.softUnlockDebounceSamples})',
            level: GpsLogLevel.debug,
          );
        }
      } else {
        // Sample ini "diam" lagi (atau belum locked) — putus streak
        // supaya 2 penyimpangan yang TIDAK berturut-turut tidak
        // dianggap debounce lolos.
        _moveExceedStreak = 0;
      }
    }

    _lastLat = raw.latitude;
    _lastLon = raw.longitude;
    _lastSampleTimeMs = raw.timestamp.millisecondsSinceEpoch;
    _lastElapsedRealtimeNanos = elapsedRealtimeNanos;
    _posInit = true;

    // Tambah ke window (FIFO: selalu tambah di akhir) — pakai `sample`
    // yang sudah dibangun di atas untuk cek spoofing, tidak dibangun ulang.
    _window.add(sample);
    if (_window.length > _config.maxWindow) _window.removeAt(0);

    // Update best samples cache (insertion sort)
    _updateBestSamples(sample);

    // Evaluasi
    _evaluate();

    // 🔥 FIX: Return value merepresentasikan "sample ini DITERIMA masuk
    // window" (tidak ditolak oleh gate accuracy/spoofing di atas) — BUKAN
    // "confidence tier naik dibanding sebelumnya". Semantik lama
    // (`_confidence.index > prev.index`) salah: begitu tier sudah di
    // puncak (excellent) atau ketika fast-path (lock sample pertama)
    // membuat tier normal berikutnya sempat turun (mis. excellent → good
    // sebelum n cukup untuk tier normal), sample yang sebenarnya sah
    // masuk window malah dilaporkan `false` — padahal semua pemanggil lain
    // (lihat kode di atas: return false untuk isMocked/accuracy=0/spoof/
    // accuracyThreshold) sudah konsisten memakai `false` HANYA untuk
    // sample yang ditolak. Sample yang sampai baris ini sudah lolos semua
    // gate itu dan sudah ditambahkan ke _window — jadi selalu `true`.
    return true;
  }

  void _flagSpoof(List<String> reasons) {
    _spoofSuspected = true;
    _spoofReasons
      ..clear()
      ..addAll(reasons);
  }

  // ─── Deteksi spoofing lanjutan ────────────────────────────────
  /// Mengembalikan daftar alasan (kosong = tidak mencurigakan). Semua
  /// cek di sini independen dari `raw.isMocked`/accuracy=0 (yang sudah
  /// ditangani terpisah di [processSample]) — tujuannya menangkap
  /// aplikasi fake-GPS yang TIDAK men-set flag isMocked (umum di
  /// aplikasi mod/Xposed) dengan sinyal lain yang lebih sulit dipalsu
  /// bersamaan:
  ///   1. Kecepatan implisit antar-sample mustahil (teleport)
  ///   2. Timestamp mundur dari sample terakhir (jam dimanipulasi)
  ///   3. GNSS lapor 0 satelit dipakai tapi tetap ada fix (mustahil
  ///      untuk fix GPS asli — indikasi lokasi disuntik dari luar GNSS)
  ///   4. Accuracy sangat bagus tapi HDOP sangat buruk (tidak konsisten
  ///      secara fisik — accuracy asli berkorelasi dengan geometri satelit)
  ///   5. N sample terakhir di window punya lat/lon/accuracy identik
  ///      persis (GPS asli selalu ada jitter kecil; replay statis)
  List<String> _evaluateSpoofHeuristics(PodSample sample) {
    final reasons = <String>[];

    // (1) & (2): butuh sample sebelumnya sebagai baseline. impliedSpeed
    // (dari delta posisi) juga dipakai ulang di (6) di bawah.
    //
    // 🔥 BARU (review GPS mendalam #2): elapsedSec untuk kecepatan
    // implisit SEKARANG diutamakan dari delta jam MONOTONIC
    // (elapsedRealtimeNanos, native Android, tidak bisa diubah user)
    // kalau kedua sample (sebelumnya & sekarang) punya data itu — baru
    // fallback ke delta wall-clock (timestampMs) kalau tidak tersedia
    // (iOS, jalur geolocator, atau sample cache). Wall-clock TETAP
    // dipakai murni untuk cek "timestamp mundur" di bawah (itu justru
    // sinyal manipulasi jam yang valid), tapi tidak lagi jadi dasar
    // perhitungan kecepatan/waktu — supaya resync NTP kecil atau ganti
    // zona waktu tidak salah men-trigger heuristik #1/#6, dan supaya
    // user yang sengaja mengubah jam device tidak bisa menyamarkan
    // kecepatan implisit dengan memanipulasi delta waktu yang dipakai
    // untuk menghitungnya.
    double? impliedSpeed;
    final lastMs = _lastSampleTimeMs;
    final lastNanos = _lastElapsedRealtimeNanos;
    final curNanos = sample.elapsedRealtimeNanos;
    if (_posInit && lastMs != null) {
      final deltaMs = sample.timestampMs - lastMs;

      if (deltaMs < 0) {
        reasons.add('timestamp mundur ${-deltaMs}ms dari sample terakhir');
      }

      final monotonicAvailable = lastNanos != null && curNanos != null;
      final deltaMonotonicMs =
          monotonicAvailable ? (curNanos - lastNanos) / 1e6 : null;

      // Pakai monotonic kalau ada & positif (delta monotonic negatif
      // praktis mustahil kecuali reboot device di tengah sesi — di
      // luar cakupan heuristik ini, biarkan fallback wall-clock).
      final effectiveDeltaMs = (deltaMonotonicMs != null && deltaMonotonicMs > 0)
          ? deltaMonotonicMs
          : (deltaMs > 0 ? deltaMs.toDouble() : null);

      if (effectiveDeltaMs != null) {
        final elapsedSec = effectiveDeltaMs / 1000.0;
        final distance = _haversine(_lastLat, _lastLon, sample.lat, sample.lon);
        impliedSpeed = distance / elapsedSec;
        if (impliedSpeed > _config.maxPlausibleSpeedMps) {
          reasons.add(
            'kecepatan implisit ${impliedSpeed.toStringAsFixed(1)}m/s '
            '(${distance.toStringAsFixed(0)}m dalam ${elapsedSec.toStringAsFixed(1)}s) '
            'melebihi batas wajar ${_config.maxPlausibleSpeedMps}m/s',
          );
        }
      }

      // (7) BARU: Clock drift — wall-clock vs monotonic tidak sinkron.
      // Kalau device baru saja di-reboot di tengah sesi, delta
      // monotonic bisa negatif/tidak masuk akal — kasus itu SENGAJA
      // tidak dievaluasi di sini (di luar cakupan; sesi akuisisi POD
      // berlangsung singkat, reboot di tengahnya sudah anomali
      // tersendiri yang lebih baik ditangani lewat hard-reset sesi,
      // bukan flag spoofing).
      if (deltaMonotonicMs != null && deltaMonotonicMs > 0 && deltaMs > 0) {
        final driftMs = (deltaMs - deltaMonotonicMs).abs();
        if (driftMs > _config.spoofClockDriftTolerance.inMilliseconds) {
          reasons.add(
            'jam sistem bergeser ${(driftMs / 1000).toStringAsFixed(1)}s '
            'dibanding jam monotonic device antar-sample — indikasi jam '
            'diubah manual',
          );
        }
      }
    }

    // (3) GNSS: 0 satelit dipakai tapi OS tetap kasih fix.
    if (sample.gnssSatellitesUsed != null && sample.gnssSatellitesUsed == 0) {
      reasons.add('GNSS lapor 0 satelit dipakai tapi OS tetap memberi fix');
    }

    // (4) Accuracy vs HDOP tidak konsisten.
    final hdop = sample.hdop;
    if (hdop != null &&
        hdop > _config.spoofDopMismatchHdop &&
        sample.accuracy < _config.spoofDopMismatchMaxAccuracy) {
      reasons.add(
        'accuracy=${sample.accuracy.toStringAsFixed(1)}m terlalu bagus '
        'untuk HDOP=${hdop.toStringAsFixed(1)} (geometri satelit buruk)',
      );
    }

    // (5) Streak fix identik persis (tidak ada jitter sama sekali).
    final streakNeeded = _config.spoofIdenticalStreak - 1;
    if (streakNeeded > 0 && _window.length >= streakNeeded) {
      final recent = _window.sublist(_window.length - streakNeeded);
      final allIdentical = recent.every((s) =>
          s.lat == sample.lat &&
          s.lon == sample.lon &&
          s.accuracy == sample.accuracy);
      if (allIdentical) {
        reasons.add(
          '${streakNeeded + 1} sample berturut-turut identik persis '
          '(lat/lon/accuracy) — tidak ada jitter GPS alami',
        );
      }
    }

    // (6) Velocity Filter — kecepatan Doppler (chip GPS) tidak cocok
    // dengan kecepatan implisit dari delta posisi. Fake-GPS berbasis
    // injeksi lat/lon umumnya tidak ikut mensimulasikan sinyal Doppler
    // yang konsisten (raw.speed sering diam/0 walau posisi "melompat").
    // Hanya dievaluasi kalau speedAccuracy dipercaya DAN ada baseline
    // impliedSpeed dari (1) di atas.
    if (impliedSpeed != null && sample.hasReliableSpeed(_config)) {
      final mismatch = (impliedSpeed - sample.speed!).abs();
      if (mismatch > _config.spoofVelocityMismatchMps) {
        reasons.add(
          'kecepatan Doppler (${sample.speed!.toStringAsFixed(1)}m/s) tidak '
          'cocok dengan kecepatan implisit posisi '
          '(${impliedSpeed.toStringAsFixed(1)}m/s), selisih '
          '${mismatch.toStringAsFixed(1)}m/s',
        );
      }
    }

    return reasons;
  }

  // ─── Deteksi indoor/outdoor (dari sample pertama saja) ───────
  /// true → indoor (timeout diperpanjang), false → outdoor (timeout
  /// dipersingkat, lock cepat). Prioritas ke data GNSS native
  /// (lebih akurat, tidak tertipu accuracy yang "terlihat wajar"
  /// padahal multipath). Kalau GNSS tidak tersedia (iOS, atau
  /// Android belum sempat terima callback pertama), fallback ke
  /// accuracy mentah dari OS.
  bool _looksIndoor(PodSample sample) {
    if (sample.hasGnssData) {
      final weakSats = sample.gnssSatellitesUsed! < _config.minGnssSatellitesUsed;
      final weakSignal = sample.gnssAvgCn0DbHz! < _config.minGnssAvgCn0DbHz;
      return weakSats || weakSignal;
    }
    return sample.accuracy > _config.indoorAccuracyHint;
  }

  // ─── Update Best Samples Cache (Insertion Sort) ──────────────
  /// 🔥 OPTIMASI: Insertion sort — O(n) untuk list kecil
  /// Tidak perlu sort seluruh list setiap kali
  void _updateBestSamples(PodSample sample) {
    // Insertion sort: masukkan di posisi yang benar (ascending accuracy)
    int insertIndex = 0;
    while (insertIndex < _bestSamples.length &&
        _bestSamples[insertIndex].accuracy < sample.accuracy) {
      insertIndex++;
    }
    _bestSamples.insert(insertIndex, sample);

    // Keep only targetSamples (terbaik)
    if (_bestSamples.length > _config.targetSamples) {
      _bestSamples.removeLast();
    }
  }

  // ─── Timeout handler ─────────────────────────────────────────
  void _onTimeout() {
    if (_locked) return;

    if (_window.isNotEmpty) {
      // ⭐ BARU: kalau cluster masih terlihat TRENDING menuju konvergen
      // tepat saat timeout jatuh, beri satu kali perpanjangan singkat
      // alih-alih langsung memotong dengan force-lock — lihat
      // GpsConfig.timeoutGraceExtension.
      if (!_graceExtensionUsed && _isTrendingTowardConvergence()) {
        _graceExtensionUsed = true;
        _log(
          'timeout tercapai tapi cluster masih trending konvergen '
          '(drift=${_convergenceDriftMeters?.toStringAsFixed(1) ?? "-"}m) — '
          'beri grace ${_config.timeoutGraceExtension.inSeconds}s',
          level: GpsLogLevel.info,
        );
        _timeoutTimer = Timer(_config.timeoutGraceExtension, _onTimeout);
        return;
      }
      _log('timeout — force accept ${_window.length} samples', level: GpsLogLevel.info);
      _forceLock();
    } else {
      _confidence = PodConfidence.poor;
      _log('timeout — no samples', level: GpsLogLevel.info);
    }
  }

  // ─── Force Lock (timeout fallback) ──────────────────────────
  /// 🔥 FIX: Tidak mengubah urutan _window (FIFO tetap terjaga).
  ///        Sort dilakukan pada SALINAN (byAccuracy), bukan _window langsung.
  ///
  /// ✅ FIX CONFIDENCE INTEGRITY: sebelumnya tier selalu di-set "good"
  /// dan confidenceScore selalu konstanta 0.6, TANPA PEDULI akurasi
  /// cluster yang sebenarnya — fallback dari 8m accuracy (nyaris lock
  /// asli) dan fallback dari 80m accuracy (indoor parah) dilaporkan
  /// PERSIS SAMA ke konsumen (badge, watermark, log). Tier "good"
  /// TETAP dipertahankan (bukan diturunkan) supaya operator tidak
  /// terjebak tidak bisa capture sama sekali setelah timeout — itu
  /// keputusan desain yang disengaja (lihat catatan GpsConfig di atas
  /// soal kenapa gate admisi indoor dilonggarkan). Yang diperbaiki
  /// hanya confidenceScore: sekarang dihitung dari _score() memakai
  /// stats cluster hasil outlier-rejection yang sama seperti jalur
  /// lock normal, supaya angkanya benar-benar mencerminkan kualitas
  /// sample, bukan angka tetap. Konsumen bisa memakai kombinasi
  /// `isFallbackLock` + `confidenceScore` untuk membedakan fallback
  /// bagus vs fallback darurat (lihat PodLocationService/badge UI).
  void _forceLock() {
    // Buat salinan untuk sorting berdasarkan akurasi
    // _window tetap FIFO (tidak tersentuh)
    final byAccuracy = List<PodSample>.from(_window)
      ..sort((a, b) => a.accuracy.compareTo(b.accuracy));

    final best = byAccuracy.first;
    final cleaned = _rejectOutliers(byAccuracy);
    final stats = _computeClusterStats(cleaned);
    // ⭐ Pakai timestamp SAMPLE terbaru di window (bukan wall-clock
    // DateTime.now()) — lihat catatan di _recordConvergence.
    _recordConvergence(stats, _window.last.timestampMs);

    _confidence = PodConfidence.good;
    _locked = true;
    _hasLockedThisSession = true;
    _isFallbackLock = true;
    final score = _score(cleaned, stats);
    _lockResult = _buildResult(
      score,
      stats,
      cleaned.length,
      _window.length - cleaned.length,
    );
    _log(
      'force lock acc=${best.accuracy.toStringAsFixed(1)}m '
      'avgAcc=${stats.avgAccuracy.toStringAsFixed(1)}m score=${score.toStringAsFixed(2)} [FALLBACK]',
      level: GpsLogLevel.info,
    );
  }

  // ─── Evaluasi confidence ─────────────────────────────────────
  void _evaluate() {
    if (_window.isEmpty) {
      _confidence = PodConfidence.searching;
      return;
    }

    final cleaned = _rejectOutliers(_window);
    final rejected = _window.length - cleaned.length;

    final stats = _computeClusterStats(cleaned);
    final avgAcc = stats.avgAccuracy;
    final stdDev = stats.stdDevMeters;
    final radius = stats.radiusMeters;
    final n = cleaned.length;

    // ⭐ BARU: catat centroid ke histori convergence SEBELUM keputusan
    // tier — supaya _isConverged yang dipakai di bawah selalu berbasis
    // histori TERKINI (termasuk evaluasi ini). Timestamp dipakai dari
    // SAMPLE terbaru di window (bukan wall-clock DateTime.now()) supaya
    // rentang waktu histori mencerminkan jarak waktu ANTAR-FIX GPS yang
    // sebenarnya — konsisten baik saat sample mengalir real-time (di
    // mana keduanya kurang lebih sama) maupun saat diputar ulang/diuji
    // dengan timestamp sintetis (offline test, replay log, dsb).
    _recordConvergence(stats, _window.last.timestampMs);

    // ── GNSS gate (BARU) ──────────────────────────────────────
    // Hanya menyalakan syarat ini jika native side memang pernah
    // kirim data GNSS untuk window ini — kalau tidak (iOS, atau
    // Android yang belum sempat terima callback pertama), gate
    // dianggap lolos semua (fallback penuh ke logika lama).
    final gnssDataAvailable = cleaned.any((s) => s.hasGnssData);
    final gnssGatedCount =
        cleaned.where((s) => s.passesGnssGate(_config)).length;
    _gnssGateActive = gnssDataAvailable;
    final gnssOk = !gnssDataAvailable || gnssGatedCount >= _config.targetSamples;

    // ── Velocity gate (BARU) ───────────────────────────────────
    // Hanya menyala jika ada sample dengan speedAccuracy dipercaya
    // di window ini. Kalau tidak (device/provider tidak melaporkan
    // Doppler speed), gate lolos otomatis (fallback aman). Mencegah
    // tier good/excellent terkunci saat device masih benar-benar
    // bergerak (kurir belum berhenti) — lihat catatan Velocity
    // Filter di GpsConfig.
    final velocityDataAvailable = cleaned.any((s) => s.hasReliableSpeed(_config));
    final velocityGatedCount =
        cleaned.where((s) => s.passesVelocityGate(_config)).length;
    _velocityGateActive = velocityDataAvailable;
    final velocityOk =
        !velocityDataAvailable || velocityGatedCount >= _config.targetSamples;

    PodConfidence newConf;

    // ⚡ FAST PATH (BARU): shortcut, bukan pengganti algoritma normal.
    // Kalau sample yang ada SUDAH sangat akurat (<= fastPathAccuracy),
    // langsung lock sebagai excellent walau n masih di bawah
    // targetSamples dan belum sempat convergen — gate anti-spoof
    // (GNSS/velocity) tetap wajib lolos supaya shortcut ini tidak
    // membuka celah untuk fix yang dipalsukan.
    //
    // PENTING: hanya berlaku untuk LOCK PERTAMA DALAM SATU SESI (lihat
    // _hasLockedThisSession) — BUKAN sekadar "_locked sedang false saat
    // ini". Kalau dicek dari `_locked` mentah, sample yang BARU SAJA
    // memicu soft-unlock (yang men-set _locked=false sesaat sebelum
    // _evaluate() ini dipanggil, di pemanggilan processSample yang sama)
    // bisa langsung lolos fast-path dan me-relock "excellent" lagi kalau
    // akurasinya kebetulan bagus — padahal maksudnya soft-unlock harus
    // benar-benar melepas lock dulu, bukan cuma flicker sesaat. Dengan
    // flag sesi ini, fast-path betul-betul cuma jalan SEKALI (saat lock
    // pertama sebelum pernah locked sama sekali); setelah itu (termasuk
    // setelah soft-unlock) WAJIB lewat jalur normal di bawah — supaya
    // convergence gate (excellent) dan soft-unlock debounce tetap
    // berfungsi apa adanya dan tidak di-override ulang tiap kali ada
    // sample baru yang kebetulan akurat.
    if (!_hasLockedThisSession &&
        n >= 1 &&
        avgAcc <= _config.fastPathAccuracy &&
        gnssOk &&
        velocityOk) {
      newConf = PodConfidence.excellent;
      _locked = true;
      _hasLockedThisSession = true;
    } else if (n >= _config.targetSamples &&
        avgAcc <= _config.excellentThreshold &&
        stdDev <= _config.excellentMaxStdDev &&
        radius <= _config.excellentMaxRadius &&
        gnssOk &&
        velocityOk &&
        // ⭐ BARU: cluster harus KONVERGEN (stabil antar-evaluasi, bukan
        // cuma rapat di SATU snapshot) — lihat GpsConfig & _recordConvergence.
        _isConverged) {
      newConf = PodConfidence.excellent;
      _locked = true;
      _hasLockedThisSession = true;
    } else if (n >= _config.quickLockSamples &&
        avgAcc <= _config.captureThreshold) {
      // ⚡ QUICK LOCK (BARU): tier "good" sekarang HANYA mensyaratkan
      // jumlah sample (quickLockSamples=2, bukan 3) + rata-rata akurasi
      // di bawah captureThreshold — gate GNSS satelit/CN0/HDOP/PDOP dan
      // motion/velocity TIDAK lagi ikut memblokir tier ini (tetap aktif
      // penuh untuk "excellent" di atas). Rasionalnya: gate-gate itu
      // dirancang untuk menyaring presisi maksimal/anti-spoof lanjutan,
      // bukan syarat minimum "lokasi cukup layak dipakai" — menumpuknya
      // di depan tier dasar cuma bikin lock kerasa lambat tanpa manfaat
      // proporsional. Anti-spoof primer (raw.isMocked + 6 heuristik di
      // _evaluateSpoofHeuristics) tetap jalan penuh di processSample()
      // SEBELUM sample ini bahkan masuk window, jadi outlier/spoofing
      // tetap tersaring lebih dulu.
      newConf = PodConfidence.good;
      _locked = true;
      _hasLockedThisSession = true;
    } else if (n >= 1 && avgAcc <= _activeAccuracyThreshold) {
      // Tetap "fair" walau GNSS/velocity gate belum lolos — UI bisa
      // menampilkan status stabilisasi tanpa memblokir selamanya;
      // force-lock via timeout tetap tersedia sebagai fallback
      // (lihat _forceLock).
      newConf = PodConfidence.fair;
    } else {
      newConf = PodConfidence.poor;
    }

    _confidence = newConf;

    if (_confidence.canCapture || _window.isNotEmpty) {
      _lockResult = _buildResult(
        _score(cleaned, stats),
        stats,
        cleaned.length,
        rejected,
      );
    }

    if (_locked) {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    }

    _log(
      '${_confidence.label} | '
      'n=$n (rejected=$rejected) avgAcc=${avgAcc.toStringAsFixed(1)}m '
      'stdDev=${stdDev.toStringAsFixed(1)}m radius=${radius.toStringAsFixed(1)}m locked=$_locked | '
      'gnss=${gnssDataAvailable ? "$gnssGatedCount/$n lolos gate" : "tidak ada data (n/a)"}',
      level: GpsLogLevel.debug,
    );
  }

  // ─── Convergence (BARU) ────────────────────────────────────────
  /// Catat centroid hasil evaluasi/force-lock TERKINI ke histori (FIFO,
  /// dibatasi [GpsConfig.convergenceHistorySize]) lalu evaluasi ulang
  /// [isConverged]/[convergenceDriftMeters].
  ///
  /// [sampleTimeMs] WAJIB berasal dari timestamp SAMPLE GPS terbaru
  /// yang dipakai pada evaluasi ini (mis. `_window.last.timestampMs`),
  /// BUKAN `DateTime.now()` — engine ini murni fungsi dari data yang
  /// diberikan lewat [processSample], tidak boleh diam-diam bergantung
  /// pada jam dinding proses yang menjalankannya. Kalau convergence
  /// dinilai dari wall-clock, engine yang diberi makan sample dengan
  /// timestamp historis/sintetis secara sinkron (unit test, replay log)
  /// akan SELALU gagal syarat rentang waktu (evaluasi berjalan dalam
  /// hitungan mikrodetik CPU, bukan detik GPS) walau sample-nya sendiri
  /// merepresentasikan rentang waktu yang cukup panjang.
  void _recordConvergence(_ClusterStats stats, int sampleTimeMs) {
    _centroidHistory.add(
      _CentroidPoint(stats.centroidLat, stats.centroidLon, sampleTimeMs),
    );
    if (_centroidHistory.length > _config.convergenceHistorySize) {
      _centroidHistory.removeAt(0);
    }

    if (_centroidHistory.length < _config.convergenceMinSamples) {
      _isConverged = false;
      _convergenceDriftMeters = null;
      return;
    }

    final oldest = _centroidHistory.first;
    final newest = _centroidHistory.last;
    final timeSpanMs = newest.timeMs - oldest.timeMs;

    // Bentang waktu histori harus cukup panjang — mencegah beberapa
    // sample yang datang beruntun dalam sepersekian detik (burst)
    // dianggap "konvergen" secara trivial hanya karena belum sempat
    // ada waktu untuk bergeser.
    if (timeSpanMs < _config.convergenceMinTimeSpanMs) {
      _isConverged = false;
      _convergenceDriftMeters = null;
      return;
    }

    // Drift = jarak maksimum ANTAR PASANGAN centroid dalam histori
    // (bukan cuma tertua↔terbaru) — menangkap kasus centroid yang
    // sempat menyimpang jauh di TENGAH histori lalu "kebetulan" balik
    // dekat ke titik awal (masih dianggap belum stabil).
    double maxDrift = 0;
    for (var i = 0; i < _centroidHistory.length; i++) {
      for (var j = i + 1; j < _centroidHistory.length; j++) {
        final d = _haversine(
          _centroidHistory[i].lat,
          _centroidHistory[i].lon,
          _centroidHistory[j].lat,
          _centroidHistory[j].lon,
        );
        if (d > maxDrift) maxDrift = d;
      }
    }

    _convergenceDriftMeters = maxDrift;
    _isConverged = maxDrift <= _config.convergenceMaxDriftMeters;
  }

  /// true jika drift 2 langkah histori terakhir mengecil (atau sudah
  /// cukup dekat) dibanding sebelumnya — dipakai [_onTimeout] untuk
  /// menentukan kelayakan grace extension. Butuh minimal 3 titik
  /// histori supaya menilai TREN, bukan cuma satu nilai sesaat.
  bool _isTrendingTowardConvergence() {
    if (_centroidHistory.length < 3) return false;
    final n = _centroidHistory.length;
    final a = _centroidHistory[n - 3];
    final b = _centroidHistory[n - 2];
    final c = _centroidHistory[n - 1];
    final distAB = _haversine(a.lat, a.lon, b.lat, b.lon);
    final distBC = _haversine(b.lat, b.lon, c.lat, c.lon);
    return distBC <= distAB || distBC <= _config.convergenceMaxDriftMeters * 1.5;
  }

  // ─── Build result ─────────────────────────────────────────────
  PodLockResult _buildResult(
    double score,
    _ClusterStats stats,
    int usedSamples,
    int rejectedSamples,
  ) {
    return PodLockResult(
      centroidLat: stats.centroidLat,
      centroidLon: stats.centroidLon,
      accuracy: stats.avgAccuracy,
      confidenceScore: score,
      confidence: _confidence,
      bestRaw: stats.best,
      samplesUsed: usedSamples,
      clusterStdDevMeters: stats.stdDevMeters,
      clusterRadiusMeters: stats.radiusMeters,
      outliersRejected: rejectedSamples,
      lockedAt: DateTime.now(),
    );
  }

  // ─── Outlier rejection (MAD-based) ───────────────────────────
  List<PodSample> _rejectOutliers(List<PodSample> input) {
    if (input.length < _config.outlierMinSamples) return input;

    final medLat = _median(input.map((s) => s.lat).toList());
    final medLon = _median(input.map((s) => s.lon).toList());

    final distances = input
        .map((s) => _haversine(medLat, medLon, s.lat, s.lon))
        .toList();

    final medDist = _median(distances);
    final mad = _median(distances.map((d) => (d - medDist).abs()).toList());
    final madScaled = mad * 1.4826;

    final threshold = max(
      medDist + _config.outlierMadFactor * madScaled,
      _config.outlierMinThreshold,
    );

    final filtered = <PodSample>[
      for (var i = 0; i < input.length; i++)
        if (distances[i] <= threshold) input[i],
    ];

    if (filtered.length < _config.targetSamples) return input;
    return filtered;
  }

  static double _median(List<double> values) {
    if (values.isEmpty) return 0.0;
    final sorted = List<double>.from(values)..sort();
    final n = sorted.length;
    final mid = n ~/ 2;
    if (n.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  // ─── Hitung centroid (weighted) ──────────────────────────────
  // ─── Bobot kualitas GNSS (BARU) ──────────────────────────────
  /// Mengubah kekuatan sinyal (satelit dipakai + C/N0) menjadi
  /// pengali bobot untuk centroid. Ini yang sebelumnya HILANG:
  /// gate lama cuma menahan label confidence, tidak pernah ikut
  /// menghitung ulang centroid — jadi lat/lon akhir tidak berubah
  /// sama sekali walau gate "aktif".
  ///
  /// Sample tanpa data GNSS (iOS / belum ada payload) → netral (1.0),
  /// tidak ikut mempengaruhi apa pun (fallback penuh ke logika lama).
  /// Sample dengan sinyal jauh di bawah ambang → bobotnya diperkecil
  /// signifikan (bukan nol, supaya window tidak pernah kosong total).
  /// Sample dengan sinyal jauh di atas ambang → bobotnya diperbesar,
  /// supaya fix yang benar-benar bersih lebih dominan di centroid.
  double _gnssQualityWeight(PodSample s) {
    if (!s.hasGnssData) return 1.0;
    final satRatio =
        (s.gnssSatellitesUsed! / _config.minGnssSatellitesUsed).clamp(0.15, 2.5);
    final cn0Ratio =
        (s.gnssAvgCn0DbHz! / _config.minGnssAvgCn0DbHz).clamp(0.15, 2.5);
    // Produk (bukan rata-rata) → sample yang lemah di DUA-DUANYA
    // (satelit sedikit DAN sinyal lemah, ciri khas multipath berat
    // di dalam gudang) turun tajam; harus kuat di keduanya untuk naik.
    return (satRatio * cn0Ratio).clamp(0.05, 4.0);
  }

  _ClusterStats _computeClusterStats(List<PodSample> samples) {
    if (samples.isEmpty) {
      return _ClusterStats(
        centroidLat: 0,
        centroidLon: 0,
        avgAccuracy: 0,
        stdDevMeters: 0,
        radiusMeters: 0,
        best: PodSample(lat: 0, lon: 0, accuracy: 0, timestampMs: 0),
      );
    }

    double sumLatW = 0, sumLonW = 0, sumW = 0;
    double sumAccW = 0;
    PodSample? best;

    for (final s in samples) {
      final clampedAcc = max(s.accuracy, 1.0);
      final w = (1.0 / (clampedAcc * clampedAcc)) * _gnssQualityWeight(s);
      sumLatW += s.lat * w;
      sumLonW += s.lon * w;
      sumW += w;
      sumAccW += s.accuracy * w;
      if (best == null || s.accuracy < best.accuracy) best = s;
    }

    // Safety: jika sumW == 0, gunakan rata-rata biasa
    if (sumW <= 0) {
      final avgLat = samples.map((s) => s.lat).reduce((a, b) => a + b) / samples.length;
      final avgLon = samples.map((s) => s.lon).reduce((a, b) => a + b) / samples.length;
      final avgAcc = samples.map((s) => s.accuracy).reduce((a, b) => a + b) / samples.length;

      return _ClusterStats(
        centroidLat: avgLat,
        centroidLon: avgLon,
        avgAccuracy: avgAcc,
        stdDevMeters: 0,
        radiusMeters: 0,
        best: best!,
      );
    }

    final cLat = sumLatW / sumW;
    final cLon = sumLonW / sumW;
    final avgAcc = sumAccW / sumW;

    double sumSq = 0, maxD = 0;
    for (final s in samples) {
      final d = _haversine(cLat, cLon, s.lat, s.lon);
      sumSq += d * d;
      if (d > maxD) maxD = d;
    }
    final stdDev = samples.length > 1 ? sqrt(sumSq / samples.length) : 0.0;

    return _ClusterStats(
      centroidLat: cLat,
      centroidLon: cLon,
      avgAccuracy: avgAcc,
      stdDevMeters: stdDev,
      radiusMeters: maxD,
      best: best!,
    );
  }

  // ─── Score 0–1 ───────────────────────────────────────────────
  double _score(List<PodSample> samples, _ClusterStats stats) {
    if (samples.isEmpty) return 0.0;

    final fSample = (samples.length / _config.targetSamples).clamp(0.0, 1.0);
    final fAcc = (1.0 - (stats.avgAccuracy / _activeAccuracyThreshold)).clamp(0.0, 1.0);

    final worstSpread = max(stats.stdDevMeters, stats.radiusMeters);
    final fSpread = (1.0 - (worstSpread / _activeAccuracyThreshold)).clamp(0.0, 1.0);

    final now = DateTime.now();
    final avgAgeSec = samples
            .map((s) => now.difference(s.time).inMilliseconds / 1000.0)
            .reduce((a, b) => a + b) /
        samples.length;
    final fFresh = (1.0 - (avgAgeSec / _activeTimeout.inSeconds)).clamp(0.0, 1.0);

    // ── Convergence factor (BARU) ─────────────────────────────────
    // Drift kecil (centroid stabil antar-evaluasi) → skor tinggi;
    // histori belum cukup panjang/belum cukup rentang waktu → skor
    // netral (0.5), bukan nol — supaya tidak menghukum lock yang sangat
    // cepat (mis. quick-lock "good") padahal faktor lain sudah bagus.
    final drift = _convergenceDriftMeters;
    final fConverge = drift == null
        ? 0.5
        : (1.0 - (drift / (_config.convergenceMaxDriftMeters * 2))).clamp(0.0, 1.0);

    return fAcc * 0.30 + fSpread * 0.20 + fSample * 0.15 + fFresh * 0.15 + fConverge * 0.20;
  }

  // ─── Soft unlock ─────────────────────────────────────────────
  void _softUnlock() {
    _locked = false;
    _isFallbackLock = false;
    _confidence = PodConfidence.fair;
    _lockResult = null;

    // 🔥 FIX: Sekarang aman karena _window tetap FIFO
    //        (tidak pernah di-sort langsung)
    while (_window.length > 3) _window.removeAt(0);

    // ⭐ BARU: histori convergence SENGAJA TIDAK dibersihkan di sini.
    // Soft-unlock dipicu oleh pergerakan RAW sample (moveThreshold),
    // termasuk kalau sample itu sendiri nanti ternyata outlier yang
    // dibuang oleh MAD-based rejection di _evaluate() — dalam kasus
    // itu centroid ROBUST sebenarnya tidak pernah bergeser sama
    // sekali, jadi memaksa histori kosong (butuh 3 evaluasi baru dari
    // nol) cuma memperlambat re-lock tanpa alasan yang valid.
    //
    // Membiarkan histori apa adanya justru lebih tepat: kalau
    // pergerakan ini SUNGGUHAN (bukan noise), evaluasi berikutnya akan
    // menghasilkan centroid yang BEDA JAUH dari histori lama →
    // convergenceMaxDriftMeters otomatis terlampaui → _isConverged
    // tetap false sampai histori lama tergusur (ring buffer,
    // convergenceHistorySize) oleh evaluasi-evaluasi baru yang stabil
    // di posisi BARU. Kalau ternyata cuma noise/outlier sesaat,
    // centroid robust tidak berubah → histori tetap konsisten → boleh
    // langsung re-lock "excellent" tanpa jeda buatan.
    //
    // Grace timeout TETAP direset supaya sesi re-lock ini punya
    // kesempatan grace baru.
    _graceExtensionUsed = false;

    // Pakai _activeTimeout (bukan re-deteksi) — soft unlock terjadi
    // karena pergerakan kecil, bukan pindah lingkungan drastis.
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_activeTimeout, _onTimeout);
  }

  // ─── Hard reset ──────────────────────────────────────────────
  void _hardReset() {
    _window.clear();
    _bestSamples.clear();
    _lockResult = null;
    _locked = false;
    _hasLockedThisSession = false;
    _isFallbackLock = false;
    _confidence = PodConfidence.searching;
    _posInit = false;
    _lastSampleTimeMs = null;
    _lastElapsedRealtimeNanos = null;
    _moveExceedStreak = 0;
    _gnssGateActive = false;
    _velocityGateActive = false;
    _spoofSuspected = false;
    _spoofReasons.clear();
    _centroidHistory.clear();
    _isConverged = false;
    _convergenceDriftMeters = null;
    _graceExtensionUsed = false;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _activeTimeout = _config.outdoorTimeout; // re-deteksi dari sample berikutnya
    _activeAccuracyThreshold = _config.outdoorAccuracyThreshold;
  }

  void reset() => _hardReset();

  void dispose() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _window.clear();
    _bestSamples.clear();
  }

  // ─── Status ──────────────────────────────────────────────────
  Map<String, dynamic> getStatus() {
    return {
      'confidence': _confidence.label,
      'confidenceLevel': _confidence.index,
      'canCapture': canCapture,
      'isLocked': _locked,
      'isFallback': _isFallbackLock,
      'gnssGateActive': _gnssGateActive,
      'velocityGateActive': _velocityGateActive,
      'sampleCount': _window.length,
      'samplesNeeded': _config.quickLockSamples,
      'progress': lockProgress,
      'environment': isIndoorDetected ? 'indoor' : 'outdoor',
      'environmentNow': isIndoorNow ? 'indoor' : 'outdoor',
      'timeoutSeconds': _activeTimeout.inSeconds,
      'accuracyThresholdMeters': _activeAccuracyThreshold,
      'spoofSuspected': _spoofSuspected,
      'spoofReasons': _spoofReasons,
      'converged': _isConverged,
      'convergenceDriftMeters': _convergenceDriftMeters,
      'lockResult': _lockResult != null
          ? {
              'accuracy': _lockResult!.accuracy,
              'score': _lockResult!.confidenceScore,
              'samplesUsed': _lockResult!.samplesUsed,
              'stdDev': _lockResult!.clusterStdDevMeters,
              'radius': _lockResult!.clusterRadiusMeters,
              'outliersRejected': _lockResult!.outliersRejected,
            }
          : null,
    };
  }

  // ─── Memory Management ──────────────────────────────────────
  /// 🔥 FIX: Sekarang menggunakan cache terpisah (_bestSamples)
  ///        _window tetap FIFO, tidak pernah dimodifikasi.
  void trimMemory() {
    // _window tetap utuh (FIFO) — tidak disentuh!
    // Kita hanya membersihkan cache _bestSamples jika terlalu besar
    if (_bestSamples.length > _config.targetSamples) {
      while (_bestSamples.length > _config.targetSamples) {
        _bestSamples.removeLast();
      }
    }

    _log(
      'trimMemory: window=${_window.length}, bestCache=${_bestSamples.length}',
      level: GpsLogLevel.debug,
    );
  }

  /// Mendapatkan sampel terbaik dari cache (tanpa mempengaruhi FIFO)
  List<PodSample> getBestSamples() {
    return List<PodSample>.from(_bestSamples);
  }

  // ─── Haversine ───────────────────────────────────────────────
  static double _haversine(double lat1, double lon1, double lat2, double lon2) =>
      haversinePublic(lat1, lon1, lat2, lon2);

  static double haversinePublic(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) *
            sin(dLon / 2) * sin(dLon / 2);
    return R * 2 * atan2(sqrt(a.clamp(0.0, 1.0)), sqrt(1.0 - a.clamp(0.0, 1.0)));
  }
}
