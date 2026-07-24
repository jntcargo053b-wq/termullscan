// lib/services/pod_location_service.dart
// ============================================================
// POD LOCATION SERVICE — On-Demand Mode (versi TermulScan)
// ============================================================
// Diadaptasi dari TermulLog: fitur weather dihilangkan karena
// tidak relevan untuk aplikasi scan barcode/foto/video.
//
// GPS TIDAK aktif terus-menerus. Engine hanya berjalan saat:
//   1. acquireForCapture() dipanggil (user buka kamera / tap capture)
//   2. Otomatis berhenti setelah lock ATAU timeout
//
// Lifecycle GPS:
//   idle      → tidak ada stream, baterai nol
//   acquiring → stream aktif, kumpul sample
//   locked    → stream berhenti, koordinat tersimpan
//   stale     → locked > _staleAfter, perlu re-acquire
//
// Cache:
//   - OS getLastKnownPosition()  → instant preview (<50ms)
//   - SharedPreferences          → koordinat + alamat sesi lalu
//   - Geocode: hanya fetch ulang jika bergerak >50m dari cache
// ============================================================

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pod_gps_engine.dart';
import 'pod_address_resolver.dart';
import '../models/resolved_location.dart';

export 'pod_gps_engine.dart' show PodConfidence, PodConfidenceLabel, PodLockResult;

// ── Status mode service ───────────────────────────────────────
enum PodGpsMode {
  idle,       // GPS off, tampilkan cache jika ada
  acquiring,  // Stream aktif, sedang mengumpul sample
  locked,     // Sudah lock, stream sudah berhenti
  stale,      // Lock lama > _staleAfter, perlu re-acquire
}

// ── State ────────────────────────────────────────────────────
class PodLocationState {
  final double? lat;
  final double? lon;
  final double? accuracy;
  final PodConfidence confidence;
  final PodLockResult? lockResult;
  final String address;
  final bool addressLoading;
  final bool fromCache;
  final double lockProgress;
  final bool isFastAddress;
  final bool isFallbackLock;
  final PodGpsMode mode;
  final ResolvedLocation? resolvedLocation;
  final bool mockDetected;

  const PodLocationState({
    this.lat,
    this.lon,
    this.accuracy,
    this.confidence = PodConfidence.searching,
    this.lockResult,
    this.address = '',
    this.addressLoading = false,
    this.fromCache = false,
    this.lockProgress = 0.0,
    this.isFastAddress = false,
    this.isFallbackLock = false,
    this.mode = PodGpsMode.idle,
    this.resolvedLocation,
    this.mockDetected = false,
  });

  PodLocationState copyWith({
    double? lat,
    double? lon,
    double? accuracy,
    PodConfidence? confidence,
    PodLockResult? lockResult,
    String? address,
    bool? addressLoading,
    bool? fromCache,
    double? lockProgress,
    bool? isFastAddress,
    bool? isFallbackLock,
    PodGpsMode? mode,
    ResolvedLocation? resolvedLocation,
    bool? mockDetected,
  }) => PodLocationState(
    lat:            lat            ?? this.lat,
    lon:            lon            ?? this.lon,
    accuracy:       accuracy       ?? this.accuracy,
    confidence:     confidence     ?? this.confidence,
    lockResult:     lockResult     ?? this.lockResult,
    address:        address        ?? this.address,
    addressLoading: addressLoading ?? this.addressLoading,
    fromCache:      fromCache      ?? this.fromCache,
    lockProgress:   lockProgress   ?? this.lockProgress,
    isFastAddress:  isFastAddress  ?? this.isFastAddress,
    isFallbackLock: isFallbackLock ?? this.isFallbackLock,
    mode:           mode           ?? this.mode,
    resolvedLocation: resolvedLocation ?? this.resolvedLocation,
    mockDetected:   mockDetected   ?? this.mockDetected,
  );

  bool get hasPosition => lat != null && lon != null;
  // canCapture WAJIB false selama mock GPS terdeteksi, meskipun
  // confidence masih menyimpan nilai "good/excellent" dari sebelumnya.
  bool get canCapture  => confidence.canCapture && !mockDetected;
  bool get isStale     => mode == PodGpsMode.stale;
}

// ═══════════════════════════════════════════════════════════════
// SERVICE
// ═══════════════════════════════════════════════════════════════
class PodLocationService {
  // Singleton
  static final PodLocationService _instance = PodLocationService._internal();
  static PodLocationService get instance => _instance;
  PodLocationService._internal();

  // Dependencies
  final PodGpsEngine _gpsEngine = PodGpsEngine();

  StreamSubscription<Position>? _positionStream;
  Timer? _staleTimer;
  Timer? _acquireTimeout;

  // ── Config ───────────────────────────────────────────────────
  static const Duration _staleAfter      = Duration(minutes: 10);
  static const Duration _acquireDeadline = Duration(seconds: 12);
  static const String   _prefLat         = 'last_known_lat';
  static const String   _prefLon         = 'last_known_lon';
  static const String   _prefAddress     = 'last_known_address';
  static const int      _gridRes         = 10000;   // ~10m grid
  static const double   _geocodeMoveM    = 80.0;

  // ── State ───────────────────────────────────────────────────
  final _stateCtrl = BehaviorSubject<PodLocationState>.seeded(
    const PodLocationState(),
  );
  Stream<PodLocationState> get stream => _stateCtrl.stream;
  PodLocationState get currentState    => _stateCtrl.value;

  final Map<String, String> _geocodeCache = {};
  static const int _maxCache = 200;

  bool      _initialized    = false;
  bool      _geocodeDone    = false;
  double?   _lastGeocodeLat;
  double?   _lastGeocodeLon;

  // ── Init ────────────────────────────────────────────────────
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _loadCachedState();
    if (kDebugMode) debugPrint('PodLocationService: init (idle, no GPS stream)');
  }

  // ── acquireForCapture ───────────────────────────────────────
  Future<void> acquireForCapture() async {
    final mode = currentState.mode;

    if (mode == PodGpsMode.locked) {
      if (kDebugMode) debugPrint('PodLocationService: already locked, skip acquire');
      return;
    }

    if (mode == PodGpsMode.acquiring) {
      if (kDebugMode) debugPrint('PodLocationService: already acquiring');
      return;
    }

    if (!await _checkPermission()) {
      _emit(currentState.copyWith(
        confidence: PodConfidence.poor,
        address: 'Izin lokasi ditolak',
        mode: PodGpsMode.idle,
      ));
      return;
    }

    await _startAcquire();
  }

  // ── releaseAfterCapture ─────────────────────────────────────
  void releaseAfterCapture() {
    _stopStream();
    _cancelTimers();

    final mode = currentState.mode;
    if (mode == PodGpsMode.locked) {
      _scheduleStale();
    } else if (mode == PodGpsMode.acquiring) {
      final hasUsable = currentState.hasPosition && currentState.confidence.canCapture;
      _emit(currentState.copyWith(
        mode: hasUsable ? PodGpsMode.stale : PodGpsMode.idle,
      ));
      if (hasUsable) _scheduleStale();
    }
    if (kDebugMode) debugPrint('PodLocationService: released');
  }

  // ── forceRefresh ────────────────────────────────────────────
  Future<void> forceRefresh() async {
    _cancelTimers();
    _gpsEngine.reset();
    _geocodeDone    = false;
    _lastGeocodeLat = null;
    _lastGeocodeLon = null;
    await _startAcquire();
  }

  // ── awaitAddressReady ────────────────────────────────────────
  /// Menunggu sampai koordinat + alamat siap (atau timeout), lalu
  /// mengembalikan state saat itu. Dipakai layar kamera/scan untuk
  /// mengisi `ScanEntry.locationName` tanpa harus subscribe manual ke
  /// [stream]. Tidak pernah throw — jika timeout/gagal, mengembalikan
  /// [currentState] apa adanya (bisa saja tanpa alamat).
  Future<PodLocationState> awaitAddressReady({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final current = currentState;
    if (current.hasPosition && current.address.isNotEmpty) return current;
    try {
      return await stream
          .where((s) => s.hasPosition && s.address.isNotEmpty)
          .first
          .timeout(timeout, onTimeout: () => currentState);
    } catch (_) {
      return currentState;
    }
  }

  // ── dispose ─────────────────────────────────────────────────
  void dispose() {
    _cancelTimers();
    _stopStream();
    _stateCtrl.close();
    PodAddressResolver.close();
    _gpsEngine.dispose();
  }

  // ── INTERNAL: start acquire ──────────────────────────────────

  Future<void> _startAcquire() async {
    _stopStream();
    _gpsEngine.reset();
    _cancelTimers();

    _emit(currentState.copyWith(
      confidence:   PodConfidence.searching,
      lockProgress: 0.0,
      mode:         PodGpsMode.acquiring,
      mockDetected: false,
    ));

    // Inject OS cached position → instant preview
    try {
      final osLast = await Geolocator.getLastKnownPosition();
      if (osLast != null && osLast.isMocked) {
        if (kDebugMode) debugPrint('PodLocationService: lastKnownPosition adalah mock, abaikan');
      } else if (osLast != null) {
        _gpsEngine.processSample(osLast);
        _emit(currentState.copyWith(
          lat:            osLast.latitude,
          lon:            osLast.longitude,
          accuracy:       osLast.accuracy,
          confidence:     _gpsEngine.confidence,
          lockProgress:   _gpsEngine.lockProgress,
          isFallbackLock: _gpsEngine.isFallbackLock,
          mode:           PodGpsMode.acquiring,
        ));
        if (kDebugMode) {
          debugPrint('PodLocationService: OS lastKnown injected '
              'acc=${osLast.accuracy.toStringAsFixed(1)}m');
        }

        // ✅ FIX ALAMAT TIDAK MUNCUL: jangan tunggu event stream
        // pertama untuk mulai geocode — di indoor/gudang, stream bisa
        // lambat atau sample-nya keburu tidak memenuhi accuracyThreshold.
        // Koordinat OS cache ini sudah cukup untuk mulai reverse-geocode
        // di background; kalau nanti stream dapat posisi yang jauh
        // berbeda, _onPosition akan re-geocode via cek `movedFar`.
        if (!_geocodeDone) {
          _geocodeDone    = true;
          _lastGeocodeLat = osLast.latitude;
          _lastGeocodeLon = osLast.longitude;
          unawaited(_geocode(osLast.latitude, osLast.longitude));
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PodLocationService: getLastKnownPosition error $e');
    }

    // ── Platform‑specific location settings ──────────────────
    // Pastikan semua distanceFilter bertipe sesuai:
    // Android → int, iOS → double, fallback → int (konstan)
    LocationSettings settings;
    if (Platform.isAndroid) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: PodGpsEngine.distanceFilterAcquiring.toInt(), // ← int
        forceLocationManager: false,
      );
    } else if (Platform.isIOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: PodGpsEngine.distanceFilterAcquiring.toInt(), // ← int
        activityType: ActivityType.fitness,
      );
    } else {
      // Web / platform lain – gunakan int agar kompatibel dengan const
      settings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0, // int, bukan double
      );
    }

    _positionStream = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(_onPosition, onError: (e) {
      if (kDebugMode) debugPrint('PodLocationService: stream error $e');
    });

    _acquireTimeout = Timer(_acquireDeadline, _onAcquireTimeout);

    if (kDebugMode) debugPrint('PodLocationService: acquiring started');
  }

  void _onAcquireTimeout() {
    if (currentState.mode != PodGpsMode.acquiring) return;
    if (kDebugMode) debugPrint('PodLocationService: acquire timeout — force stop');
    _stopStream();
    _emit(currentState.copyWith(
      mode: currentState.confidence.canCapture
          ? PodGpsMode.locked
          : PodGpsMode.stale,
    ));
    if (currentState.confidence.canCapture) _scheduleStale();
  }

  // ── INTERNAL: position handler ───────────────────────────────

  void _onPosition(Position raw) async {
    if (currentState.mode != PodGpsMode.acquiring) return;

    if (raw.isMocked) {
      _stopStream();
      _emit(currentState.copyWith(
        confidence:   PodConfidence.poor,
        address:      '⚠️ GPS Mock terdeteksi — nonaktifkan aplikasi lokasi palsu',
        mode:         PodGpsMode.idle,
        mockDetected: true,
      ));
      if (kDebugMode) debugPrint('PodLocationService: mock GPS terdeteksi, blokir capture');
      return;
    }

    // Proses sample; return value tidak digunakan
    _gpsEngine.processSample(raw);

    final conf     = _gpsEngine.confidence;
    final lock     = _gpsEngine.lockResult;
    final progress = _gpsEngine.lockProgress;

    final lat = lock?.centroidLat ?? raw.latitude;
    final lon = lock?.centroidLon ?? raw.longitude;
    final acc = lock?.accuracy    ?? raw.accuracy;

    _emit(currentState.copyWith(
      lat:            lat,
      lon:            lon,
      accuracy:       acc,
      confidence:     conf,
      lockResult:     lock,
      lockProgress:   progress,
      isFallbackLock: _gpsEngine.isFallbackLock,
      mode:           PodGpsMode.acquiring,
    ));

    // ✅ FIX ALAMAT TIDAK MUNCUL: dulu geocode hanya dipicu kalau
    // conf.canCapture (confidence good/excellent, akurasi <=15m).
    // Di dalam gudang/gedung, GPS sering tidak pernah setepat itu —
    // bahkan banyak sample ditolak duluan oleh processSample() karena
    // akurasi >25m — sehingga confidence mentok di poor/fair selamanya
    // dan alamat tidak pernah di-resolve, walau lat/lon sudah ada
    // (makanya watermark cuma tampilkan koordinat). Reverse-geocoding
    // tidak butuh presisi setinggi capture; cukup ada posisi valid.
    // Geocode sekarang dipicu begitu ada lat/lon pertama kali ATAU
    // sudah bergerak > _geocodeMoveM dari titik geocode terakhir.
    final movedFar = _geocodeDone &&
        _lastGeocodeLat != null &&
        PodGpsEngine.haversinePublic(
            _lastGeocodeLat!, _lastGeocodeLon!, lat, lon) > _geocodeMoveM;

    if (!_geocodeDone || movedFar) {
      _geocodeDone    = true;
      _lastGeocodeLat = lat;
      _lastGeocodeLon = lon;
      unawaited(_geocode(lat, lon));
    }

    // Locked → stop stream
    if (_gpsEngine.isLocked) {
      _cancelTimers();
      _stopStream();
      _emit(currentState.copyWith(mode: PodGpsMode.locked));
      _scheduleStale();
      if (kDebugMode) {
        debugPrint('PodLocationService: locked acc=${acc.toStringAsFixed(1)}m');
      }
    }
  }

  // ── Stale timer ─────────────────────────────────────────────

  void _scheduleStale() {
    _staleTimer?.cancel();
    _staleTimer = Timer(_staleAfter, () {
      if (currentState.mode == PodGpsMode.locked) {
        _emit(currentState.copyWith(mode: PodGpsMode.stale));
        if (kDebugMode) debugPrint('PodLocationService: lock stale after $_staleAfter');
      }
    });
  }

  // ── Geocode ──────────────────────────────────────────────────

  Future<void> _geocode(double lat, double lon) async {
    final key = _gridKey(lat, lon);
    if (_geocodeCache.containsKey(key)) {
      _emit(currentState.copyWith(
        address:        _geocodeCache[key]!,
        fromCache:      true,
        addressLoading: false,
      ));
      return;
    }

    _emit(currentState.copyWith(addressLoading: true));
    try {
      final resolved = await PodAddressResolver.resolveDetailed(lat, lon);
      final address = resolved.display;
      if (address.isNotEmpty && !resolved.isDmsFallback) {
        _geocodeCache[key] = address;
        if (_geocodeCache.length > _maxCache) {
          final remove = _geocodeCache.keys.take(50).toList();
          for (final k in remove) _geocodeCache.remove(k);
        }
        await _saveLastKnown(lat, lon, address);
      }
      _emit(currentState.copyWith(
        address:          address,
        resolvedLocation: resolved,
        fromCache:        false,
        addressLoading:   false,
        isFastAddress:    false,
      ));
      if (kDebugMode) debugPrint('PodLocationService: geocode → $address');
    } catch (e) {
      if (kDebugMode) debugPrint('PodLocationService: geocode error $e');
      _emit(currentState.copyWith(addressLoading: false));
    }
  }

  // ── Cache load/save ──────────────────────────────────────────

  Future<void> _loadCachedState() async {
    try {
      final prefs   = await SharedPreferences.getInstance();
      final lat     = prefs.getDouble(_prefLat);
      final lon     = prefs.getDouble(_prefLon);
      final address = prefs.getString(_prefAddress);

      if (lat != null && lon != null && address != null && address.isNotEmpty) {
        final key = _gridKey(lat, lon);
        _geocodeCache[key] = address;
        _geocodeDone    = true;
        _lastGeocodeLat = lat;
        _lastGeocodeLon = lon;

        _emit(currentState.copyWith(
          lat:           lat,
          lon:           lon,
          address:       address,
          fromCache:     true,
          isFastAddress: true,
          confidence:    PodConfidence.fair,
          mode:          PodGpsMode.stale,
        ));
        if (kDebugMode) debugPrint('PodLocationService: cache loaded → $address');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PodLocationService: load cache error $e');
    }
  }

  Future<void> _saveLastKnown(double lat, double lon, String address) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setDouble(_prefLat, lat),
        prefs.setDouble(_prefLon, lon),
        prefs.setString(_prefAddress, address),
      ]);
    } catch (e) {
      if (kDebugMode) debugPrint('PodLocationService: save error $e');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────

  Future<bool> _checkPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm != LocationPermission.denied &&
           perm != LocationPermission.deniedForever;
  }

  void _stopStream() {
    _positionStream?.cancel();
    _positionStream = null;
  }

  void _cancelTimers() {
    _staleTimer?.cancel();
    _staleTimer = null;
    _acquireTimeout?.cancel();
    _acquireTimeout = null;
  }

  String _gridKey(double lat, double lon) {
    final gLat = (lat * _gridRes).round();
    final gLon = (lon * _gridRes).round();
    return '$gLat,$gLon';
  }

  void _emit(PodLocationState state) {
    if (!_stateCtrl.isClosed) _stateCtrl.add(state);
  }
}
