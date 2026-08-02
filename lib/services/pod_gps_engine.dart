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
//   timeout            : adaptif — 8 detik outdoor, 15 detik indoor
//                         (dideteksi dari sample pertama: GNSS sat/CN0
//                         kalau ada, fallback ke accuracy OS)
//   target samples     : 3 (fast lock), max 10 untuk refine
//   min sampel utk Excellent : 3
//   centroid           : weighted (bobot 1/accuracy²)
//   avgAccuracy        : weighted (bobot 1/accuracy²)
//   provider           : fused
//   startup            : lastKnownPosition (OS cache + SharedPrefs)
//   distanceFilter     : 0 saat acquiring, 5 setelah locked
//   mock GPS           : ditolak (raw.isMocked) + heuristik spoofing lanjutan (teleport speed,
//                         timestamp mundur, 0 satelit tapi ada fix,
//                         accuracy vs HDOP tidak konsisten, streak fix
//                         identik persis) — lihat _evaluateSpoofHeuristics
//   DOP                : HDOP/PDOP dari NMEA GSA (opsional, Android),
//                         ikut menyaring gate GNSS kalau tersedia
//   accuracy gate      : adaptif — 25m outdoor, 40m indoor (gate admisi
//                         window & tier "fair" saja; captureThreshold/
//                         excellentThreshold TETAP fixed, tidak ikut turun)
//   velocity filter    : raw.speed/speedAccuracy (Doppler, dari OS) —
//                         (a) motion gate: good/excellent tidak terkunci
//                         selama device masih bergerak (kurir belum
//                         berhenti); (b) heuristik spoofing #6: speed
//                         Doppler vs kecepatan implisit posisi mismatch
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
  final double excellentMaxStdDev;
  final double excellentMaxRadius;
  final int targetSamples;
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
  final double maxPlausibleSpeedMps;
  final double spoofDopMismatchHdop;
  final double spoofDopMismatchMaxAccuracy;
  final int spoofIdenticalStreak;
  final double spoofVelocityMismatchMps;

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

  const GpsConfig({
    this.outdoorAccuracyThreshold = 25.0,
    this.indoorAccuracyThreshold = 40.0,
    this.captureThreshold = 20.0,
    this.excellentThreshold = 10.0,
    this.excellentMaxStdDev = 8.0,
    this.excellentMaxRadius = 12.0,
    this.targetSamples = 3,
    this.maxWindow = 10,
    this.outdoorTimeout = const Duration(seconds: 8),
    this.indoorTimeout = const Duration(seconds: 15),
    this.indoorAccuracyHint = 20.0,
    this.moveThreshold = 20.0,
    this.resetThreshold = 50.0,
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
    this.maxPlausibleStationarySpeedMps = 3.0, // ~10.8 km/h, longgar utk jalan kaki bawa paket
    this.maxSpeedAccuracyForGate = 3.0,
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

// ═══════════════════════════════════════════════════════════════
// PodGpsEngine
// ═══════════════════════════════════════════════════════════════
class PodGpsEngine {
  // ─── Distance Filter Constants ──────────────────────────────
  static const double distanceFilterAcquiring = 0.0;
  static const double distanceFilterLocked = 5.0;

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
  bool get isIndoorDetected => _activeTimeout == _config.indoorTimeout;

  /// Threshold admisi sample yang aktif untuk sesi berjalan — hasil
  /// deteksi indoor/outdoor yang SAMA dengan [_activeTimeout] (satu
  /// deteksi lingkungan dipakai untuk keduanya, lihat _looksIndoor).
  /// TIDAK mempengaruhi captureThreshold/excellentThreshold.
  late double _activeAccuracyThreshold;
  double get activeAccuracyThreshold => _activeAccuracyThreshold;

  double _lastLat = 0, _lastLon = 0;
  int? _lastSampleTimeMs;
  bool _posInit = false;
  bool _locked = false;
  bool _isFallbackLock = false;

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
  int get samplesNeeded => _config.targetSamples;

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
    return (_window.length / _config.targetSamples).clamp(0.0, 1.0);
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

    // Deteksi lingkungan (indoor/outdoor) — dilakukan SEKALI dari
    // sample PERTAMA yang benar-benar masuk fungsi ini, SEBELUM filter
    // accuracyThreshold. Ini penting: kalau deteksi dilakukan setelah
    // filter (seperti timeout dulu), sample indoor yang accuracy-nya
    // 30-40m akan selalu ditolak duluan oleh asumsi threshold outdoor
    // (25m) sebelum sempat terdeteksi sebagai indoor — deadlock, gate
    // tidak pernah melonggar. Timer timeout juga ikut dimulai di sini
    // supaya sesi selalu punya batas waktu sejak callback GPS pertama,
    // bukan menunggu sample pertama yang "cukup akurat".
    if (_timeoutTimer == null) {
      final indoor = _looksIndoor(sample);
      _activeTimeout = indoor ? _config.indoorTimeout : _config.outdoorTimeout;
      _activeAccuracyThreshold = indoor
          ? _config.indoorAccuracyThreshold
          : _config.outdoorAccuracyThreshold;
      _log(
        'lingkungan terdeteksi ${indoor ? "INDOOR" : "OUTDOOR"} '
        '(gnss=${sample.hasGnssData}, acc=${sample.accuracy.toStringAsFixed(1)}m) '
        '→ timeout=${_activeTimeout.inSeconds}s, '
        'gate-admisi=${_activeAccuracyThreshold.toStringAsFixed(0)}m',
        level: GpsLogLevel.info,
      );
      _timeoutTimer = Timer(_activeTimeout, _onTimeout);
    }

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
        _hardReset();
        _log('hard reset, moved ${moved.toStringAsFixed(1)}m', level: GpsLogLevel.info);
      } else if (moved >= _config.moveThreshold && _locked) {
        _softUnlock();
        _log('soft unlock, moved ${moved.toStringAsFixed(1)}m', level: GpsLogLevel.info);
      }
    }

    _lastLat = raw.latitude;
    _lastLon = raw.longitude;
    _lastSampleTimeMs = raw.timestamp.millisecondsSinceEpoch;
    _posInit = true;

    // Tambah ke window (FIFO: selalu tambah di akhir) — pakai `sample`
    // yang sudah dibangun di atas untuk cek spoofing, tidak dibangun ulang.
    _window.add(sample);
    if (_window.length > _config.maxWindow) _window.removeAt(0);

    // Update best samples cache (insertion sort)
    _updateBestSamples(sample);

    // Evaluasi
    final prev = _confidence;
    _evaluate();
    return _confidence.index > prev.index;
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
    double? impliedSpeed;
    final lastMs = _lastSampleTimeMs;
    if (_posInit && lastMs != null) {
      final deltaMs = sample.timestampMs - lastMs;

      if (deltaMs < 0) {
        reasons.add('timestamp mundur ${-deltaMs}ms dari sample terakhir');
      } else if (deltaMs > 0) {
        final elapsedSec = deltaMs / 1000.0;
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

    _confidence = PodConfidence.good;
    _locked = true;
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

    if (n >= _config.targetSamples &&
        avgAcc <= _config.excellentThreshold &&
        stdDev <= _config.excellentMaxStdDev &&
        radius <= _config.excellentMaxRadius &&
        gnssOk &&
        velocityOk) {
      newConf = PodConfidence.excellent;
      _locked = true;
    } else if (n >= _config.targetSamples &&
        avgAcc <= _config.captureThreshold &&
        gnssOk &&
        velocityOk) {
      newConf = PodConfidence.good;
      _locked = true;
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

    return fAcc * 0.35 + fSpread * 0.25 + fSample * 0.20 + fFresh * 0.20;
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
    _isFallbackLock = false;
    _confidence = PodConfidence.searching;
    _posInit = false;
    _lastSampleTimeMs = null;
    _gnssGateActive = false;
    _velocityGateActive = false;
    _spoofSuspected = false;
    _spoofReasons.clear();
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
      'samplesNeeded': _config.targetSamples,
      'progress': lockProgress,
      'environment': isIndoorDetected ? 'indoor' : 'outdoor',
      'timeoutSeconds': _activeTimeout.inSeconds,
      'accuracyThresholdMeters': _activeAccuracyThreshold,
      'spoofSuspected': _spoofSuspected,
      'spoofReasons': _spoofReasons,
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
