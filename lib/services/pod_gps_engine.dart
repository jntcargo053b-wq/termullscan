// lib/services/pod_gps_engine.dart
// ============================================================
// POD GPS ENGINE — Simple & Fast
// ============================================================
// Spec:
//   accuracy threshold (terima sample) : 25m
//   capture threshold (status Good)    : 15m
//   excellent threshold                : 10m
//   excellent max stdDev (cluster)     : 8m
//   excellent max radius (cluster)     : 12m
//   outlier rejection (MAD-based)      : BARU
//   confidence score (0–1)             : BARU
//   hard timeout       : 12 detik
//   target samples     : 3 (fast lock), max 10 untuk refine
//   min sampel utk Excellent : 3
//   centroid           : weighted (bobot 1/accuracy²)
//   avgAccuracy        : weighted (bobot 1/accuracy²)
//   provider           : fused
//   startup            : lastKnownPosition (OS cache + SharedPrefs)
//   distanceFilter     : 0 saat acquiring, 5 setelah locked
//   mock GPS           : ditolak (raw.isMocked) + heuristik akurasi=0
// ============================================================

import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

// ── GPS Configuration ──────────────────────────────────────────
class GpsConfig {
  final double accuracyThreshold;
  final double captureThreshold;
  final double excellentThreshold;
  final double excellentMaxStdDev;
  final double excellentMaxRadius;
  final int targetSamples;
  final int maxWindow;
  final Duration hardTimeout;
  final double moveThreshold;
  final double resetThreshold;
  final int outlierMinSamples;
  final double outlierMadFactor;
  final double outlierMinThreshold;

  const GpsConfig({
    this.accuracyThreshold = 25.0,
    this.captureThreshold = 15.0,
    this.excellentThreshold = 10.0,
    this.excellentMaxStdDev = 8.0,
    this.excellentMaxRadius = 12.0,
    this.targetSamples = 3,
    this.maxWindow = 10,
    this.hardTimeout = Duration(seconds: 12),
    this.moveThreshold = 20.0,
    this.resetThreshold = 50.0,
    this.outlierMinSamples = 4,
    this.outlierMadFactor = 3.0,
    this.outlierMinThreshold = 5.0,
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

  const PodSample({
    required this.lat,
    required this.lon,
    required this.accuracy,
    required this.timestampMs,
  });

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(timestampMs);

  @override
  String toString() =>
      'PodSample(lat=$lat, lon=$lon, acc=${accuracy.toStringAsFixed(1)}m, time=$time)';
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

  double _lastLat = 0, _lastLon = 0;
  bool _posInit = false;
  bool _locked = false;
  bool _isFallbackLock = false;

  // ─── Constructor ──────────────────────────────────────────────
  PodGpsEngine({GpsConfig? config}) : _config = config ?? const GpsConfig();

  // ─── Public getters ──────────────────────────────────────────
  PodConfidence get confidence => _confidence;
  PodLockResult? get lockResult => _lockResult;
  bool get canCapture => _confidence.canCapture;
  bool get isLocked => _locked;
  bool get isFallbackLock => _isFallbackLock;
  int get sampleCount => _window.length;
  int get samplesNeeded => _config.targetSamples;

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
  bool processSample(Position raw) {
    // Mock GPS → tolak
    if (raw.isMocked) {
      _log('mock GPS terdeteksi (isMocked), skip', level: GpsLogLevel.info);
      return false;
    }

    // Heuristik: akurasi 0.0 mencurigakan (spoofed)
    if (raw.accuracy <= 0.0) {
      _log('akurasi=0 mencurigakan (kemungkinan spoofed), skip', level: GpsLogLevel.info);
      return false;
    }

    // Filter akurasi
    if (raw.accuracy > _config.accuracyThreshold) {
      _log(
        'acc=${raw.accuracy.toStringAsFixed(1)}m > ${_config.accuracyThreshold}m, skip',
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
    _posInit = true;

    // Tambah ke window (FIFO: selalu tambah di akhir)
    final sample = PodSample(
      lat: raw.latitude,
      lon: raw.longitude,
      accuracy: raw.accuracy,
      timestampMs: raw.timestamp.millisecondsSinceEpoch,
    );
    _window.add(sample);
    if (_window.length > _config.maxWindow) _window.removeAt(0);

    // Update best samples cache (insertion sort)
    _updateBestSamples(sample);

    // Start timeout saat sample pertama masuk
    _timeoutTimer ??= Timer(_config.hardTimeout, _onTimeout);

    // Evaluasi
    final prev = _confidence;
    _evaluate();
    return _confidence.index > prev.index;
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
    _lockResult = _buildResult(
      0.6,
      stats,
      cleaned.length,
      _window.length - cleaned.length,
    );
    _log(
      'force lock acc=${best.accuracy.toStringAsFixed(1)}m [FALLBACK]',
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

    PodConfidence newConf;

    if (n >= _config.targetSamples &&
        avgAcc <= _config.excellentThreshold &&
        stdDev <= _config.excellentMaxStdDev &&
        radius <= _config.excellentMaxRadius) {
      newConf = PodConfidence.excellent;
      _locked = true;
    } else if (n >= _config.targetSamples && avgAcc <= _config.captureThreshold) {
      newConf = PodConfidence.good;
      _locked = true;
    } else if (n >= 1 && avgAcc <= _config.accuracyThreshold) {
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
      'stdDev=${stdDev.toStringAsFixed(1)}m radius=${radius.toStringAsFixed(1)}m locked=$_locked',
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
      final w = 1.0 / (clampedAcc * clampedAcc);
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
    final fAcc = (1.0 - (stats.avgAccuracy / _config.accuracyThreshold)).clamp(0.0, 1.0);

    final worstSpread = max(stats.stdDevMeters, stats.radiusMeters);
    final fSpread = (1.0 - (worstSpread / _config.accuracyThreshold)).clamp(0.0, 1.0);

    final now = DateTime.now();
    final avgAgeSec = samples
            .map((s) => now.difference(s.time).inMilliseconds / 1000.0)
            .reduce((a, b) => a + b) /
        samples.length;
    final fFresh = (1.0 - (avgAgeSec / _config.hardTimeout.inSeconds)).clamp(0.0, 1.0);

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

    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_config.hardTimeout, _onTimeout);
  }

  // ─── Hard reset ──────────────────────────────────────────────
  void _hardReset() {
    _window.clear();
    _bestSamples.clear(); // ← JANGAN LUPA CLEAR CACHE
    _lockResult = null;
    _locked = false;
    _isFallbackLock = false;
    _confidence = PodConfidence.searching;
    _posInit = false;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
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
      'sampleCount': _window.length,
      'samplesNeeded': _config.targetSamples,
      'progress': lockProgress,
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
      // Sudah selalu ≤ targetSamples karena _updateBestSamples menjaga ukuran
      // Tapi tetap aman
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
