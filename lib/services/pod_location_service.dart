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
//   - Geocode: hanya fetch ulang jika bergerak >30m dari cache
// ============================================================

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pod_gps_engine.dart';
import 'pod_address_resolver.dart';
import 'gnss_quality_service.dart';
import 'pod_native_location_service.dart';
import '../models/resolved_location.dart';
import '../watermark/models/watermark_data.dart';

export 'pod_gps_engine.dart' show PodConfidence, PodConfidenceLabel, PodLockResult;

// ── Status mode service ───────────────────────────────────────
enum PodGpsMode {
  idle,       // GPS off, tampilkan cache jika ada
  acquiring,  // Stream aktif rate penuh, sedang mengumpul sample awal
  tracking,   // BARU — sudah lock, stream TETAP hidup di interval
              // rendah (lihat _trackingMinInterval) untuk refinement &
              // deteksi drift latar belakang. Evidence tetap dianggap
              // "ready" sama seperti `locked` (lihat isEvidenceReady).
  locked,     // Sudah lock, stream sudah berhenti (tidak ada capture
              // owner aktif — lihat releaseAfterCapture)
  stale,      // Lock lama > _staleAfter, perlu re-acquire
}

// ── State ────────────────────────────────────────────────────
class PodLocationState {
  static const Duration evidenceMaxAge = Duration(seconds: 30);
  static const double addressMatchRadiusMeters = 30.0;

  // ── Evidence max age adaptif (BARU) ──────────────────────────
  // Sample yang direkam saat device masih bergerak jadi basi (secara
  // lokasi, bukan cuma waktu) lebih cepat daripada sample yang direkam
  // saat diam — kurir yang terus jalan bisa sudah puluhan meter dari
  // titik fix dalam 30 detik. [evidenceMaxAgeMoving] mempersempit
  // jendela freshness untuk kasus itu. Ambang "bergerak" disamakan
  // dengan GpsConfig.maxPlausibleStationarySpeedMps (3.0 m/s, ~10.8
  // km/h — longgar utk jalan kaki bawa paket) supaya konsisten dengan
  // velocity gate di PodGpsEngine.
  static const Duration evidenceMaxAgeMoving = Duration(seconds: 10);
  static const double movingSpeedThresholdMps = 3.0;

  final double? lat;
  final double? lon;
  final double? accuracy;
  final DateTime? positionTimestamp;
  final bool positionFromCache;
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

  /// true jika PodGpsEngine mencurigai spoofing lewat heuristik lanjutan
  /// (teleport speed, timestamp mundur, 0 satelit tapi ada fix, accuracy
  /// vs HDOP tidak konsisten, atau streak fix identik persis) —
  /// terpisah dari [mockDetected] (flag eksplisit OS) karena ini
  /// berbasis kecurigaan, bukan kepastian dari sistem operasi.
  final bool spoofSuspected;
  final double? addressLat;
  final double? addressLon;

  /// true jika native side sedang mengirim data GNSS (Android saja)
  /// DAN confidence belum tembus "good/excellent" karena jumlah
  /// satelit/C-N0 belum memenuhi ambang (bukan karena accuracy OS).
  /// UI bisa memakai ini untuk pesan yang lebih akurat daripada
  /// sekadar "mencari sinyal", misal "sinyal GNSS masih lemah —
  /// coba dekat jendela/area terbuka".
  final bool gnssGateActive;

  /// true jika device terdeteksi masih bergerak (kecepatan Doppler
  /// dari chip GPS di atas ambang diam) DAN itu satu-satunya alasan
  /// confidence belum tembus good/excellent (accuracy/GNSS sudah oke).
  /// UI bisa memakai ini untuk pesan "berhenti dulu untuk mengunci
  /// lokasi" — lihat Velocity Filter di GpsConfig.
  final bool velocityGateActive;

  /// Kecepatan Doppler (raw.speed, m/s) dari sample GPS terakhir yang
  /// dipakai untuk posisi ini — null kalau OS tidak melaporkan speed
  /// yang cukup dipercaya (lihat [PodSample.hasReliableSpeed]). Dipakai
  /// untuk membuat [evidenceMaxAge] adaptif — lihat [hasFreshPosition].
  final double? speedMps;

  const PodLocationState({
    this.lat,
    this.lon,
    this.accuracy,
    this.positionTimestamp,
    this.positionFromCache = false,
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
    this.spoofSuspected = false,
    this.addressLat,
    this.addressLon,
    this.gnssGateActive = false,
    this.velocityGateActive = false,
    this.speedMps,
  });

  PodLocationState copyWith({
    double? lat,
    double? lon,
    double? accuracy,
    DateTime? positionTimestamp,
    bool? positionFromCache,
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
    bool? spoofSuspected,
    double? addressLat,
    double? addressLon,
    bool? gnssGateActive,
    bool? velocityGateActive,
    double? speedMps,
    bool clearPosition = false,
    bool clearAddress = false,
    bool clearLockResult = false,
  }) => PodLocationState(
    lat:            clearPosition ? null : lat ?? this.lat,
    lon:            clearPosition ? null : lon ?? this.lon,
    accuracy:       clearPosition ? null : accuracy ?? this.accuracy,
    positionTimestamp:
        clearPosition ? null : positionTimestamp ?? this.positionTimestamp,
    positionFromCache: clearPosition
        ? false
        : positionFromCache ?? this.positionFromCache,
    confidence:     confidence     ?? this.confidence,
    lockResult:     clearLockResult ? null : lockResult ?? this.lockResult,
    address:        clearAddress ? '' : address ?? this.address,
    addressLoading: addressLoading ?? this.addressLoading,
    fromCache:      fromCache      ?? this.fromCache,
    lockProgress:   lockProgress   ?? this.lockProgress,
    isFastAddress:  isFastAddress  ?? this.isFastAddress,
    isFallbackLock: isFallbackLock ?? this.isFallbackLock,
    mode:           mode           ?? this.mode,
    resolvedLocation:
        clearAddress ? null : resolvedLocation ?? this.resolvedLocation,
    mockDetected:   mockDetected   ?? this.mockDetected,
    spoofSuspected: spoofSuspected ?? this.spoofSuspected,
    addressLat:     clearAddress ? null : addressLat ?? this.addressLat,
    addressLon:     clearAddress ? null : addressLon ?? this.addressLon,
    gnssGateActive: gnssGateActive ?? this.gnssGateActive,
    velocityGateActive: velocityGateActive ?? this.velocityGateActive,
    speedMps:       clearPosition ? null : speedMps ?? this.speedMps,
  );

  bool get hasPosition => lat != null && lon != null;
  // canCapture WAJIB false selama mock/spoof GPS terdeteksi, meskipun
  // confidence masih menyimpan nilai "good/excellent" dari sebelumnya.
  bool get canCapture  => confidence.canCapture && !mockDetected && !spoofSuspected;
  bool get isStale     => mode == PodGpsMode.stale;

  /// ⭐ BARU: jendela freshness adaptif — dipersempit ke
  /// [evidenceMaxAgeMoving] kalau sample terakhir menunjukkan device
  /// masih bergerak di atas [movingSpeedThresholdMps]. `speedMps` null
  /// (OS tidak melaporkan speed yang dipercaya) → fallback aman ke
  /// [evidenceMaxAge] biasa, sama seperti pola gate lain di engine.
  Duration get _effectiveEvidenceMaxAge {
    final speed = speedMps;
    if (speed != null && speed > movingSpeedThresholdMps) {
      return evidenceMaxAgeMoving;
    }
    return evidenceMaxAge;
  }

  bool get hasFreshPosition {
    final timestamp = positionTimestamp;
    if (!hasPosition || timestamp == null || positionFromCache) return false;
    final age = DateTime.now().difference(timestamp);
    return age >= const Duration(seconds: -5) && age <= _effectiveEvidenceMaxAge;
  }

  bool get isEvidenceReady =>
      hasFreshPosition &&
      canCapture &&
      mode != PodGpsMode.idle &&
      mode != PodGpsMode.stale;

  bool get hasMatchingAddress {
    if (!hasPosition ||
        address.isEmpty ||
        addressLat == null ||
        addressLon == null) {
      return false;
    }
    return PodGpsEngine.haversinePublic(
          lat!,
          lon!,
          addressLat!,
          addressLon!,
        ) <=
        addressMatchRadiusMeters;
  }

  String get evidenceAddress => hasMatchingAddress ? address : '';
}

enum _LocationAccessStatus {
  granted,
  serviceDisabled,
  denied,
  deniedForever,
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
  final GnssQualityService _gnssQuality = GnssQualityService.instance;
  final PodNativeLocationService _nativeLocation =
      PodNativeLocationService.instance;

  // true selama acquisition berjalan lewat native FusedLocationProviderClient
  // bridge (Android). Dipakai supaya _onAcquireTimeout/_stopStream tahu path
  // mana yang aktif kalau nanti perlu logging/diagnostik terpisah.
  bool _usingNativeStream = false;

  // Data GNSS dianggap terlalu basi untuk dipasangkan dengan sample
  // posisi jika lebih tua dari ini — mencegah quality lama (misal dari
  // sesaat sebelum tersembunyi di balik gedung) menempel ke sample baru.
  static const Duration _gnssQualityMaxAge = Duration(seconds: 3);

  StreamSubscription<Position>? _positionStream;
  Timer? _staleTimer;
  Timer? _acquireTimeout;
  final Set<Object> _captureOwners = <Object>{};

  // ── Tracking mode (BARU) ─────────────────────────────────────
  // Kapan sample terakhir DIPROSES (bukan diterima — lihat _onPosition)
  // selama mode tracking. null berarti belum ada sample tracking yang
  // diproses sejak masuk tracking (throttle lolos untuk sample pertama).
  DateTime? _lastTrackingSampleAt;

  // ── Config ───────────────────────────────────────────────────
  static const Duration _staleAfter      = PodLocationState.evidenceMaxAge;
  static const Duration _acquireDeadline = Duration(seconds: 14);
  static const String   _prefLat         = 'last_known_lat';
  static const String   _prefLon         = 'last_known_lon';
  static const String   _prefAddress     = 'last_known_address';
  static const String   _prefTimestamp   = 'last_known_timestamp';
  static const Duration _cachedPreviewMaxAge = Duration(hours: 24);
  static const int      _gridRes         = 10000;   // ~10m grid
  static const double   _geocodeMoveM    = 80.0;

  // ── Tracking mode config (BARU, Priority 1) ─────────────────
  // Setelah lock pertama, stream TIDAK lagi dihentikan total begitu
  // capture masih berlangsung (owner masih aktif) — sebelumnya
  // _onPosition langsung _stopStream() begitu isLocked, artinya:
  //   (a) tidak ada cara mendeteksi device bergerak menjauh dari titik
  //       lock sampai capture BERIKUTNYA memanggil acquireForCapture()
  //       dari nol lagi, dan
  //   (b) tidak ada kesempatan sample yang lebih baik masuk untuk
  //       me-refine lock sebelum watermark benar-benar dibakar
  //       (lihat refineSnapshot, Priority 3).
  // Sekarang begitu lock tercapai, service pindah ke mode `tracking`:
  // stream tetap hidup tapi di-throttle ke interval rendah supaya
  // tidak menyamai boros baterainya fase akuisisi awal. Throttle
  // diterapkan di level Dart (_lastTrackingSampleAt, berlaku untuk
  // SEMUA jalur termasuk native FusedLocationProviderClient yang rate
  // request-nya tidak bisa diatur dari Dart) — pada jalur geolocator
  // (iOS, atau Android tanpa native bridge) request rate SUMBER juga
  // ikut dilonggarkan (lihat _buildTrackingSettings) untuk penghematan
  // baterai yang lebih nyata, bukan cuma throttle di sisi Dart.
  static const Duration _trackingMinInterval = Duration(seconds: 3);
  static const double   _trackingDistanceFilterMeters = 8.0;

  // ── State ───────────────────────────────────────────────────
  final _stateCtrl = BehaviorSubject<PodLocationState>.seeded(
    const PodLocationState(),
  );
  Stream<PodLocationState> get stream => _stateCtrl.stream;
  PodLocationState get currentState    => _stateCtrl.value;

  final Map<String, String> _geocodeCache = {};
  static const int _maxCache = 200;

  bool      _initialized    = false;
  Future<void>? _initializing;
  bool      _geocodeDone    = false;
  double?   _lastGeocodeLat;
  double?   _lastGeocodeLon;
  int       _acquisitionGeneration = 0;
  int       _latestGeocodeRequest = 0;

  // ── Init ────────────────────────────────────────────────────
  Future<void> init() async {
    if (_initialized) return;
    final pending = _initializing;
    if (pending != null) return pending;

    final operation = _loadCachedState();
    _initializing = operation;
    try {
      await operation;
      _initialized = true;
      if (kDebugMode) {
        debugPrint('PodLocationService: init (idle, no GPS stream)');
      }
    } finally {
      _initializing = null;
    }
  }

  // ── acquireForCapture ───────────────────────────────────────
  Future<void> acquireForCapture({Object? owner}) async {
    await init();
    if (owner != null) _captureOwners.add(owner);
    final mode = currentState.mode;

    // ⭐ BARU: mode `tracking` juga dianggap sudah punya evidence siap
    // pakai — stream latar belakangnya sendiri yang terus menjaga
    // kesegarannya (lihat _onPosition/_scheduleStale), jadi tidak perlu
    // acquire dari nol.
    if ((mode == PodGpsMode.locked || mode == PodGpsMode.tracking) &&
        currentState.isEvidenceReady) {
      if (kDebugMode) {
        debugPrint('PodLocationService: already $mode, skip acquire');
      }
      return;
    }

    if (mode == PodGpsMode.acquiring) {
      if (kDebugMode) debugPrint('PodLocationService: already acquiring');
      return;
    }

    final access = await _checkPermission();
    if (access != _LocationAccessStatus.granted) {
      final message = switch (access) {
        _LocationAccessStatus.serviceDisabled => 'Layanan lokasi nonaktif',
        _LocationAccessStatus.deniedForever =>
          'Izin lokasi ditolak permanen — buka pengaturan',
        _LocationAccessStatus.denied => 'Izin lokasi ditolak',
        _LocationAccessStatus.granted => '',
      };
      _emit(PodLocationState(
        confidence: PodConfidence.poor,
        address: message,
        mode: PodGpsMode.idle,
      ));
      return;
    }

    await _startAcquire();
  }

  // ── releaseAfterCapture ─────────────────────────────────────
  void releaseAfterCapture({Object? owner}) {
    if (owner != null) _captureOwners.remove(owner);
    if (_captureOwners.isNotEmpty) {
      if (kDebugMode) {
        debugPrint(
          'PodLocationService: release ditunda, ${_captureOwners.length} owner aktif',
        );
      }
      return;
    }
    _stopStream();
    _cancelTimers();
    _lastTrackingSampleAt = null;

    final mode = currentState.mode;
    if (mode == PodGpsMode.locked || mode == PodGpsMode.tracking) {
      // ⭐ BARU: owner terakhir baru saja lepas — stream tracking latar
      // belakang (kalau sedang aktif) sudah dihentikan di atas. Turunkan
      // label mode ke `locked` (statis, tidak ada stream) supaya
      // konsisten dengan kondisi sebenarnya sebelum stale timer jalan.
      if (mode == PodGpsMode.tracking) {
        _emit(currentState.copyWith(mode: PodGpsMode.locked));
      }
      _scheduleStale();
    } else if (mode == PodGpsMode.acquiring) {
      final hasUsable = currentState.isEvidenceReady;
      _emit(currentState.copyWith(
        mode: hasUsable ? PodGpsMode.stale : PodGpsMode.idle,
      ));
      if (hasUsable) _scheduleStale();
    }
    if (kDebugMode) debugPrint('PodLocationService: released');
  }

  // ── forceRefresh ────────────────────────────────────────────
  Future<void> forceRefresh() async {
    await init();
    _stopStream();
    _cancelTimers();
    _lastTrackingSampleAt = null;
    _gpsEngine.reset();
    _acquisitionGeneration++;
    _latestGeocodeRequest++;
    final hasPreview = currentState.hasPosition;
    _emit(currentState.copyWith(
      mode: hasPreview ? PodGpsMode.stale : PodGpsMode.idle,
      positionFromCache: hasPreview,
      mockDetected: false,
      spoofSuspected: false,
      clearLockResult: true,
      clearAddress: !currentState.hasMatchingAddress,
    ));
    await acquireForCapture();
  }

  // ── awaitEvidenceReady ───────────────────────────────────────
  /// Menunggu snapshot lokasi fresh yang aman dipakai sebagai bukti.
  /// Alamat ditunggu selama masih ada waktu, tetapi koordinat fresh tetap
  /// dikembalikan saat enrichment alamat melewati timeout.
  /// ✅ Default diturunkan dari 15 → 12 detik: skenario terburuk GPS
  /// engine sendiri sekarang cuma 10 detik (indoor force-lock timeout,
  /// lihat GpsConfig.indoorTimeout), jadi 12 detik sudah termasuk buffer
  /// untuk propagasi state — 15 detik dulu adalah sisa slack dari
  /// sebelum engine dipercepat (dulu indoor timeout 15 detik).
  Future<PodLocationState?> awaitEvidenceReady({
    Duration timeout = const Duration(seconds: 12),
    bool requireAddress = true,
  }) async {
    final deadline = DateTime.now().add(timeout);
    try {
      await acquireForCapture();

      PodLocationState evidence;
      final current = currentState;
      if (current.isEvidenceReady) {
        evidence = current;
      } else {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) return null;
        evidence = await stream
            .where((s) => s.isEvidenceReady)
            .first
            .timeout(remaining);
      }

      if (!requireAddress || evidence.hasMatchingAddress) return evidence;

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        final latest = currentState;
        return latest.isEvidenceReady ? latest : null;
      }
      try {
        return await stream
            .where((s) => s.isEvidenceReady && s.hasMatchingAddress)
            .first
            .timeout(remaining);
      } on TimeoutException {
        final latest = currentState;
        return latest.isEvidenceReady ? latest : null;
      }
    } catch (_) {
      final latest = currentState;
      return latest.isEvidenceReady ? latest : null;
    }
  }

  // ── refineSnapshot (BARU, Priority 3) ─────────────────────────
  /// Background refinement SEBELUM watermark difinalisasi.
  ///
  /// [original] adalah snapshot [WatermarkData] yang SUDAH DIBEKUKAN
  /// (@immutable — lihat catatan di watermark_data.dart) tepat saat
  /// shutter ditekan. Method ini TIDAK PERNAH memutasi [original] —
  /// dan tidak perlu, karena [WatermarkData] memang immutable. Selama
  /// [deadline] (default singkat, jauh lebih pendek dari
  /// [awaitEvidenceReady]), method ini menunggu kemungkinan fix yang
  /// LEBIH BAIK datang dari stream tracking latar belakang (lihat
  /// _enterTrackingMode/Priority 1) — kalau ada & lolos sanity check,
  /// dikembalikan sebagai OBJEK BARU lewat `original.copyWith(...)`.
  /// Kalau tidak ada perbaikan yang layak dalam batas waktu, method ini
  /// mengembalikan [original] APA ADANYA (referensi yang sama persis).
  ///
  /// Efeknya: mekanisme rollback yang sudah ada (CameraCaptureResult →
  /// liveSnapshot dipakai langsung tanpa query ulang) TIDAK terganggu
  /// sama sekali — pemanggil selalu punya nilai valid untuk dipakai;
  /// "rollback" ke snapshot asli terjadi otomatis begitu saja (bukan
  /// lewat try/catch atau flag terpisah) karena kegagalan refine =
  /// method ini mengembalikan objek yang sama dengan yang diberikan.
  ///
  /// Sanity check terhadap [original]:
  ///   - kandidat WAJIB confidence == excellent (tier tertinggi) —
  ///     tidak ada gunanya mengganti snapshot yang sudah dipakai
  ///     dengan sesuatu yang belum tentu lebih baik.
  ///   - kandidat WAJIB dalam [maxDriftMeters] dari titik [original] —
  ///     mencegah refinement diam-diam memakai fix dari lokasi BARU
  ///     (mis. operator sudah mulai jalan ke barang berikutnya, tapi
  ///     sample sisa capture sebelumnya baru sempat masuk sekarang).
  ///   - kandidat WAJIB bukan mock/spoof.
  Future<WatermarkData> refineSnapshot(
    WatermarkData original, {
    Duration deadline = const Duration(milliseconds: 1200),
    double maxDriftMeters = 15.0,
  }) async {
    final baseLat = original.latitude;
    final baseLon = original.longitude;
    if (baseLat == null || baseLon == null) return original;

    WatermarkData best = original;
    var tookAny = false;

    bool tryAccept(PodLocationState s) {
      if (tookAny) return false; // sekali dapat excellent, cukup
      if (!s.hasPosition || s.confidence != PodConfidence.excellent) {
        return false;
      }
      if (s.mockDetected || s.spoofSuspected) return false;
      final drift = PodGpsEngine.haversinePublic(baseLat, baseLon, s.lat!, s.lon!);
      if (drift > maxDriftMeters) return false;

      best = original.copyWith(
        latitude: s.lat,
        longitude: s.lon,
        locationName:
            s.hasMatchingAddress ? s.evidenceAddress : original.locationName,
      );
      tookAny = true;
      if (kDebugMode) {
        debugPrint(
          'PodLocationService: refineSnapshot upgrade — drift=${drift.toStringAsFixed(1)}m, '
          'acc=${s.accuracy?.toStringAsFixed(1) ?? "-"}m',
        );
      }
      return true;
    }

    // Cek state SAAT INI dulu — barangkali refinement sudah kejadian
    // sebelum fungsi ini sempat dipanggil (mis. selama jeda copy-to-
    // pending/kompresi di pipeline pemanggil, yang berjalan konkuren
    // dengan tracking stream).
    if (tryAccept(currentState)) return best;

    final deadlineAt = DateTime.now().add(deadline);
    final remaining = deadlineAt.difference(DateTime.now());
    if (remaining <= Duration.zero) return best;

    final completer = Completer<void>();
    late final StreamSubscription<PodLocationState> sub;
    sub = stream.listen((s) {
      if (tryAccept(s) && !completer.isCompleted) completer.complete();
    });
    final timer = Timer(remaining, () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    timer.cancel();
    await sub.cancel();
    return best;
  }

  // ── dispose ─────────────────────────────────────────────────
  void dispose() {
    _cancelTimers();
    _stopStream();
    _stateCtrl.close();
    PodAddressResolver.close();
    _gpsEngine.dispose();
    _gnssQuality.dispose();
  }

  // ── INTERNAL: start acquire ──────────────────────────────────

  Future<void> _startAcquire() async {
    final generation = ++_acquisitionGeneration;
    _stopStream();
    _gpsEngine.reset();
    _cancelTimers();
    _gnssQuality.start();
    _geocodeDone = false;
    _lastGeocodeLat = null;
    _lastGeocodeLon = null;
    _latestGeocodeRequest++;

    _emit(currentState.copyWith(
      confidence:   PodConfidence.searching,
      lockProgress: 0.0,
      mode:         PodGpsMode.acquiring,
      mockDetected: false,
      spoofSuspected: false,
      positionFromCache: currentState.hasPosition,
      clearLockResult: true,
      clearAddress: !currentState.hasMatchingAddress,
    ));

    // Inject cached position → instant preview.
    // ✅ NATIVE FIX: di Android, cache FusedLocationProviderClient
    // (via getLastLocation() native) digabung dari SEMUA app yang minta
    // lokasi di device, biasanya lebih segar dari
    // Geolocator.getLastKnownPosition() yang cuma cache app ini sendiri.
    // Fallback ke geolocator kalau native null (belum pernah ada fix
    // sama sekali, atau device tanpa Play Services).
    try {
      final osLast = await _getCachedPreviewPosition();
      if (osLast != null && osLast.isMocked) {
        _emit(const PodLocationState(
          confidence: PodConfidence.poor,
          address: '⚠️ GPS Mock terdeteksi — menunggu lokasi asli',
          mode: PodGpsMode.acquiring,
          mockDetected: true,
        ));
        if (kDebugMode) {
          debugPrint(
            'PodLocationService: lastKnownPosition adalah mock, menunggu sample live',
          );
        }
      } else if (osLast != null &&
          _isTimestampWithin(osLast.timestamp, _cachedPreviewMaxAge)) {
        if (generation != _acquisitionGeneration) return;
        // ⚠️ JANGAN processSample(osLast) ke _gpsEngine.
        // OS lastKnownPosition cuma untuk preview instan di UI. Kalau
        // dimasukkan ke _window, dia ikut kehitung di weighted centroid
        // dan bisa jadi bahan _forceLock() (fallback saat timeout) —
        // artinya koordinat FINAL (yang dipakai watermark/POD) bisa
        // berasal dari cache basi, bukan sample GPS live. Engine wajib
        // mulai murni dari sample live.
        _emit(currentState.copyWith(
          lat:            osLast.latitude,
          lon:            osLast.longitude,
          accuracy:       osLast.accuracy,
          positionTimestamp: osLast.timestamp,
          positionFromCache: true,
          confidence:     PodConfidence.searching,
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
        _requestGeocode(
          osLast.latitude,
          osLast.longitude,
          generation,
          osLast.timestamp,
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PodLocationService: getLastKnownPosition error $e');
    }

    // ── Platform‑specific location settings ──────────────────
    // Pastikan semua distanceFilter bertipe sesuai:
    // Android → int, iOS → double, fallback → int (konstan)
    //
    // ✅ FIX AKURASI: accuracy dinaikkan dari `.high` → `.bestForNavigation`.
    // Di Android ini efeknya nol (baik `.high` maupun `.bestForNavigation`
    // sama-sama dipetakan geolocator ke PRIORITY_HIGH_ACCURACY — Android
    // cuma punya 4 tingkat prioritas, jadi `.high` sudah maksimal). Tapi
    // di iOS `.high` dipetakan ke kCLLocationAccuracyNearestTenMeters —
    // secara EKSPLISIT membatasi presisi ke sekitar 10m sebagai lantai,
    // padahal excellentThreshold engine ini justru 10m. Akibatnya sample
    // dari iOS nyaris mustahil pernah menembus tier "excellent", dan
    // turut menyumbang selisih puluhan meter yang dilaporkan. Tidak ada
    // dampak baterai berarti karena acquisition di sini selalu singkat
    // (stream berhenti begitu lock, bukan tracking berkelanjutan).
    // intervalDuration/timeLimit sengaja TIDAK diset (null) — nilai null
    // berarti geolocator TIDAK menerapkan filter interval sama sekali,
    // jadi update datang secepat chip GPS mengirim (umumnya 1Hz, standar
    // hardware GPS konsumen) tanpa throttle tambahan dari kita.
    final settings = _buildAcquiringSettings();

    if (generation != _acquisitionGeneration) return;
    _startPositionStream(generation, settings);

    _acquireTimeout =
        Timer(_acquireDeadline, () => _onAcquireTimeout(generation));

    if (kDebugMode) debugPrint('PodLocationService: acquiring started');
  }

  // ── Location settings builders ──────────────────────────────
  //
  // ✅ FIX AKURASI: accuracy dinaikkan dari `.high` → `.bestForNavigation`
  // untuk fase akuisisi. Di Android ini efeknya nol (baik `.high` maupun
  // `.bestForNavigation` sama-sama dipetakan geolocator ke
  // PRIORITY_HIGH_ACCURACY — Android cuma punya 4 tingkat prioritas,
  // jadi `.high` sudah maksimal). Tapi di iOS `.high` dipetakan ke
  // kCLLocationAccuracyNearestTenMeters — secara EKSPLISIT membatasi
  // presisi ke sekitar 10m sebagai lantai, padahal excellentThreshold
  // engine ini justru 10m. intervalDuration/timeLimit sengaja TIDAK
  // diset (null) saat akuisisi — nilai null berarti geolocator TIDAK
  // menerapkan filter interval sama sekali, update datang secepat chip
  // GPS mengirim (umumnya 1Hz).
  LocationSettings _buildAcquiringSettings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: PodGpsEngine.distanceFilterAcquiring.toInt(), // ← int
        forceLocationManager: false,
      );
    } else if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: PodGpsEngine.distanceFilterAcquiring.toInt(), // ← int
        activityType: ActivityType.fitness,
      );
    }
    // Web / platform lain – gunakan int agar kompatibel dengan const
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0, // int, bukan double
    );
  }

  // ── Tracking settings (BARU, Priority 1) ────────────────────
  // Dipakai HANYA pada jalur geolocator (bukan native fused — lihat
  // catatan _trackingMinInterval). accuracy diturunkan ke `.high`
  // (masih jauh lebih dari cukup untuk mendeteksi drift beberapa
  // meter) dan distanceFilter/intervalDuration dilonggarkan supaya
  // request ke chip GPS sendiri lebih jarang — penghematan baterai
  // yang nyata untuk sesi tracking latar belakang yang bisa berjalan
  // lama (selama capture owner masih aktif).
  LocationSettings _buildTrackingSettings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _trackingDistanceFilterMeters.toInt(),
        intervalDuration: _trackingMinInterval,
        forceLocationManager: false,
      );
    } else if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _trackingDistanceFilterMeters.toInt(),
        activityType: ActivityType.fitness,
      );
    }
    return LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: _trackingDistanceFilterMeters.toInt(),
    );
  }

  // ── Position stream: native FusedLocationProviderClient (Android)
  //    dengan fallback ke geolocator ─────────────────────────────
  //
  // Kenapa native, bukan langsung geolocator, di Android: geolocator
  // TIDAK mengekspos `setWaitForAccurateLocation(true)`, opsi yang
  // mencegah FusedLocationProviderClient mengirim estimasi kasar
  // (network/cell-based) sebagai callback pertama — sample seperti itu
  // kalau lolos masuk _window bisa mengotori centroid awal. Lihat
  // android/.../FusedLocationStreamHandler.kt.
  //
  // Fallback ke geolocator terjadi kalau: platform bukan Android, atau
  // native stream melempar error (device tanpa Play Services / channel
  // gagal) — supaya acquisition tidak macet total hanya karena bridge
  // native bermasalah di device tertentu.
  void _startPositionStream(int generation, LocationSettings settings) {
    if (Platform.isAndroid && _nativeLocation.isSupported) {
      _usingNativeStream = true;
      _positionStream = _nativeLocation.positionStream
          .map(_nativeToPosition)
          .listen(
        (position) => _onPosition(position, generation),
        onError: (Object e) {
          if (kDebugMode) {
            debugPrint(
              'PodLocationService: native fused stream error $e — '
              'fallback ke geolocator',
            );
          }
          if (generation != _acquisitionGeneration) return;
          _positionStream?.cancel();
          _usingNativeStream = false;
          _startGeolocatorStream(generation, settings);
        },
      );
    } else {
      _startGeolocatorStream(generation, settings);
    }
  }

  void _startGeolocatorStream(int generation, LocationSettings settings) {
    _usingNativeStream = false;
    _positionStream = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen((position) => _onPosition(position, generation), onError: (e) {
      if (kDebugMode) debugPrint('PodLocationService: stream error $e');
    });
  }

  Future<Position?> _getCachedPreviewPosition() async {
    if (Platform.isAndroid && _nativeLocation.isSupported) {
      final native = await _nativeLocation.getLastLocation();
      if (native != null) return _nativeToPosition(native);
    }
    return Geolocator.getLastKnownPosition();
  }

  /// Adapter NativeFusedPosition → geolocator Position, supaya seluruh
  /// pipeline hilir (PodGpsEngine.processSample, _onPosition, spoof
  /// heuristics) TIDAK perlu tahu/berubah soal sumber sample-nya.
  /// Hanya field yang benar-benar dipakai hilir (lat/lon/accuracy/
  /// timestamp/isMocked/speed/speedAccuracy) yang punya makna asli;
  /// altitude/heading/floor diisi placeholder karena tidak pernah
  /// dibaca oleh PodGpsEngine atau PodLocationService.
  Position _nativeToPosition(NativeFusedPosition native) {
    return Position(
      latitude: native.latitude,
      longitude: native.longitude,
      timestamp: native.timestamp,
      accuracy: native.accuracy,
      altitude: native.altitude ?? 0.0,
      altitudeAccuracy: 0.0,
      heading: native.bearing ?? 0.0,
      headingAccuracy: 0.0,
      speed: native.speed ?? 0.0,
      // speedAccuracy<=0 sudah konsisten berarti "tidak dipercaya" di
      // seluruh pipeline hilir (lihat NativeFusedPosition.hasReliableSpeed
      // dan PodSample.hasReliableSpeed) — diteruskan apa adanya.
      speedAccuracy: native.speedAccuracy,
      floor: null,
      isMocked: native.isMock,
    );
  }

  void _onAcquireTimeout(int generation) {
    if (generation != _acquisitionGeneration) return;
    if (currentState.mode != PodGpsMode.acquiring) {
      _stopStream();
      return;
    }
    if (kDebugMode) debugPrint('PodLocationService: acquire timeout — force stop');
    _gpsEngine.forceLockIfPossible();
    final lock = _gpsEngine.lockResult;
    if (lock != null) {
      _emit(currentState.copyWith(
        lat: lock.centroidLat,
        lon: lock.centroidLon,
        accuracy: lock.accuracy,
        confidence: _gpsEngine.confidence,
        lockResult: lock,
        lockProgress: _gpsEngine.lockProgress,
        isFallbackLock: _gpsEngine.isFallbackLock,
        speedMps: lock.bestRaw.speed,
      ));
    }
    // ⭐ BARU (Priority 1): kalau evidence sudah layak dipakai, jangan
    // _stopStream() total — pindah ke mode tracking supaya masih ada
    // kesempatan sample lebih baik masuk (refinement) & drift device
    // masih terdeteksi selagi capture owner aktif. Kalau evidence TETAP
    // tidak layak (window kosong sejak awal), tidak ada yang perlu
    // di-track — stop seperti biasa.
    if (currentState.isEvidenceReady) {
      _enterTrackingMode(generation);
    } else {
      _stopStream();
      _emit(currentState.copyWith(mode: PodGpsMode.stale));
    }
  }

  // ── INTERNAL: tracking mode transitions (BARU, Priority 1) ────

  /// Dipanggil begitu evidence pertama kali layak dipakai (lock normal
  /// via [_onPosition] atau force-lock via [_onAcquireTimeout]). Stream
  /// TIDAK dihentikan — dialihkan ke rate rendah (lihat
  /// [_buildTrackingSettings]/[_trackingMinInterval]) supaya refinement
  /// & deteksi drift latar belakang tetap berjalan selama capture owner
  /// masih aktif (lihat releaseAfterCapture untuk kapan benar-benar
  /// berhenti).
  void _enterTrackingMode(int generation) {
    if (generation != _acquisitionGeneration) {
      _stopStream();
      return;
    }
    _acquireTimeout?.cancel();
    _acquireTimeout = null;
    _lastTrackingSampleAt = DateTime.now();

    // Native fused stream (Android): rate request dikontrol native side,
    // tidak bisa dilonggarkan dari Dart — penghematan baterai di jalur
    // ini sepenuhnya lewat throttle Dart (_lastTrackingSampleAt) di
    // _onPosition. Jalur geolocator (iOS / Android tanpa native bridge):
    // stream benar-benar di-restart dengan settings yang lebih longgar.
    if (!_usingNativeStream) {
      _restartStreamWithSettings(generation, _buildTrackingSettings());
    }

    _emit(currentState.copyWith(mode: PodGpsMode.tracking));
    _scheduleStale();
    if (kDebugMode) {
      debugPrint('PodLocationService: entering tracking mode (background refinement)');
    }
  }

  /// Dipanggil ketika sample yang diproses SELAGI tracking membuat
  /// engine soft-unlock/hard-reset (device bergerak) — kembali ke mode
  /// akuisisi rate penuh supaya re-lock secepat mungkin, bukan menunggu
  /// cadence tracking yang rendah.
  void _exitTrackingMode(int generation) {
    if (generation != _acquisitionGeneration) {
      _stopStream();
      return;
    }
    _lastTrackingSampleAt = null;
    _staleTimer?.cancel();
    _staleTimer = null;

    if (!_usingNativeStream) {
      _restartStreamWithSettings(generation, _buildAcquiringSettings());
    }

    _emit(currentState.copyWith(mode: PodGpsMode.acquiring));
    _acquireTimeout?.cancel();
    _acquireTimeout = Timer(_acquireDeadline, () => _onAcquireTimeout(generation));
    if (kDebugMode) {
      debugPrint('PodLocationService: exiting tracking mode — device bergerak, re-acquiring');
    }
  }

  /// Restart subscription geolocator dengan settings baru. HANYA dipakai
  /// untuk jalur geolocator (bukan native fused, lihat _usingNativeStream)
  /// — mengganti rate request di SUMBER, bukan cuma throttle Dart.
  void _restartStreamWithSettings(int generation, LocationSettings settings) {
    _positionStream?.cancel();
    _startGeolocatorStream(generation, settings);
  }

  // ── INTERNAL: position handler ───────────────────────────────

  void _onPosition(Position raw, int generation) {
    if (generation != _acquisitionGeneration ||
        (currentState.mode != PodGpsMode.acquiring &&
            currentState.mode != PodGpsMode.tracking)) {
      return;
    }

    // ── Tracking-mode throttle (BARU, Priority 1) ────────────────
    // Sample yang masuk selagi mode tracking di-throttle ke interval
    // rendah SEBELUM menyentuh apa pun lain (mock check, engine,
    // dst.) — sample yang di-skip tidak pernah diproses sama sekali,
    // supaya window/timer engine juga tidak ikut sibuk memproses data
    // yang tidak akan dipakai. Sample PERTAMA begitu masuk tracking
    // (​_lastTrackingSampleAt baru saja di-set oleh _enterTrackingMode)
    // otomatis di-throttle juga — wajar, karena evidence-nya sendiri
    // baru saja segar dari lock/force-lock sebelumnya.
    if (currentState.mode == PodGpsMode.tracking) {
      final last = _lastTrackingSampleAt;
      final now = DateTime.now();
      if (last != null && now.difference(last) < _trackingMinInterval) {
        return;
      }
      _lastTrackingSampleAt = now;
    }

    if (raw.isMocked) {
      _stopStream();
      _cancelTimers();
      _acquisitionGeneration++;
      _latestGeocodeRequest++;
      _emit(const PodLocationState(
        confidence: PodConfidence.poor,
        address: '⚠️ GPS Mock terdeteksi — nonaktifkan aplikasi lokasi palsu',
        mode: PodGpsMode.idle,
        mockDetected: true,
      ));
      if (kDebugMode) debugPrint('PodLocationService: mock GPS terdeteksi, blokir capture');
      return;
    }

    // Pasangkan data GNSS terbaru (jika masih cukup segar) dengan
    // sample posisi ini. Jika platform tidak mendukung (iOS) atau
    // belum ada data masuk, keduanya tetap null → gate otomatis
    // nonaktif di PodGpsEngine (fallback ke logika accuracy-only).
    final gnss = _gnssQuality.latest;
    final gnssFresh = gnss != null &&
        DateTime.now().difference(gnss.timestamp) <= _gnssQualityMaxAge;

    // Proses sample; return value tidak digunakan
    _gpsEngine.processSample(
      raw,
      gnssSatellitesUsed: gnssFresh ? gnss.satellitesUsedInFix : null,
      gnssAvgCn0DbHz: gnssFresh ? gnss.avgCn0DbHz : null,
      hdop: gnssFresh ? gnss.hdop : null,
      pdop: gnssFresh ? gnss.pdop : null,
    );

    // ⭐ Spoofing lanjutan terdeteksi (bukan isMocked, tapi heuristik
    // lain — lihat PodGpsEngine._evaluateSpoofHeuristics): blokir
    // capture sama seperti mock, tapi dengan pesan yang beda supaya
    // user tahu ini kecurigaan berbasis pola, bukan flag OS eksplisit.
    if (_gpsEngine.spoofSuspected) {
      _stopStream();
      _cancelTimers();
      _acquisitionGeneration++;
      _latestGeocodeRequest++;
      _emit(const PodLocationState(
        confidence: PodConfidence.poor,
        address: '⚠️ Lokasi mencurigakan terdeteksi — coba di area terbuka',
        mode: PodGpsMode.idle,
        spoofSuspected: true,
      ));
      if (kDebugMode) {
        debugPrint(
          'PodLocationService: spoofing dicurigai (${_gpsEngine.spoofReasons.join("; ")}), blokir capture',
        );
      }
      return;
    }

    final conf     = _gpsEngine.confidence;
    final lock     = _gpsEngine.lockResult;
    final progress = _gpsEngine.lockProgress;

    final lat = lock?.centroidLat ?? raw.latitude;
    final lon = lock?.centroidLon ?? raw.longitude;
    final acc = lock?.accuracy    ?? raw.accuracy;

    // speedAccuracy<=0 dianggap "provider tidak melaporkan speed
    // Doppler" (bukan bacaan valid) → simpan null, sama pola dengan
    // PodSample.hasReliableSpeed di PodGpsEngine.
    final speed = raw.speedAccuracy > 0 ? raw.speed : null;

    _emit(currentState.copyWith(
      lat:            lat,
      lon:            lon,
      accuracy:       acc,
      positionTimestamp: raw.timestamp,
      positionFromCache: false,
      confidence:     conf,
      lockResult:     lock,
      lockProgress:   progress,
      isFallbackLock: _gpsEngine.isFallbackLock,
      // ⭐ FIX: dulu di-hardcode `PodGpsMode.acquiring` di sini — kalau
      // sample ini diproses selagi mode SUDAH `tracking`, hardcode ini
      // akan diam-diam menurunkan mode balik ke acquiring tiap sample
      // (menghapus efek _enterTrackingMode). Sekarang mempertahankan
      // mode SAAT INI; transisi mode eksplisit ditangani di blok
      // isLocked/exit-tracking di bawah.
      mode:           currentState.mode,
      mockDetected:   false,
      spoofSuspected: false,
      gnssGateActive: _gpsEngine.gnssGateActive && !conf.canCapture,
      velocityGateActive: _gpsEngine.velocityGateActive && !conf.canCapture,
      speedMps:       speed,
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
      if (movedFar) {
        _emit(currentState.copyWith(
          clearAddress: true,
          addressLoading: true,
        ));
      }
      _requestGeocode(lat, lon, generation, raw.timestamp);
    }

    // ⭐ BARU (Priority 1): begitu locked, TIDAK lagi _stopStream() total
    // — pindah/tetap di mode tracking (stream rate rendah, latar
    // belakang) supaya refinement (Priority 3) & deteksi drift device
    // tetap berjalan selama capture owner masih aktif.
    if (_gpsEngine.isLocked) {
      if (currentState.mode != PodGpsMode.tracking) {
        _enterTrackingMode(generation);
      } else {
        // Sudah tracking — sample ini mengonfirmasi lock masih dalam
        // ambang, refresh stale timer supaya evidence tetap "fresh"
        // selama tracking terus mengonfirmasi (tidak perlu re-acquire
        // dari nol di capture berikutnya).
        _scheduleStale();
      }
      if (kDebugMode) {
        debugPrint('PodLocationService: locked acc=${acc.toStringAsFixed(1)}m');
      }
    } else if (currentState.mode == PodGpsMode.tracking) {
      // Soft-unlock/hard-reset terjadi selagi tracking (device
      // bergerak) — kembali ke mode akuisisi rate penuh supaya re-lock
      // secepat mungkin, bukan menunggu cadence tracking yang rendah.
      _exitTrackingMode(generation);
    }
  }

  // ── Stale timer ─────────────────────────────────────────────

  void _scheduleStale() {
    _staleTimer?.cancel();
    _staleTimer = Timer(_staleAfter, () {
      if (currentState.mode != PodGpsMode.locked &&
          currentState.mode != PodGpsMode.tracking) {
        return;
      }

      // 🟡 FIX BATCH GPS WAIT: dulu lock langsung digugurkan ke `stale`
      // begitu `_staleAfter` (30s) lewat, TANPA peduli apakah sesi
      // capture (batch foto/video untuk satu barcode) masih berjalan.
      // Akibatnya kalau jeda antar-foto dalam satu batch >30s (wajar di
      // lapangan: jalan ke barang berikutnya, atur posisi, dst), evidence
      // gugur → foto berikutnya masuk `_startAcquire()` dari nol lagi
      // (lock GPS ulang + geocode ulang) → `awaitEvidenceReady()` di
      // `_applyWatermark` nunggu penuh sampai 15 detik lagi, TIAP foto.
      //
      // Selama masih ada owner aktif (PhotoScanScreen/VideoScanScreen
      // belum dispose — artinya batch untuk barcode ini belum selesai),
      // evidence yang sudah didapat (lock + alamat) TETAP dipertahankan
      // dan dipakai ulang langsung, tanpa re-acquire/re-geocode. Begitu
      // owner terakhir release (`releaseAfterCapture`), stale timer akan
      // dijadwalkan ulang dari titik itu seperti biasa — jadi evidence
      // tetap segar untuk barcode berikutnya.
      if (_captureOwners.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
            'PodLocationService: stale ditahan — ${_captureOwners.length} '
            'owner capture masih aktif, evidence dipakai ulang',
          );
        }
        return;
      }

      _emit(currentState.copyWith(mode: PodGpsMode.stale));
      if (kDebugMode) debugPrint('PodLocationService: lock stale after $_staleAfter');
    });
  }

  // ── Geocode ──────────────────────────────────────────────────

  void _requestGeocode(
    double lat,
    double lon,
    int generation,
    DateTime positionTimestamp,
  ) {
    _geocodeDone = true;
    _lastGeocodeLat = lat;
    _lastGeocodeLon = lon;
    final requestId = ++_latestGeocodeRequest;
    unawaited(_geocode(
      lat,
      lon,
      generation,
      requestId,
      positionTimestamp,
    ));
  }

  bool _isCurrentGeocode(
    double lat,
    double lon,
    int generation,
    int requestId,
  ) {
    if (generation != _acquisitionGeneration ||
        requestId != _latestGeocodeRequest ||
        !currentState.hasPosition) {
      return false;
    }
    return PodGpsEngine.haversinePublic(
          lat,
          lon,
          currentState.lat!,
          currentState.lon!,
        ) <=
        PodLocationState.addressMatchRadiusMeters;
  }

  void _publishGeocode(
    double lat,
    double lon,
    int generation,
    int requestId,
    ResolvedLocation resolved, {
    required bool fromCache,
    required bool addressLoading,
    required bool isFastAddress,
  }) {
    if (!_isCurrentGeocode(lat, lon, generation, requestId)) return;
    _emit(currentState.copyWith(
      address: resolved.display,
      resolvedLocation: resolved,
      addressLat: lat,
      addressLon: lon,
      fromCache: fromCache,
      addressLoading: addressLoading,
      isFastAddress: isFastAddress,
    ));
  }

  Future<void> _geocode(
    double lat,
    double lon,
    int generation,
    int requestId,
    DateTime positionTimestamp,
  ) async {
    final key = _gridKey(lat, lon);
    if (_geocodeCache.containsKey(key)) {
      final address = _geocodeCache[key]!;
      _publishGeocode(
        lat,
        lon,
        generation,
        requestId,
        ResolvedLocation(addressLine: address),
        fromCache: true,
        addressLoading: false,
        isFastAddress: true,
      );
      if (_isCurrentGeocode(lat, lon, generation, requestId)) {
        unawaited(_saveLastKnown(lat, lon, address, positionTimestamp));
      }
      return;
    }

    if (_isCurrentGeocode(lat, lon, generation, requestId)) {
      _emit(currentState.copyWith(addressLoading: true));
    }
    try {
      final resolved = await PodAddressResolver.resolveDetailed(
        lat,
        lon,
        onAddressResolved: (addressLine) {
          _publishGeocode(
            lat,
            lon,
            generation,
            requestId,
            ResolvedLocation(addressLine: addressLine),
            fromCache: false,
            addressLoading: true,
            isFastAddress: true,
          );
        },
      );
      if (!_isCurrentGeocode(lat, lon, generation, requestId)) return;
      final address = resolved.display;
      if (address.isNotEmpty && !resolved.isDmsFallback) {
        _geocodeCache[key] = address;
        if (_geocodeCache.length > _maxCache) {
          final remove = _geocodeCache.keys.take(50).toList();
          for (final k in remove) _geocodeCache.remove(k);
        }
        unawaited(_saveLastKnown(lat, lon, address, positionTimestamp));
      }
      _publishGeocode(
        lat,
        lon,
        generation,
        requestId,
        resolved,
        fromCache: false,
        addressLoading: false,
        isFastAddress: false,
      );
      if (kDebugMode) debugPrint('PodLocationService: geocode → $address');
    } catch (e) {
      if (kDebugMode) debugPrint('PodLocationService: geocode error $e');
      if (_isCurrentGeocode(lat, lon, generation, requestId)) {
        _emit(currentState.copyWith(addressLoading: false));
      }
    }
  }

  // ── Cache load/save ──────────────────────────────────────────

  Future<void> _loadCachedState() async {
    try {
      final prefs   = await SharedPreferences.getInstance();
      final lat     = prefs.getDouble(_prefLat);
      final lon     = prefs.getDouble(_prefLon);
      final address = prefs.getString(_prefAddress);
      final timestampMs = prefs.getInt(_prefTimestamp);
      final timestamp = timestampMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(timestampMs);

      if (lat != null &&
          lon != null &&
          address != null &&
          address.isNotEmpty &&
          timestamp != null &&
          _isTimestampWithin(timestamp, _cachedPreviewMaxAge)) {
        final key = _gridKey(lat, lon);
        _geocodeCache[key] = address;

        _emit(currentState.copyWith(
          lat:           lat,
          lon:           lon,
          positionTimestamp: timestamp,
          positionFromCache: true,
          address:       address,
          addressLat:    lat,
          addressLon:    lon,
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

  Future<void> _saveLastKnown(
    double lat,
    double lon,
    String address,
    DateTime positionTimestamp,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setDouble(_prefLat, lat),
        prefs.setDouble(_prefLon, lon),
        prefs.setString(_prefAddress, address),
        prefs.setInt(_prefTimestamp, positionTimestamp.millisecondsSinceEpoch),
      ]);
    } catch (e) {
      if (kDebugMode) debugPrint('PodLocationService: save error $e');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────

  Future<_LocationAccessStatus> _checkPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return _LocationAccessStatus.serviceDisabled;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      return _LocationAccessStatus.deniedForever;
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.unableToDetermine) {
      return _LocationAccessStatus.denied;
    }
    return _LocationAccessStatus.granted;
  }

  bool _isTimestampWithin(DateTime timestamp, Duration maximumAge) {
    final age = DateTime.now().difference(timestamp);
    return age >= const Duration(seconds: -5) && age <= maximumAge;
  }

  void _stopStream() {
    _positionStream?.cancel();
    _positionStream = null;
    _usingNativeStream = false;
    _gnssQuality.stop();
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
