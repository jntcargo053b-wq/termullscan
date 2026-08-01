// lib/services/gnss_quality_service.dart
// ============================================================
// GNSS QUALITY SERVICE
// ============================================================
// Wrapper untuk EventChannel native (Android-only) yang membaca
// GnssStatus.Callback: jumlah satelit yang dipakai dalam fix dan
// rata-rata C/N0 (kekuatan sinyal, dB-Hz).
//
// Kenapa ini penting dan tidak bisa didapat dari geolocator biasa:
//   Position.accuracy dari OS adalah ESTIMASI (biasanya HDOP × faktor
//   internal chip). Saat sinyal memantul dari atap logam/rak baja
//   (multipath) di dalam gudang, chip GPS kadang tetap melaporkan
//   accuracy yang terlihat wajar padahal fix-nya bias — karena OS
//   tidak selalu mendeteksi multipath sebagai "buruk". Data mentah
//   satelit (jumlah dipakai + C/N0) adalah sinyal independen untuk
//   menyaring kondisi ini SEBELUM data masuk ke smoothing/centroid.
//
// Platform lain (iOS, web, dll.) → stream selalu null, seluruh
// gating GNSS di PodGpsEngine otomatis nonaktif dan sistem fallback
// sepenuhnya ke logika accuracy-only yang sudah ada.
// ============================================================

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class GnssQualitySample {
  final int satellitesUsedInFix;
  final int satellitesTotal;
  final int healthySatellitesUsed;
  final double avgCn0DbHz;

  // ── Dilution of Precision (BARU, dari NMEA GSA, Android-only) ──
  // null jika sentence GSA belum pernah diterima atau sudah basi
  // (lihat NMEA_DOP_MAX_AGE_MS di native side). Saat null, seluruh
  // gating berbasis DOP di PodGpsEngine otomatis nonaktif — fallback
  // penuh ke logika satelit/CN0/accuracy yang sudah ada.
  final double? pdop;
  final double? hdop;
  final double? vdop;

  final DateTime timestamp;

  const GnssQualitySample({
    required this.satellitesUsedInFix,
    required this.satellitesTotal,
    required this.healthySatellitesUsed,
    required this.avgCn0DbHz,
    this.pdop,
    this.hdop,
    this.vdop,
    required this.timestamp,
  });

  factory GnssQualitySample.fromMap(Map<dynamic, dynamic> map) {
    return GnssQualitySample(
      satellitesUsedInFix: (map['satellitesUsedInFix'] as num?)?.toInt() ?? 0,
      satellitesTotal: (map['satellitesTotal'] as num?)?.toInt() ?? 0,
      healthySatellitesUsed:
          (map['healthySatellitesUsed'] as num?)?.toInt() ?? 0,
      avgCn0DbHz: (map['avgCn0DbHz'] as num?)?.toDouble() ?? 0.0,
      pdop: (map['pdop'] as num?)?.toDouble(),
      hdop: (map['hdop'] as num?)?.toDouble(),
      vdop: (map['vdop'] as num?)?.toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (map['timestampMs'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  bool get hasDop => pdop != null || hdop != null || vdop != null;

  @override
  String toString() =>
      'GnssQualitySample(used=$satellitesUsedInFix/$satellitesTotal, '
      'healthy=$healthySatellitesUsed, avgCn0=${avgCn0DbHz.toStringAsFixed(1)}dBHz, '
      'hdop=${hdop?.toStringAsFixed(1) ?? "n/a"}, pdop=${pdop?.toStringAsFixed(1) ?? "n/a"})';
}

class GnssQualityService {
  static final GnssQualityService _instance = GnssQualityService._internal();
  static GnssQualityService get instance => _instance;
  GnssQualityService._internal();

  static const EventChannel _channel =
      EventChannel('com.termulscan.whscanner/gnss_quality');

  StreamSubscription<dynamic>? _sub;
  final _ctrl = StreamController<GnssQualitySample?>.broadcast();

  GnssQualitySample? _latest;
  GnssQualitySample? get latest => _latest;

  /// true hanya jika platform mendukung DAN sudah pernah menerima
  /// minimal satu payload non-null dari native side.
  bool _everReceivedData = false;
  bool get isSupported => _everReceivedData;

  Stream<GnssQualitySample?> get stream => _ctrl.stream;

  bool get _platformSupported => !kIsWeb && Platform.isAndroid;

  void start() {
    if (!_platformSupported) return;
    if (_sub != null) return; // sudah listening

    _sub = _channel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final sample = GnssQualitySample.fromMap(event);
          _everReceivedData = true;
          _latest = sample;
          _ctrl.add(sample);
        } else {
          _latest = null;
          _ctrl.add(null);
        }
      },
      onError: (Object e) {
        if (kDebugMode) debugPrint('GnssQualityService: stream error $e');
        _latest = null;
        _ctrl.add(null);
      },
      cancelOnError: false,
    );
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _latest = null;
  }

  void dispose() {
    stop();
    _ctrl.close();
  }
}
