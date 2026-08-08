// test/pod_gps_engine_advanced_test.dart
// ============================================================
// Test tambahan untuk PodGpsEngine — melengkapi pod_gps_engine_test.dart
// (yang cuma cover force-lock dasar & mock rejection).
//
// Cover di sini:
//   1. Outlier rejection (MAD-based)
//   2. Spoof heuristik #1 — teleport speed
//   3. Spoof heuristik #2 — timestamp mundur
//   4. Spoof heuristik #3 — GNSS 0 satelit tapi ada fix
//   5. Spoof heuristik #4 — accuracy vs HDOP tidak konsisten
//   6. Spoof heuristik #5 — streak fix identik persis
//   7. Spoof heuristik #6 — kecepatan Doppler vs implisit posisi mismatch
//   8. GNSS quality gate — memblokir tier "excellent", tidak memblokir "good"
//   9. Velocity/motion gate — memblokir tier "excellent", tidak memblokir "good"
//  10. Quick lock — tier "good" tercapai hanya dengan quickLockSamples (2)
//
// Semua nilai ambang di test ini mengacu ke default GpsConfig di
// pod_gps_engine.dart (lihat konstruktor GpsConfig).
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:termulscan/services/pod_gps_engine.dart';

/// Base timestamp tetap (deterministik) — nilai absolut tidak penting,
/// yang penting adalah jarak antar-sample (dipakai untuk hitung
/// kecepatan implisit / kesegaran sample).
final _baseTime = DateTime(2026, 1, 1, 8, 0, 0);

/// 1 derajat lintang ≈ 111_320 meter — dipakai untuk membuat offset
/// posisi yang presisi dalam meter tanpa perlu haversine manual di test.
const _metersPerDegLat = 111320.0;

Position _pos({
  double lat = -6.200000,
  double lon = 106.800000,
  double accuracy = 5.0,
  int offsetMs = 0,
  bool isMocked = false,
  double speed = 0,
  double speedAccuracy = 0,
}) =>
    Position(
      longitude: lon,
      latitude: lat,
      timestamp: _baseTime.add(Duration(milliseconds: offsetMs)),
      accuracy: accuracy,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: speed,
      speedAccuracy: speedAccuracy,
      isMocked: isMocked,
    );

/// Offset lintang sejauh [meters] meter ke utara dari base lat.
double _latPlusMeters(double meters) => -6.200000 + (meters / _metersPerDegLat);

void main() {
  group('Outlier rejection (MAD-based)', () {
    test('sample yang jauh menyimpang dari cluster ditolak dari perhitungan centroid', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      // 3 sample "bersih" di titik yang sama (akurasi sedikit berbeda
      // supaya tidak kena heuristik #5 streak-identik).
      engine.processSample(_pos(accuracy: 5.0, offsetMs: 0));
      engine.processSample(_pos(accuracy: 5.2, offsetMs: 5000));
      engine.processSample(_pos(accuracy: 4.8, offsetMs: 10000));

      // Outlier ~35m dari cluster — cukup jauh untuk terdeteksi MAD,
      // tapi di bawah resetThreshold (50m) supaya tidak memicu hard
      // reset yang akan menghapus window.
      engine.processSample(
        _pos(lat: _latPlusMeters(35), accuracy: 5.0, offsetMs: 15000),
      );

      expect(engine.sampleCount, 4, reason: 'semua 4 sample harus masuk window (bukan ditolak admisi)');
      expect(engine.confidence, PodConfidence.excellent);
      expect(engine.lockResult, isNotNull);
      expect(
        engine.lockResult!.outliersRejected,
        1,
        reason: 'outlier 35m harus dibuang dari perhitungan cluster',
      );
      expect(engine.lockResult!.samplesUsed, 3);
    });

    test('tanpa outlier, semua sample dipakai (outliersRejected = 0)', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      engine.processSample(_pos(accuracy: 5.0, offsetMs: 0));
      engine.processSample(_pos(accuracy: 5.2, offsetMs: 5000));
      engine.processSample(_pos(accuracy: 4.8, offsetMs: 10000));

      expect(engine.confidence, PodConfidence.excellent);
      expect(engine.lockResult!.outliersRejected, 0);
      expect(engine.lockResult!.samplesUsed, 3);
    });
  });

  group('Spoof heuristik', () {
    test('#1 teleport speed — kecepatan implisit melebihi batas wajar ditolak', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      engine.processSample(_pos(offsetMs: 0));
      expect(engine.spoofSuspected, isFalse);

      // 1000m dalam 1 detik = 1000 m/s, jauh di atas maxPlausibleSpeedMps (55).
      final accepted = engine.processSample(
        _pos(lat: _latPlusMeters(1000), offsetMs: 1000),
      );

      expect(accepted, isFalse);
      expect(engine.spoofSuspected, isTrue);
      expect(
        engine.spoofReasons.any((r) => r.contains('kecepatan implisit')),
        isTrue,
      );
      expect(engine.sampleCount, 1, reason: 'sample teleport tidak boleh masuk window');
    });

    test('#2 timestamp mundur — sample dengan jam mundur ditolak', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      engine.processSample(_pos(offsetMs: 5000));
      final accepted = engine.processSample(_pos(offsetMs: 1000)); // mundur 4 detik

      expect(accepted, isFalse);
      expect(engine.spoofSuspected, isTrue);
      expect(
        engine.spoofReasons.any((r) => r.contains('timestamp mundur')),
        isTrue,
      );
    });

    test('#3 GNSS 0 satelit tapi tetap ada fix — ditolak langsung', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      final accepted = engine.processSample(
        _pos(offsetMs: 0),
        gnssSatellitesUsed: 0,
        gnssAvgCn0DbHz: 30.0,
      );

      expect(accepted, isFalse);
      expect(engine.spoofSuspected, isTrue);
      expect(
        engine.spoofReasons.any((r) => r.contains('0 satelit')),
        isTrue,
      );
    });

    test('#4 accuracy terlalu bagus untuk HDOP buruk — tidak konsisten, ditolak', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      // accuracy 2m (< spoofDopMismatchMaxAccuracy 5.0) tapi HDOP 10
      // (> spoofDopMismatchHdop 8.0) — mustahil secara fisik.
      final accepted = engine.processSample(
        _pos(accuracy: 2.0, offsetMs: 0),
        hdop: 10.0,
      );

      expect(accepted, isFalse);
      expect(engine.spoofSuspected, isTrue);
      expect(
        engine.spoofReasons.any((r) => r.contains('HDOP')),
        isTrue,
      );
    });

    test('#5 streak sample identik persis — replay statis terdeteksi', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      // spoofIdenticalStreak default = 3 → butuh 2 sample identik di
      // window sebelum sample ke-3 yang identik memicu flag.
      const lat = -6.200000, lon = 106.800000, accuracy = 5.0;

      // 🐛 FIX TEST: sample1 (accuracy 5m <= fastPathAccuracy 6m) lock
      // "excellent" instan lewat fast-path (n=1). Fast-path CUMA boleh
      // sekali (lihat catatan _evaluate) — sample2 wajib lewat jalur
      // normal (butuh targetSamples=3 + convergence untuk excellent),
      // jadi confidence TURUN ke "good" (quickLock). Itu penurunan sah,
      // BUKAN penolakan — processSample() return `confidence NAIK`,
      // bukan `sample diterima`, jadi tidak boleh diasumsikan `isTrue`
      // di sini. Acceptance dicek lewat sampleCount, bukan return value.
      expect(engine.processSample(_pos(lat: lat, lon: lon, accuracy: accuracy, offsetMs: 0)), isTrue);
      engine.processSample(_pos(lat: lat, lon: lon, accuracy: accuracy, offsetMs: 5000));
      expect(engine.sampleCount, 2, reason: 'sample ke-2 identik tetap diterima masuk window walau confidence turun tier');
      expect(engine.spoofSuspected, isFalse, reason: '2 sample identik saja belum cukup untuk flag');

      final thirdAccepted = engine.processSample(
        _pos(lat: lat, lon: lon, accuracy: accuracy, offsetMs: 10000),
      );

      expect(thirdAccepted, isFalse);
      expect(engine.spoofSuspected, isTrue);
      expect(
        engine.spoofReasons.any((r) => r.contains('identik persis')),
        isTrue,
      );
      expect(engine.sampleCount, 2, reason: 'sample ke-3 yang identik tidak boleh masuk window');
    });

    test('#6 kecepatan Doppler tidak cocok dengan kecepatan implisit posisi', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      // Sample pertama: diam, speed Doppler = 0 (dipercaya, speedAccuracy rendah).
      engine.processSample(_pos(offsetMs: 0, speed: 0, speedAccuracy: 1.0));

      // Sample kedua: posisi bergeser 200m dalam 10 detik (implied speed
      // 20 m/s — di bawah batas teleport 55 m/s, jadi tidak kena heuristik
      // #1), tapi chip GPS tetap lapor speed=0 (mismatch 20 m/s > ambang
      // spoofVelocityMismatchMps 15).
      final accepted = engine.processSample(
        _pos(
          lat: _latPlusMeters(200),
          offsetMs: 10000,
          speed: 0,
          speedAccuracy: 1.0,
        ),
      );

      expect(accepted, isFalse);
      expect(engine.spoofSuspected, isTrue);
      expect(
        engine.spoofReasons.any((r) => r.contains('Doppler')),
        isTrue,
      );
    });
  });

  group('GNSS & velocity gate — memblokir "excellent" tapi tidak "good"', () {
    test('GNSS lemah (satelit/CN0 di bawah ambang) memblokir excellent, quick-lock tetap jalan', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      // 3 sample akurat & rapat, tapi GNSS lemah di semuanya
      // (3 satelit < minGnssSatellitesUsed 6, CN0 15 < minGnssAvgCn0DbHz 22).
      engine.processSample(
        _pos(accuracy: 5.0, offsetMs: 0),
        gnssSatellitesUsed: 3,
        gnssAvgCn0DbHz: 15.0,
      );
      engine.processSample(
        _pos(accuracy: 5.2, offsetMs: 5000),
        gnssSatellitesUsed: 3,
        gnssAvgCn0DbHz: 15.0,
      );
      engine.processSample(
        _pos(accuracy: 4.8, offsetMs: 10000),
        gnssSatellitesUsed: 3,
        gnssAvgCn0DbHz: 15.0,
      );

      expect(engine.gnssGateActive, isTrue);
      expect(
        engine.confidence,
        PodConfidence.good,
        reason: 'gate GNSS mestinya menahan di "good", tidak sampai "excellent"',
      );
      expect(engine.canCapture, isTrue, reason: 'quick-lock (good) tidak digerbang GNSS');
    });

    test('device masih bergerak memblokir excellent, quick-lock tetap jalan', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      // 3 sample akurat & di posisi sama, tapi speed Doppler 5 m/s
      // (> maxPlausibleStationarySpeedMps 3.0) dengan speedAccuracy
      // dipercaya (1.0 <= maxSpeedAccuracyForGate 3.0).
      engine.processSample(_pos(accuracy: 5.0, offsetMs: 0, speed: 5.0, speedAccuracy: 1.0));
      engine.processSample(_pos(accuracy: 5.2, offsetMs: 5000, speed: 5.0, speedAccuracy: 1.0));
      engine.processSample(_pos(accuracy: 4.8, offsetMs: 10000, speed: 5.0, speedAccuracy: 1.0));

      expect(engine.velocityGateActive, isTrue);
      expect(
        engine.confidence,
        PodConfidence.good,
        reason: 'gate kecepatan mestinya menahan di "good", tidak sampai "excellent"',
      );
      expect(engine.canCapture, isTrue, reason: 'quick-lock (good) tidak digerbang velocity');
    });
  });

  group('Quick lock', () {
    test('tier "good" tercapai hanya dengan quickLockSamples (2), tidak perlu 3', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      engine.processSample(_pos(accuracy: 15.0, offsetMs: 0));
      expect(engine.confidence, isNot(PodConfidence.good), reason: '1 sample belum cukup untuk quick-lock');

      engine.processSample(_pos(accuracy: 15.0, offsetMs: 5000));

      expect(engine.confidence, PodConfidence.good);
      expect(engine.isLocked, isTrue);
      expect(engine.isFallbackLock, isFalse);
    });
  });

  group('Convergence-based lock (BARU)', () {
    test('excellent DIBLOKIR walau stdDev/radius snapshot lolos, kalau centroid masih '
        'bergeser signifikan antar-evaluasi (belum konvergen)', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      // 3 sample segaris (0m, 6m, 12m) — dievaluasi SATU-per-SATU
      // seperti sample GPS asli mengalir, bukan dimasukkan sekaligus.
      // Centroid bergeser 0 → 3m → 6m antar-evaluasi (weighted average,
      // akurasi sama semua) — drift maksimum antar-titik histori = 6m,
      // MELEBIHI convergenceMaxDriftMeters default (4.0m).
      //
      // Tapi snapshot TERAKHIR (n=3) sendiri lolos semua gate LAMA:
      //   avgAcc=5.0m <= excellentThreshold(10), stdDev≈4.9m <= 8,
      //   radius=6m <= excellentMaxRadius(12).
      // Artinya SEBELUM convergence gate ditambahkan, tier ini akan
      // salah lolos jadi "excellent" walau centroid nyatanya belum
      // berhenti bergeser — inilah gap yang convergence gate tutup.
      engine.processSample(_pos(lat: _latPlusMeters(0), accuracy: 5.0, offsetMs: 0));
      engine.processSample(_pos(lat: _latPlusMeters(6), accuracy: 5.0, offsetMs: 5000));
      engine.processSample(_pos(lat: _latPlusMeters(12), accuracy: 5.0, offsetMs: 10000));

      expect(
        engine.confidence,
        PodConfidence.good,
        reason: 'convergence gate mestinya menahan di "good" walau '
            'stdDev/radius snapshot terakhir sudah memenuhi ambang excellent',
      );
      expect(engine.isConverged, isFalse);
      expect(engine.convergenceDriftMeters, isNotNull);
      expect(engine.convergenceDriftMeters!, greaterThan(4.0));
      expect(engine.canCapture, isTrue, reason: 'tier "good" tetap tercapai, cukup layak dipakai');
    });

    test('excellent TERCAPAI begitu centroid berhenti bergeser (konvergen) di titik yang sama', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      // 3 sample di titik yang PERSIS sama (akurasi sedikit bervariasi
      // supaya tidak kena heuristik #5 streak-identik) — centroid tidak
      // pernah bergeser antar-evaluasi, drift = 0m.
      engine.processSample(_pos(accuracy: 5.0, offsetMs: 0));
      engine.processSample(_pos(accuracy: 5.1, offsetMs: 5000));
      engine.processSample(_pos(accuracy: 4.9, offsetMs: 10000));

      expect(engine.confidence, PodConfidence.excellent);
      expect(engine.isConverged, isTrue);
      expect(engine.convergenceDriftMeters, isNotNull);
      expect(engine.convergenceDriftMeters!, lessThanOrEqualTo(4.0));
    });

    test('histori convergence dibersihkan setelah hard reset (pindah lokasi jauh)', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      engine.processSample(_pos(accuracy: 5.0, offsetMs: 0));
      engine.processSample(_pos(accuracy: 5.1, offsetMs: 5000));
      engine.processSample(_pos(accuracy: 4.9, offsetMs: 10000));
      expect(engine.isConverged, isTrue);

      // Lompat >resetThreshold (50m) — hard reset total.
      engine.processSample(
        _pos(lat: _latPlusMeters(200), accuracy: 5.0, offsetMs: 15000),
      );

      expect(engine.isConverged, isFalse);
      expect(engine.convergenceDriftMeters, isNull);
    });
  });

  group('Soft-unlock debounce (BARU, saran performa #4)', () {
    test('1 sample menyimpang >= moveThreshold TIDAK memicu soft-unlock '
        '(belum debounce, streak=1)', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      // Lock excellent dulu di titik yang sama.
      engine.processSample(_pos(accuracy: 5.0, offsetMs: 0));
      engine.processSample(_pos(accuracy: 5.1, offsetMs: 5000));
      engine.processSample(_pos(accuracy: 4.9, offsetMs: 10000));
      expect(engine.confidence, PodConfidence.excellent);

      // Geser 25m (>= moveThreshold 20, < resetThreshold 50) — SATU
      // kali saja, lalu balik lagi ke titik semula di sample berikutnya.
      engine.processSample(
        _pos(lat: _latPlusMeters(25), accuracy: 5.0, offsetMs: 15000),
      );

      // Dengan debounce, 1 sample menyimpang belum cukup — confidence
      // TIDAK boleh sempat turun ke "fair" (tidak ada flicker).
      expect(
        engine.confidence,
        isNot(PodConfidence.fair),
        reason: '1 sample menyimpang belum boleh memicu soft-unlock (debounce butuh 2 berturut)',
      );
    });

    test('2 sample BERTURUT-TURUT menyimpang >= moveThreshold memicu soft-unlock', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      engine.processSample(_pos(accuracy: 5.0, offsetMs: 0));
      engine.processSample(_pos(accuracy: 5.1, offsetMs: 5000));
      engine.processSample(_pos(accuracy: 4.9, offsetMs: 10000));
      expect(engine.confidence, PodConfidence.excellent);

      // Geser 25m DUA kali berturut-turut ke arah yang sama (device
      // benar-benar bergerak menjauh, bukan noise sesaat).
      engine.processSample(
        _pos(lat: _latPlusMeters(25), accuracy: 5.0, offsetMs: 15000),
      );
      engine.processSample(
        _pos(lat: _latPlusMeters(50 - 1), accuracy: 5.0, offsetMs: 20000),
      );

      expect(
        engine.isLocked && engine.confidence == PodConfidence.excellent,
        isFalse,
        reason: 'pergerakan konsisten 2x berturut-turut mestinya tetap terdeteksi (soft-unlock jalan)',
      );
    });

    test('streak putus kalau sample di antaranya "diam" lagi', () {
      final engine = PodGpsEngine();
      addTearDown(engine.dispose);

      engine.processSample(_pos(accuracy: 5.0, offsetMs: 0));
      engine.processSample(_pos(accuracy: 5.1, offsetMs: 5000));
      engine.processSample(_pos(accuracy: 4.9, offsetMs: 10000));
      expect(engine.confidence, PodConfidence.excellent);

      // Menyimpang sekali...
      engine.processSample(
        _pos(lat: _latPlusMeters(25), accuracy: 5.0, offsetMs: 15000),
      );
      // ...lalu balik "diam" tepat di titik menyimpang itu (delta ke
      // sample sebelumnya < moveThreshold) — streak mestinya putus.
      engine.processSample(
        _pos(lat: _latPlusMeters(25), accuracy: 5.1, offsetMs: 20000),
      );
      // Lalu menyimpang lagi — ini SATU streak baru, bukan lanjutan
      // dari yang tadi, jadi belum boleh memicu soft-unlock.
      engine.processSample(
        _pos(lat: _latPlusMeters(50), accuracy: 5.0, offsetMs: 25000),
      );

      expect(
        engine.confidence,
        isNot(PodConfidence.fair),
        reason: 'streak yang terputus tidak boleh diakumulasi lintas sample yang "diam"',
      );
    });
  });
}
