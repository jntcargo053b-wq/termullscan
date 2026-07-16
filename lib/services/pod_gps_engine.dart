// lib/services/pod_gps_engine.dart
// ============================================================
// POD GPS ENGINE — Simple & Fast
// ============================================================
// Spec:
//   accuracy threshold (terima sample) : 25m
//   capture threshold (status Good)    : 15m  ← diperketat dari 25m
//   excellent threshold                : 10m  ← diperketat dari 12m
//   excellent max stdDev (cluster)     : 8m   ← BARU: cegah "akurasi bagus
//                                                tapi titik lompat-lompat"
//   excellent max radius (cluster)     : 12m  ← BARU: tambahan syarat Excellent
//   outlier rejection                  : 2.5σ ← BARU: buang sampel liar
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
  final int samplesRejected; // BARU: jumlah sampel yang ditolak outlier
  final double clusterStdDevMeters;
  final double clusterRadiusMeters;
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
    required this.samplesRejected,
    required this.clusterStdDevMeters,
    required this.clusterRadiusMeters,
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
    samplesRejected: samplesRejected,
    clusterStdDevMeters: clusterStdDevMeters,
    clusterRadiusMeters: clusterRadiusMeters,
    lockedAt: lockedAt,
  );
}

// ── Cluster stats (internal) ──────────────────────────────────
// Hasil perhitungan centroid + sebaran, dipakai bareng oleh _evaluate()
// (untuk gating Excellent via stdDev & radius) dan _buildResult() (untuk hasil akhir),
// supaya tidak dihitung dua kali dengan cara berbeda.
class _ClusterStats {
  final double centroidLat;
  final double centroidLon;
  final double avgAccuracy;
  final double stdDevMeters;
  final double radiusMeters;
  final PodSample best;
  final int rejectedCount; // BARU: jumlah sampel yang direject

  const _ClusterStats({
    required this.centroidLat,
    required this.centroidLon,
    required this.avgAccuracy,
    required this.stdDevMeters,
    required this.radiusMeters,
    required this.best,
    required this.rejectedCount,
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
  static const double _excellentMaxStdDev = 8.0;   // BARU: sebaran cluster maks utk Excellent
  static const double _excellentMaxRadius = 12.0;  // BARU: radius cluster maks utk Excellent
  static const double _outlierSigma       = 2.5;   // BARU: ambang outlier dalam satuan sigma
  static const int    _targetSamples      = 3;     // min sampel utk Good & Excellent (tak ada fast-path 1 sampel)
  static const int    _maxWindow          = 10;    // simpan max 10 sample
  static const Duration _hardTimeout      = Duration(seconds: 12);

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
    final stats = _computeClusterStats();

    // CATATAN: fallback ini sengaja TIDAK mengikuti _captureThreshold (15m)
    // yang lebih ketat — ini adalah katup pengaman terakhir agar user tidak
    // terkunci total saat sinyal GPS buruk (indoor gudang, dsb). Karena itu
    // selalu ditandai isFallbackLock=true agar UI bisa menampilkan
    // peringatan "akurasi rendah" ke pengguna.
    _confidence = PodConfidence.good;
    _locked = true;
    _isFallbackLock = true;
    _lockResult = _buildResult(_computeConfidenceScore(stats), stats);
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

    final stats  = _computeClusterStats();
    final avgAcc = stats.avgAccuracy;
    final stdDev = stats.stdDevMeters;
    final radius = stats.radiusMeters;
    final n      = _window.length;
    final rejected = stats.rejectedCount;

    PodConfidence newConf;

    // BARU: Excellent wajib memenuhi SEMUA syarat:
    // 1. Minimal _targetSamples (3) sampel
    // 2. Akurasi rata-rata ≤ _excellentThreshold (10m)
    // 3. StdDev ≤ _excellentMaxStdDev (8m) — cegah titik lompat-lompat
    // 4. Radius ≤ _excellentMaxRadius (12m) — cegah outlier yang lolos
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
      // fair lebih inklusif: 1 sample sudah cukup untuk preview
      newConf = PodConfidence.fair;
    } else {
      newConf = PodConfidence.poor;
    }

    _confidence = newConf;

    if (_confidence.canCapture || _window.isNotEmpty) {
      _lockResult = _buildResult(_computeConfidenceScore(stats), stats);
    }

    if (_locked) {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    }

    if (kDebugMode) {
      debugPrint('PodGpsEngine: ${_confidence.label} | '
          'n=$n avgAcc=${avgAcc.toStringAsFixed(1)}m stdDev=${stdDev.toStringAsFixed(1)}m '
          'radius=${radius.toStringAsFixed(1)}m rejected=$rejected locked=$_locked');
    }
  }

  // ── Confidence Score yang disempurnakan ─────────────────────
  // Score 0-1 yang menggabungkan:
  // - Akurasi (semakin kecil semakin baik)
  // - Sebaran titik (stdDev & radius)
  // - Jumlah sampel (semakin banyak semakin stabil)
  // - Usia sampel (semakin fresh semakin baik)
  double _computeConfidenceScore(_ClusterStats stats) {
    if (_window.isEmpty) return 0.0;

    final n = _window.length;
    final avgAcc = stats.avgAccuracy.clamp(0.0, _accuracyThreshold);
    final stdDev = stats.stdDevMeters.clamp(0.0, 20.0);
    final radius = stats.radiusMeters.clamp(0.0, 30.0);
    
    // 1. Faktor akurasi (0-1): semakin kecil akurasi semakin tinggi
    // Menggunakan kurva eksponensial untuk memberikan penalti lebih berat
    // pada akurasi buruk
    final accFactor = exp(-avgAcc / 15.0);
    
    // 2. Faktor stabilitas (0-1): stdDev dan radius kecil = stabil
    // stdDev ideal ≤ 3m, radius ideal ≤ 5m
    final stdDevFactor = exp(-stdDev / 4.0);
    final radiusFactor = exp(-radius / 6.0);
    final stabilityFactor = (stdDevFactor + radiusFactor) / 2.0;
    
    // 3. Faktor jumlah sampel (0-1): semakin banyak semakin baik
    // target 5 sampel ideal, lebih dari itu diminishing returns
    final sampleFactor = 1.0 - exp(-n / 3.5);
    
    // 4. Faktor kesegaran (0-1): sampel terbaru lebih berbobot
    // Hitung rata-rata usia sampel dalam detik
    final now = DateTime.now();
    double totalAge = 0;
    for (final s in _window) {
      totalAge += now.difference(s.time).inMilliseconds.abs();
    }
    final avgAgeMs = totalAge / n;
    final avgAgeSec = avgAgeMs / 1000.0;
    // Usia ideal < 3 detik, penalti penuh di 15 detik
    final freshnessFactor = exp(-avgAgeSec / 5.0);
    
    // 5. Faktor outlier (0-1): semakin banyak outlier yang direject semakin baik
    final outlierFactor = _window.length > 0 
        ? 1.0 - (stats.rejectedCount / (_window.length + stats.rejectedCount)).clamp(0.0, 0.5)
        : 0.5;
    
    // Bobot masing-masing faktor
    const wAcc = 0.30;
    const wStability = 0.25;
    const wSamples = 0.20;
    const wFreshness = 0.15;
    const wOutlier = 0.10;
    
    double score = (accFactor * wAcc) +
                   (stabilityFactor * wStability) +
                   (sampleFactor * wSamples) +
                   (freshnessFactor * wFreshness) +
                   (outlierFactor * wOutlier);
    
    // Bonus: jika Excellent, tambahkan boost
    if (_confidence == PodConfidence.excellent) {
      score = min(1.0, score + 0.1);
    }
    
    return score.clamp(0.0, 1.0);
  }

  // ── Build result dari cluster stats yang sudah dihitung ─────
  PodLockResult _buildResult(double score, _ClusterStats stats) {
    return PodLockResult(
      centroidLat: stats.centroidLat,
      centroidLon: stats.centroidLon,
      accuracy: stats.avgAccuracy,
      confidenceScore: score,
      confidence: _confidence,
      bestRaw: stats.best,
      samplesUsed: _window.length,
      samplesRejected: stats.rejectedCount,
      clusterStdDevMeters: stats.stdDevMeters,
      clusterRadiusMeters: stats.radiusMeters,
      lockedAt: DateTime.now(),
    );
  }

  // ── Hitung centroid (weighted) + sebaran cluster ────────────
  // Centroid dihitung dengan bobot inverse-variance (w = 1/accuracy²)
  // supaya sampel yang lebih presisi lebih dominan menentukan titik akhir,
  // bukan rata-rata polos yang menyamakan bobot sampel 5m dan 20m.
  // Akurasi diklem minimum 1m agar sampel super-akurat tidak
  // mendominasi secara ekstrem (mis. pembagian oleh angka mendekati 0).
  //
  // BARU: outlier rejection menggunakan sigma clipping dengan threshold _outlierSigma
  // Sampel yang jaraknya > _outlierSigma * stdDev dari centroid akan dibuang
  //
  // BARU: avgAccuracy juga menggunakan weighted average (bobot 1/accuracy²)
  // sehingga sampel dengan akurasi lebih baik lebih dominan
  _ClusterStats _computeClusterStats() {
    // Pertama hitung centroid awal dengan semua sampel
    double sumLatW = 0, sumLonW = 0, sumW = 0;
    double sumAccW = 0; // BARU: untuk weighted average akurasi
    PodSample? best;

    for (final s in _window) {
      final clampedAcc = max(s.accuracy, 1.0);
      final w = 1.0 / (clampedAcc * clampedAcc);
      sumLatW += s.lat * w;
      sumLonW += s.lon * w;
      sumW    += w;
      sumAccW += s.accuracy * w; // BARU: akurasi dikali bobot
      if (best == null || s.accuracy < best.accuracy) best = s;
    }

    final n = _window.length;
    double cLat = sumLatW / sumW;
    double cLon = sumLonW / sumW;
    final avgAcc = sumAccW / sumW; // BARU: weighted average, bukan rata-rata biasa

    // Hitung stdDev awal dari centroid
    double sumSq = 0, maxD = 0;
    final distances = <double>[];
    for (final s in _window) {
      final d = _haversine(cLat, cLon, s.lat, s.lon);
      distances.add(d);
      sumSq += d * d;
      if (d > maxD) maxD = d;
    }
    double stdDev = n > 1 ? sqrt(sumSq / n) : 0.0;

    // ── Outlier Rejection (Sigma Clipping) ──
    // Jika stdDev > 0 dan ada lebih dari 2 sampel, lakukan outlier rejection
    List<PodSample> filteredSamples = List.from(_window);
    int rejectedCount = 0;
    
    if (stdDev > 0.5 && n >= 3) {
      final threshold = _outlierSigma * stdDev;
      final newSamples = <PodSample>[];
      
      for (int i = 0; i < distances.length; i++) {
        if (distances[i] <= threshold) {
          newSamples.add(_window[i]);
        } else {
          rejectedCount++;
          if (kDebugMode) {
            debugPrint('PodGpsEngine: outlier rejected at ${distances[i].toStringAsFixed(1)}m '
                '(threshold ${threshold.toStringAsFixed(1)}m)');
          }
        }
      }
      
      // Hanya terima hasil filtering jika masih tersisa cukup sampel (≥ 2)
      // dan tidak membuang terlalu banyak (> 50%)
      if (newSamples.length >= 2 && rejectedCount <= n * 0.5) {
        filteredSamples = newSamples;
      } else {
        // Jika terlalu banyak outlier, reset rejectedCount
        rejectedCount = 0;
      }
    }

    // ── Rehitungan centroid dengan data yang sudah difilter ──
    // Hanya hitung ulang jika ada sampel yang dibuang
    if (rejectedCount > 0 && filteredSamples.length < _window.length) {
      sumLatW = 0; sumLonW = 0; sumW = 0;
      sumAccW = 0; // BARU: reset weighted akurasi
      best = null;
      
      for (final s in filteredSamples) {
        final clampedAcc = max(s.accuracy, 1.0);
        final w = 1.0 / (clampedAcc * clampedAcc);
        sumLatW += s.lat * w;
        sumLonW += s.lon * w;
        sumW    += w;
        sumAccW += s.accuracy * w; // BARU: akurasi dikali bobot
        if (best == null || s.accuracy < best.accuracy) best = s;
      }
      
      cLat = sumLatW / sumW;
      cLon = sumLonW / sumW;
      final avgAccFiltered = sumAccW / sumW; // BARU: weighted average setelah filtering
      
      // Hitung ulang stdDev dan radius
      sumSq = 0; maxD = 0;
      for (final s in filteredSamples) {
        final d = _haversine(cLat, cLon, s.lat, s.lon);
        sumSq += d * d;
        if (d > maxD) maxD = d;
      }
      final m = filteredSamples.length;
      stdDev = m > 1 ? sqrt(sumSq / m) : 0.0;
      
      // Update window dengan data yang sudah difilter
      // Hanya jika jumlah sampel masih cukup
      if (filteredSamples.length >= _targetSamples) {
        _window.clear();
        _window.addAll(filteredSamples);
      }
      
      return _ClusterStats(
        centroidLat: cLat,
        centroidLon: cLon,
        avgAccuracy: avgAccFiltered, // Gunakan weighted average setelah filtering
        stdDevMeters: stdDev,
        radiusMeters: maxD,
        best: best!,
        rejectedCount: rejectedCount,
      );
    }

    // Jika tidak ada filtering, return hasil pertama
    return _ClusterStats(
      centroidLat: cLat,
      centroidLon: cLon,
      avgAccuracy: avgAcc, // Sudah weighted
      stdDevMeters: stdDev,
      radiusMeters: maxD,
      best: best!,
      rejectedCount: rejectedCount,
    );
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
