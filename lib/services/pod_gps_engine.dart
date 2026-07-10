// lib/services/pod_gps_engine.dart
// ============================================================
// POD GPS ENGINE — Simple & Fast
// ============================================================
// Spec:
//   accuracy threshold : 20m
//   hard timeout       : 10 detik
//   target samples     : 3 (fast lock), max 8 untuk refine
//   fast path          : 1 sample ≤5m → excellent langsung
//   provider           : fused
//   startup            : lastKnownPosition (OS cache + SharedPrefs)
//   distanceFilter     : 0 saat acquiring, 5 setelah locked
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

// ═══════════════════════════════════════════════════════════════
// PodGpsEngine
// ═══════════════════════════════════════════════════════════════
class PodGpsEngine {

  // ── Tuning ──────────────────────────────────────────────────
  static const double _accuracyThreshold  = 25.0;  // terima sample ≤ 25m (urban Indonesia)
  static const double _fastPathAccuracy   = 6.0;   // 1 sample ≤6m → excellent langsung
  static const double _excellentThreshold = 12.0;  // 3 sample ≤12m → excellent
  static const int    _targetSamples      = 3;     // 3 sample → locked (lebih cepat)
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
      if (kDebugMode) debugPrint('PodGpsEngine: mock GPS, skip');
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

    _confidence = PodConfidence.good;
    _locked = true;
    _isFallbackLock = true;
    _lockResult = _buildResult(0.6);
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

    final avgAcc = _avgAccuracy();
    final n = _window.length;

    PodConfidence newConf;

    // Fast path: 1 sample dengan akurasi sangat baik → langsung excellent
    if (n >= 1 && avgAcc <= _fastPathAccuracy) {
      newConf = PodConfidence.excellent;
      _locked = true;
      _isFallbackLock = false;
    } else if (n >= _targetSamples && avgAcc <= _excellentThreshold) {
      newConf = PodConfidence.excellent;
      _locked = true;
    } else if (n >= _targetSamples && avgAcc <= _accuracyThreshold) {
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
      _lockResult = _buildResult(_score());
    }

    if (_locked) {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    }

    if (kDebugMode) {
      debugPrint('PodGpsEngine: ${_confidence.label} | '
          'n=$n avgAcc=${avgAcc.toStringAsFixed(1)}m locked=$_locked');
    }
  }

  // ── Build result ────────────────────────────────────────────
  PodLockResult _buildResult(double score) {
    double sumLat = 0, sumLon = 0, sumAcc = 0;
    PodSample? best;

    for (final s in _window) {
      sumLat += s.lat;
      sumLon += s.lon;
      sumAcc += s.accuracy;
      if (best == null || s.accuracy < best.accuracy) best = s;
    }

    final n = _window.length;
    final cLat = sumLat / n;
    final cLon = sumLon / n;
    final avgAcc = sumAcc / n;

    // Std-dev dan radius dari centroid
    double sumSq = 0, maxD = 0;
    for (final s in _window) {
      final d = _haversine(cLat, cLon, s.lat, s.lon);
      sumSq += d * d;
      if (d > maxD) maxD = d;
    }
    final stdDev = n > 1 ? sqrt(sumSq / n) : 0.0;

    return PodLockResult(
      centroidLat: cLat,
      centroidLon: cLon,
      accuracy: avgAcc,
      confidenceScore: score,
      confidence: _confidence,
      bestRaw: best!,
      samplesUsed: n,
      clusterStdDevMeters: stdDev,
      clusterRadiusMeters: maxD,
      lockedAt: DateTime.now(),
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
