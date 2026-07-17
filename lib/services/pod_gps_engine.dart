// lib/services/pod_gps_engine.dart
// ============================================================
// POD GPS ENGINE — Simple & Fast
// ============================================================
// Spec:
//   accuracy threshold (terima sample) : 25m
//   capture threshold (status Good)    : 15m  ← diperketat dari 25m
//   excellent threshold                : 10m  ← diperketat dari 12m
//   excellent max stdDev (cluster)     : 8m   ← cegah "akurasi bagus
//                                                tapi titik lompat-lompat"
//   excellent max radius (cluster)     : 12m  ← BARU: gating tambahan,
//                                                stdDev bisa "diredam" oleh
//                                                banyak titik rapat + 1 titik
//                                                jauh; radius (jarak terjauh
//                                                dari centroid) menutup celah itu
//   outlier rejection (MAD-based)      : BARU — buang sampel yang secara
//                                                statistik nyasar (multipath)
//                                                SEBELUM dipakai hitung
//                                                centroid/stdDev/radius,
//                                                supaya satu sampel liar
//                                                tidak "menyeret" cluster
//   confidence score (0–1)             : BARU — gabungan akurasi + sebaran
//                                                cluster + jumlah sampel +
//                                                usia/kesegaran sampel,
//                                                bukan cuma akurasi+jumlah
//   hard timeout       : 12 detik
//   target samples     : 3 (fast lock), max 10 untuk refine
//   min sampel utk Excellent : 3 — TIDAK ADA fast-path 1 sampel lagi
//   centroid           : weighted (bobot 1/accuracy²)
//   avgAccuracy        : weighted (bobot 1/accuracy²) ← BARU: konsisten dengan centroid
//   provider           : fused
//   startup            : lastKnownPosition (OS cache + SharedPrefs)
//   distanceFilter     : 0 saat acquiring, 5 setelah locked
//   mock GPS           : ditolak (raw.isMocked) + heuristik akurasi=0
// ============================================================

import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

// ── Confidence ───────────────────────────────────────────────
enum PodConfidence {
  searching,  // Belum ada data
  poor,       // Ada sinyal, akurasi jelek
  fair,       // Cukup untuk preview
  good,       // OK untuk capture
  excellent,  // Terkunci presisi
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
  bool get isLocked   => this == PodConfidence.excellent;
}

// ── Sample ───────────────────────────────────────────────────
class PodSample {
  final double lat;
  final double lon;
  final double accuracy;
  final DateTime time;

  const PodSample({
    required this.lat,
    required this.lon,
    required this.accuracy,
    required this.time,
  });
}

// ── Lock Result ──────────────────────────────────────────────
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
    if (confidence == PodConfidence.good)      return 'Good';
    if (confidence == PodConfidence.fair)      return 'Fair';
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
  }) => PodLockResult(
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
// Hasil perhitungan centroid + sebaran, dipakai bareng oleh _evaluate()
// (untuk gating Excellent via stdDev) dan _buildResult() (untuk hasil akhir),
// supaya tidak dihitung dua kali dengan cara berbeda.
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

  // ── Tuning ──────────────────────────────────────────────────
  static const double _accuracyThreshold  = 25.0;  // terima sample ≤ 25m (urban Indonesia)
  static const double _captureThreshold   = 15.0;  // ambang "Good"/siap-capture — diperketat dari 25m
  static const double _excellentThreshold = 10.0;  // ambang "Excellent" — diperketat dari 12m
  static const double _excellentMaxStdDev = 8.0;   // sebaran cluster (avg) maks utk Excellent
  static const double _excellentMaxRadius = 12.0;  // BARU: jarak titik terjauh dari centroid maks
                                                    // utk Excellent — stdDev bisa "diredam" beberapa
                                                    // titik rapat, radius menutup celah 1 titik nyasar
  static const int    _targetSamples      = 3;     // min sampel utk Good & Excellent (tak ada fast-path 1 sampel)
  static const int    _maxWindow          = 10;    // simpan max 10 sample
  static const Duration _hardTimeout      = Duration(seconds: 12);

  // BARU: outlier rejection (MAD-based)
  static const int    _outlierMinSamples  = 4;     // di bawah ini, tak ada cukup data utk deteksi outlier yg aman
  static const double _outlierMadFactor   = 3.0;   // ambang = medianDist + factor * MAD_scaled
  static const double _outlierMinThreshold = 5.0;  // lantai ambang (m) — cegah over-reject saat cluster sangat rapat

  // distanceFilter: 0 saat acquiring, 5 setelah locked
  // (diatur oleh pod_location_service saat subscribe stream)
  static const double distanceFilterAcquiring = 0.0;
  static const double distanceFilterLocked     = 5.0;

  // Movement detection
  static const double _moveThreshold  = 20.0;  // soft unlock
  static const double _resetThreshold = 50.0;  // hard reset

  // ── State ───────────────────────────────────────────────────
  final List<PodSample> _window = [];
  PodLockResult?  _lockResult;
  PodConfidence   _confidence = PodConfidence.searching;
  Timer?          _timeoutTimer;

  double  _lastLat = 0, _lastLon = 0;
  bool    _posInit = false;
  bool    _locked  = false;

  // ── State ───────────────────────────────────────────────────
  bool _isFallbackLock = false;

  // ── Public getters ──────────────────────────────────────────
  PodConfidence  get confidence      => _confidence;
  PodLockResult? get lockResult      => _lockResult;
  bool           get canCapture      => _confidence.canCapture;
  bool           get isLocked        => _locked;
  bool           get isFallbackLock  => _isFallbackLock;
  int            get sampleCount     => _window.length;
  int            get samplesNeeded   => _targetSamples;

  double get lockProgress {
    if (_window.isEmpty) return 0.0;
    return (_window.length / _targetSamples).clamp(0.0, 1.0);
  }

  // ── Proses satu sample dari OS ──────────────────────────────
  bool processSample(Position raw) {
    // Mock GPS → tolak
    if (raw.isMocked) {
      if (kDebugMode) debugPrint('PodGpsEngine: mock GPS terdeteksi (isMocked), skip');
      return false;
    }

    // Heuristik tambahan: akurasi persis 0.0 sangat tidak wajar untuk GPS
    // asli (selalu ada noise sensor). Beberapa aplikasi fake-GPS di device
    // rooted bisa menyamarkan flag isMocked, jadi ini lapisan pertahanan
    // kedua (defense-in-depth), bukan pengganti raw.isMocked.
    if (raw.accuracy <= 0.0) {
      if (kDebugMode) debugPrint('PodGpsEngine: akurasi=0 mencurigakan (kemungkinan spoofed), skip');
      return false;
    }

    // Filter akurasi
    if (raw.accuracy > _accuracyThreshold) {
      if (kDebugMode) {
        debugPrint('PodGpsEngine: acc=${raw.accuracy.toStringAsFixed(1)}m > ${_accuracyThreshold}m, skip');
      }
      if (_confidence == PodConfidence.searching) _confidence = PodConfidence.poor;
      return false;
    }

    // Cek pergerakan
    if (_posInit) {
      final moved = _haversine(_lastLat, _lastLon, raw.latitude, raw.longitude);
      if (moved >= _resetThreshold) {
        _hardReset();
        if (kDebugMode) debugPrint('PodGpsEngine: hard reset, moved ${moved.toStringAsFixed(1)}m');
      } else if (moved >= _moveThreshold && _locked) {
        _softUnlock();
        if (kDebugMode) debugPrint('PodGpsEngine: soft unlock, moved ${moved.toStringAsFixed(1)}m');
      }
    }

    _lastLat = raw.latitude;
    _lastLon = raw.longitude;
    _posInit = true;

    // Tambah ke window
    _window.add(PodSample(
      lat: raw.latitude,
      lon: raw.longitude,
      accuracy: raw.accuracy,
      time: raw.timestamp,
    ));
    if (_window.length > _maxWindow) _window.removeAt(0);

    // Start timeout saat sample pertama masuk
    _timeoutTimer ??= Timer(_hardTimeout, _onTimeout);

    // Evaluasi
    final prev = _confidence;
    _evaluate();
    return _confidence.index > prev.index;
  }

  // ── Timeout handler ─────────────────────────────────────────
  void _onTimeout() {
    if (_locked) return; // sudah lock, tidak perlu timeout action

    // Paksa accept dengan data terbaik yang ada, meski belum 5 sampel
    if (_window.isNotEmpty) {
      if (kDebugMode) debugPrint('PodGpsEngine: timeout — force accept ${_window.length} samples');
      _forceLock();
    } else {
      _confidence = PodConfidence.poor;
      if (kDebugMode) debugPrint('PodGpsEngine: timeout — no samples');
    }
  }

  void _forceLock() {
    // Ambil sample dengan akurasi terbaik
    _window.sort((a, b) => a.accuracy.compareTo(b.accuracy));
    final best = _window.first;
    final cleaned = _rejectOutliers(_window);
    final stats = _computeClusterStats(cleaned);

    // CATATAN: fallback ini sengaja TIDAK mengikuti _captureThreshold (15m)
    // yang lebih ketat — ini adalah katup pengaman terakhir agar user tidak
    // terkunci total saat sinyal GPS buruk (indoor gudang, dsb). Karena itu
    // selalu ditandai isFallbackLock=true agar UI bisa menampilkan
    // peringatan "akurasi rendah" ke pengguna.
    _confidence = PodConfidence.good;
    _locked = true;
    _isFallbackLock = true;
    _lockResult = _buildResult(0.6, stats, cleaned.length, _window.length - cleaned.length);
    if (kDebugMode) {
      debugPrint('PodGpsEngine: force lock acc=${best.accuracy.toStringAsFixed(1)}m [FALLBACK]');
    }
  }

  // ── Evaluasi confidence ─────────────────────────────────────
  void _evaluate() {
    if (_window.isEmpty) {
      _confidence = PodConfidence.searching;
      return;
    }

    // BARU: buang outlier statistik (MAD-based) SEBELUM dipakai untuk
    // gating & centroid. Satu titik nyasar (multipath, refleksi gedung)
    // tidak boleh menyeret centroid maupun lolos sebagai "sampel valid".
    final cleaned = _rejectOutliers(_window);
    final rejected = _window.length - cleaned.length;

    final stats  = _computeClusterStats(cleaned);
    final avgAcc = stats.avgAccuracy;
    final stdDev = stats.stdDevMeters;
    final radius = stats.radiusMeters;
    final n      = cleaned.length; // gating pakai jumlah sampel BERSIH, bukan mentah

    PodConfidence newConf;

    // TIDAK ADA fast-path 1 sampel lagi — Excellent WAJIB minimal
    // _targetSamples (3) sampel bersih, mencegah 1 sampel kebetulan akurat
    // (mis. 6m) langsung dianggap "Terkunci".
    //
    // Excellent wajib stdDev (sebaran rata2 antar-sampel) DAN clusterRadius
    // (jarak titik terjauh dari centroid) kecil. stdDev saja bisa "diredam"
    // ketika mayoritas titik rapat tapi ada 1 titik nyasar jauh — radius
    // menutup celah itu karena mengukur kasus terburuk, bukan rata-rata.
    // Kalau salah satu gagal, turun jadi Good, bukan Fair, karena avgAcc
    // sendiri tetap valid.
    if (n >= _targetSamples &&
        avgAcc <= _excellentThreshold &&
        stdDev <= _excellentMaxStdDev &&
        radius <= _excellentMaxRadius) {
      newConf = PodConfidence.excellent;
      _locked = true;
    } else if (n >= _targetSamples && avgAcc <= _captureThreshold) {
      newConf = PodConfidence.good;
      _locked = true;
    } else if (n >= 1 && avgAcc <= _accuracyThreshold) {
      // fair lebih inklusif: 1 sample bersih sudah cukup untuk preview
      newConf = PodConfidence.fair;
    } else {
      newConf = PodConfidence.poor;
    }

    _confidence = newConf;

    if (_confidence.canCapture || _window.isNotEmpty) {
      _lockResult = _buildResult(_score(cleaned, stats), stats, cleaned.length, rejected);
    }

    if (_locked) {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    }

    if (kDebugMode) {
      debugPrint('PodGpsEngine: ${_confidence.label} | '
          'n=$n (rejected=$rejected) avgAcc=${avgAcc.toStringAsFixed(1)}m '
          'stdDev=${stdDev.toStringAsFixed(1)}m radius=${radius.toStringAsFixed(1)}m locked=$_locked');
    }
  }

  // ── Build result dari cluster stats yang sudah dihitung ─────
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

  // ── Outlier rejection (MAD-based) ───────────────────────────
  // Median Absolute Deviation lebih tahan terhadap outlier ekstrem
  // dibanding mean/stdDev biasa (yang justru "tertarik" oleh outlier itu
  // sendiri, membuatnya sulit dideteksi via stdDev). Sengaja konservatif:
  //  - hanya aktif jika n >= _outlierMinSamples (butuh cukup data agar
  //    deteksi statistik valid; dengan n kecil, "median" = sampel itu
  //    sendiri sehingga rawan salah buang sampel yang justru benar)
  //  - tidak pernah membuang sampel sampai di bawah _targetSamples,
  //    supaya gating confidence tidak terjebak looping poor↔fair karena
  //    window terus-menerus dikuras oleh false-positive rejection
  //  - ambang punya lantai minimum (_outlierMinThreshold) agar cluster
  //    yang memang sangat rapat (MAD≈0) tidak jadi over-agresif membuang
  List<PodSample> _rejectOutliers(List<PodSample> input) {
    if (input.length < _outlierMinSamples) return input;

    final medLat = _median(input.map((s) => s.lat).toList());
    final medLon = _median(input.map((s) => s.lon).toList());

    final distances = input
        .map((s) => _haversine(medLat, medLon, s.lat, s.lon))
        .toList();

    final medDist = _median(distances);
    final mad = _median(distances.map((d) => (d - medDist).abs()).toList());
    final madScaled = mad * 1.4826; // faktor skala MAD → stdDev (distribusi normal)

    final threshold = max(medDist + _outlierMadFactor * madScaled, _outlierMinThreshold);

    final filtered = <PodSample>[
      for (var i = 0; i < input.length; i++)
        if (distances[i] <= threshold) input[i],
    ];

    // Katup pengaman: jangan sampai gating jadi tak bisa lock sama sekali
    if (filtered.length < _targetSamples) return input;
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

  // ── Hitung centroid (weighted) + sebaran cluster ────────────
  // Centroid dihitung dengan bobot inverse-variance (w = 1/accuracy²)
  // supaya sampel yang lebih presisi lebih dominan menentukan titik akhir,
  // bukan rata-rata polos yang menyamakan bobot sampel 5m dan 20m.
  // Akurasi diklem minimum 1m agar sampel super-akurat tidak
  // mendominasi secara ekstrem (mis. pembagian oleh angka mendekati 0).
  //
  // BARU: avgAccuracy juga menggunakan weighted average (bobot 1/accuracy²)
  // sehingga sampel dengan akurasi lebih baik lebih dominan
  _ClusterStats _computeClusterStats(List<PodSample> samples) {
    double sumLatW = 0, sumLonW = 0, sumW = 0;
    double sumAccW = 0; // BARU: untuk weighted average akurasi
    PodSample? best;

    for (final s in samples) {
      final clampedAcc = max(s.accuracy, 1.0);
      final w = 1.0 / (clampedAcc * clampedAcc);
      sumLatW += s.lat * w;
      sumLonW += s.lon * w;
      sumW    += w;
      sumAccW += s.accuracy * w; // BARU: akurasi dikali bobot
      if (best == null || s.accuracy < best.accuracy) best = s;
    }

    final n = samples.length;
    final cLat = sumLatW / sumW;
    final cLon = sumLonW / sumW;
    final avgAcc = sumAccW / sumW; // BARU: weighted average, bukan rata-rata biasa

    // Std-dev dan radius dari centroid (weighted)
    double sumSq = 0, maxD = 0;
    for (final s in samples) {
      final d = _haversine(cLat, cLon, s.lat, s.lon);
      sumSq += d * d;
      if (d > maxD) maxD = d;
    }
    final stdDev = n > 1 ? sqrt(sumSq / n) : 0.0;

    return _ClusterStats(
      centroidLat: cLat,
      centroidLon: cLon,
      avgAccuracy: avgAcc, // Sekarang sudah weighted!
      stdDevMeters: stdDev,
      radiusMeters: maxD,
      best: best!,
    );
  }

  // ── Score 0–1 ───────────────────────────────────────────────
  // BARU: gabungan 4 faktor, bukan cuma akurasi+jumlah sampel.
  //   1. fAcc     (bobot 0.35) — akurasi rata2 vs ambang penerimaan
  //   2. fSpread  (bobot 0.25) — sebaran cluster (pakai yang TERBURUK
  //      antara stdDev & radius, supaya 1 titik nyasar tetap menekan skor
  //      walau stdDev rata2 masih kelihatan bagus)
  //   3. fSample  (bobot 0.20) — jumlah sampel bersih vs target
  //   4. fFresh   (bobot 0.20) — usia/kesegaran sampel: sampel yang "basi"
  //      (delay dari OS/cache, atau sisa window lama) menurunkan skor
  //      meski akurasi & sebaran-nya sendiri masih terlihat bagus
  double _score(List<PodSample> samples, _ClusterStats stats) {
    if (samples.isEmpty) return 0.0;

    final fSample = (samples.length / _targetSamples).clamp(0.0, 1.0);
    final fAcc    = (1.0 - (stats.avgAccuracy / _accuracyThreshold)).clamp(0.0, 1.0);

    final worstSpread = max(stats.stdDevMeters, stats.radiusMeters);
    final fSpread = (1.0 - (worstSpread / _accuracyThreshold)).clamp(0.0, 1.0);

    final now = DateTime.now();
    final avgAgeSec = samples
            .map((s) => now.difference(s.time).inMilliseconds / 1000.0)
            .reduce((a, b) => a + b) /
        samples.length;
    final fFresh = (1.0 - (avgAgeSec / _hardTimeout.inSeconds)).clamp(0.0, 1.0);

    return fAcc * 0.35 + fSpread * 0.25 + fSample * 0.20 + fFresh * 0.20;
  }

  // ── Soft unlock ─────────────────────────────────────────────
  void _softUnlock() {
    _locked = false;
    _isFallbackLock = false;
    _confidence = PodConfidence.fair;
    _lockResult = null;
    // Simpan 3 sample terakhir
    while (_window.length > 3) _window.removeAt(0);
    // Restart timeout
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_hardTimeout, _onTimeout);
  }

  // ── Hard reset ──────────────────────────────────────────────
  void _hardReset() {
    _window.clear();
    _lockResult = null;
    _locked = false;
    _isFallbackLock = false;
    _confidence = PodConfidence.searching;
    _posInit = false;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void reset() {
    _hardReset();
  }

  void dispose() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  // ── Haversine ───────────────────────────────────────────────
  static double _haversine(double lat1, double lon1, double lat2, double lon2) =>
      haversinePublic(lat1, lon1, lat2, lon2);

  /// Public version untuk dipakai service (movement detection geocode re-trigger)
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
