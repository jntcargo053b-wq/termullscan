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
//   hard timeout       : 12 detik
//   target samples     : 3 (fast lock), max 10 untuk refine
//   min sampel utk Excellent : 3 — TIDAK ADA fast-path 1 sampel lagi
//   centroid           : weighted (bobot 1/accuracy²) — BARU, bukan rata2 polos
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
  static const double _excellentMaxStdDev = 8.0;   // BARU: sebaran cluster maks utk Excellent
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
    _lockResult = _buildResult(0.6, stats);
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
    final n      = _window.length;

    PodConfidence newConf;

    // TIDAK ADA fast-path 1 sampel lagi — Excellent WAJIB minimal
    // _targetSamples (3) sampel, mencegah 1 sampel kebetulan akurat
    // (mis. 6m) langsung dianggap "Terkunci".
    //
    // BARU: Excellent juga wajib stdDev (sebaran antar-sampel) kecil.
    // Ini menutup celah di mana chip GPS melaporkan akurasi bagus tapi
    // titik-titiknya sendiri lompat-lompat (multipath di gudang/gedung
    // bertingkat) — kalau stdDev gagal, turun jadi Good, bukan Fair,
    // karena avgAcc-nya sendiri tetap valid.
    if (n >= _targetSamples && avgAcc <= _excellentThreshold && stdDev <= _excellentMaxStdDev) {
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
      _lockResult = _buildResult(_score(), stats);
    }

    if (_locked) {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    }

    if (kDebugMode) {
      debugPrint('PodGpsEngine: ${_confidence.label} | '
          'n=$n avgAcc=${avgAcc.toStringAsFixed(1)}m stdDev=${stdDev.toStringAsFixed(1)}m locked=$_locked');
    }
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
  _ClusterStats _computeClusterStats() {
    double sumLatW = 0, sumLonW = 0, sumW = 0, sumAcc = 0;
    PodSample? best;

    for (final s in _window) {
      final clampedAcc = max(s.accuracy, 1.0);
      final w = 1.0 / (clampedAcc * clampedAcc);
      sumLatW += s.lat * w;
      sumLonW += s.lon * w;
      sumW    += w;
      sumAcc  += s.accuracy;
      if (best == null || s.accuracy < best.accuracy) best = s;
    }

    final n = _window.length;
    final cLat = sumLatW / sumW;
    final cLon = sumLonW / sumW;
    final avgAcc = sumAcc / n;

    // Std-dev dan radius dari centroid (weighted)
    double sumSq = 0, maxD = 0;
    for (final s in _window) {
      final d = _haversine(cLat, cLon, s.lat, s.lon);
      sumSq += d * d;
      if (d > maxD) maxD = d;
    }
    final stdDev = n > 1 ? sqrt(sumSq / n) : 0.0;

    return _ClusterStats(
      centroidLat: cLat,
      centroidLon: cLon,
      avgAccuracy: avgAcc,
      stdDevMeters: stdDev,
      radiusMeters: maxD,
      best: best!,
    );
  }

  // ── Score 0–1 ───────────────────────────────────────────────
  double _score() {
    if (_window.isEmpty) return 0.0;
    final fSample = (_window.length / _targetSamples).clamp(0.0, 1.0);
    final fAcc    = (1.0 - (_avgAccuracy() / _accuracyThreshold).clamp(0.0, 1.0));
    return fSample * 0.5 + fAcc * 0.5;
  }

  double _avgAccuracy() {
    if (_window.isEmpty) return 999.0;
    return _window.map((s) => s.accuracy).reduce((a, b) => a + b) / _window.length;
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
