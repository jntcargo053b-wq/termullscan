// lib/services/pod_native_location_service.dart
// ============================================================
// NATIVE FUSED LOCATION BRIDGE (Android only)
// ============================================================
// Wrapper tipis di atas FusedLocationProviderClient native — lihat
// android/.../FusedLocationStreamHandler.kt untuk alasan kenapa ini
// perlu ada di luar package `geolocator`: geolocator tidak mengekspos
// `setWaitForAccurateLocation(true)`, yang mencegah callback pertama
// berupa estimasi kasar (network/cell-based) ikut mengotori window
// PodGpsEngine.
//
// iOS TIDAK dijembatani — [isSupported] akan false, dan
// PodLocationService WAJIB fallback ke geolocator untuk platform itu
// (CoreLocation tidak punya API setara yang perlu dibedakan).
//
// Desain sengaja MENIRU gaya GnssQualityService yang sudah ada:
// listen = mulai update native (warm-up, GPS chip aktif), cancel =
// berhenti (baterai nol saat idle) — supaya PodLocationService bisa
// mengontrol warm-up hanya dengan subscribe/unsubscribe, tanpa method
// call terpisah untuk start/stop.
// ============================================================

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class NativeFusedPosition {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double? altitude;
  final double? speed;
  final double speedAccuracy;
  final double? bearing;
  final DateTime timestamp;
  final bool isMock;
  final String provider;

  const NativeFusedPosition({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    this.altitude,
    this.speed,
    required this.speedAccuracy,
    this.bearing,
    required this.timestamp,
    required this.isMock,
    required this.provider,
  });

  factory NativeFusedPosition.fromMap(Map<dynamic, dynamic> map) {
    return NativeFusedPosition(
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      accuracy: (map['accuracy'] as num).toDouble(),
      altitude: (map['altitude'] as num?)?.toDouble(),
      speed: (map['speed'] as num?)?.toDouble(),
      speedAccuracy: (map['speedAccuracy'] as num?)?.toDouble() ?? 0.0,
      bearing: (map['bearing'] as num?)?.toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (map['timestampMs'] as num).toInt(),
      ),
      isMock: map['isMock'] as bool? ?? false,
      provider: map['provider'] as String? ?? 'fused',
    );
  }

  /// speedAccuracy<=0 berarti provider tidak melaporkan speed Doppler
  /// yang bisa dipercaya — sama pola dengan PodSample.hasReliableSpeed
  /// di pod_gps_engine.dart, dipertahankan konsisten di sini.
  bool get hasReliableSpeed => speedAccuracy > 0;
}

class PodNativeLocationService {
  PodNativeLocationService._internal();
  static final PodNativeLocationService instance =
      PodNativeLocationService._internal();

  static const EventChannel _events =
      EventChannel('com.termulscan.whscanner/fused_location');
  static const MethodChannel _methods =
      MethodChannel('com.termulscan.whscanner/fused_location_control');

  /// true kalau platform ini punya native bridge (Android saja).
  /// Caller WAJIB fallback ke geolocator kalau ini false.
  bool get isSupported => Platform.isAndroid;

  Stream<NativeFusedPosition>? _cachedStream;

  /// Stream update posisi dari FusedLocationProviderClient native.
  ///
  /// Listen  → native mulai `requestLocationUpdates` (GPS chip warm).
  /// Cancel  → native `removeLocationUpdates` (idle, baterai nol).
  ///
  /// Error native (mis. permission belum granted saat listen dimulai)
  /// diteruskan sebagai error stream, BUKAN ditelan diam-diam — caller
  /// wajib menangkapnya dan fallback ke geolocator, karena silent
  /// swallow di sini bisa membuat capture menunggu selamanya tanpa
  /// pernah dapat sample.
  Stream<NativeFusedPosition> get positionStream {
    if (!isSupported) return const Stream.empty();
    return _cachedStream ??= _events
        .receiveBroadcastStream()
        .map((event) => NativeFusedPosition.fromMap(event as Map));
  }

  /// Snapshot instan dari cache FusedLocationProviderClient — biasanya
  /// lebih segar dari Geolocator.getLastKnownPosition() karena fused
  /// cache digabung dari semua app yang minta lokasi di device, bukan
  /// cuma app ini. Dipakai untuk preview instan (<50ms) sebelum stream
  /// live dapat sample pertama.
  Future<NativeFusedPosition?> getLastLocation() async {
    if (!isSupported) return null;
    try {
      final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
        'getLastLocation',
      );
      if (result == null) return null;
      return NativeFusedPosition.fromMap(result);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PodNativeLocationService: getLastLocation error $e');
      }
      return null;
    }
  }
}
