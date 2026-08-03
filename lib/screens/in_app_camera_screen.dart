// lib/screens/in_app_camera_screen.dart
// ============================================================
// KAMERA IN-APP DENGAN PRATINJAU WATERMARK LIVE
// ============================================================
// Overlay watermark digambar via DUA CustomPainter terpisah:
//   - WatermarkStaticPainter  → WatermarkLayout.paintStaticOnly()
//   - WatermarkDynamicPainter → WatermarkLayout.paintDynamicOnly()
// Keduanya mendelegasikan ke WatermarkLayout, method yang SUDAH ADA
// dan juga dipakai untuk overlay video. TIDAK ADA PictureRecorder /
// toImage / encode-decode PNG di jalur live preview ini — canvas
// digambar langsung oleh Flutter tiap repaint.
//
// OPTIMASI PERFORMA (vs versi sebelumnya):
//  1. Overlay PNG (renderOverlayPng → Image.memory) DIGANTI CustomPainter
//     yang menggambar langsung ke Canvas Flutter — tidak ada raster ke
//     bitmap + encode/decode PNG tiap detik.
//  2. Elemen statis di-cache SEKALI, bukan tiap frame/detik:
//       - Logo (ui.Image) di-decode sekali di initState, dipakai ulang
//         selama layar terbuka, di-dispose saat dispose().
//       - WatermarkLayout instance dibuat sekali (bukan per-tick).
//  3. Overlay dipecah jadi 2 layer, masing-masing RepaintBoundary sendiri:
//       - Static (logo, background bar, brand, kode verifikasi, meta
//         barcode/operator) — HANYA repaint kalau field terkait berubah.
//       - Dynamic (jam, tanggal, koordinat, alamat) — repaint tiap tick
//         clock/GPS, TAPI tidak memicu repaint layer static di atasnya.
//     Root State TIDAK pakai setState() untuk ini, jadi CameraPreview
//     & chrome UI di sekitarnya tidak ikut rebuild sama sekali.
//  4. shouldRepaint() masing-masing painter membandingkan HANYA field
//     yang relevan untuk layer itu; kalau tidak ada yang berubah,
//     Flutter melewati repaint layer tersebut sepenuhnya.
//
// Proses watermark FINAL (dibakar ke file hasil foto) tetap 100% lewat
// WatermarkRenderer.render() yang sudah ada di _applyWatermark
// (photo_scan_screen.dart) — TIDAK berubah sama sekali.
// ============================================================


import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/pod_location_service.dart';
import '../theme/app_theme.dart';
import '../watermark/layouts/base_layout.dart';
import '../watermark/models/watermark_data.dart';
import '../watermark/watermark_factory.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/widgets/watermark_dynamic_painter.dart';
import '../watermark/widgets/watermark_static_painter.dart';

/// ✅ FIX SINKRONISASI LIVE PREVIEW ↔ SIMPAN: dulu layar ini hanya
/// mengembalikan XFile mentah lewat Navigator.pop(), lalu
/// PhotoScanScreen._applyWatermark() query ULANG lokasi (bahkan
/// menunggu s.d. 15 detik lewat awaitEvidenceReady()) dan waktu
/// (DateTime.now() baru) — terpisah total dari apa yang barusan
/// tampil di layar saat tombol jepret ditekan. Untuk kendaraan yang
/// bergerak, jeda tunggu itu bisa membuat alamat/koordinat yang
/// TERBAKAR di watermark foto berbeda dari yang DILIHAT operator di
/// live preview saat menjepret.
///
/// Sekarang [InAppCameraScreen] membawa serta snapshot [WatermarkData]
/// yang PERSIS sama dengan yang sedang tampil di live preview pada
/// detik tombol ditekan, supaya pemanggil (PhotoScanScreen) tinggal
/// pakai data ini langsung — tidak query ulang GPS/waktu sama sekali.
class CameraCaptureResult {
  final XFile file;
  final WatermarkData watermarkData;
  const CameraCaptureResult({required this.file, required this.watermarkData});
}

class InAppCameraScreen extends StatefulWidget {
  const InAppCameraScreen({super.key});

  @override
  State<InAppCameraScreen> createState() => _InAppCameraScreenState();
}

class _InAppCameraScreenState extends State<InAppCameraScreen>
    with WidgetsBindingObserver {
  final WatermarkSettings _wmSettings = WatermarkSettings();

  CameraController? _controller;
  Future<void>? _initFuture;
  String? _errorText;
  // ✅ FIX: melacak disposal controller lama supaya init berikutnya
  // selalu menunggu native side benar-benar selesai dispose dulu —
  // tanpa ini bisa race: controller baru initialize() sementara
  // controller lama masih dispose() di native, hasilnya isInitialized
  // true di Dart tapi channel native-nya sudah putus (CameraException
  // channel-error saat takePicture).
  Future<void>? _disposeFuture;

  // ─── Cache elemen statis (dibuat/dimuat SEKALI) ────────────
  late final WatermarkLayout _layout;
  late final bool _overlaySupported;
  ui.Image? _logoImage; // di-decode sekali, dipakai ulang tiap repaint

  // ─── Data live (bagian yang MEMANG berubah tiap detik/GPS update) ──
  late final ValueNotifier<WatermarkData> _liveData;
  Timer? _clockTimer;
  StreamSubscription<PodLocationState>? _gpsSub;

  bool _isCapturing = false;
  FlashMode _flashMode = FlashMode.off;

  static const Duration _clockTickInterval = Duration(seconds: 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Style seperti Polaroid punya canvas LEBIH BESAR dari frame foto
    // (border/strip di sekelilingnya) sehingga tidak bisa dipakai sebagai
    // overlay transparan langsung di atas live preview — sama seperti
    // batasan overlay video. Untuk kasus ini kita tampilkan badge info,
    // watermark tetap diterapkan penuh setelah foto diambil.
    _layout = WatermarkFactory.create(_wmSettings.style);
    _overlaySupported = _layout.supportsVideoOverlay;

    _liveData = ValueNotifier(_buildLiveData());
    _initFuture = _initCamera();

    if (_overlaySupported) {
      unawaited(_loadLogoIfNeeded());
      _clockTimer = Timer.periodic(
        _clockTickInterval,
        (_) => _liveData.value = _buildLiveData(),
      );
      if (_wmSettings.gpsWatermarkEnabled) {
        _gpsSub = PodLocationService.instance.stream.listen(
          (_) => _liveData.value = _buildLiveData(),
        );
      }
    }
  }

  // ─── PILIH RESOLUTION PRESET SECARA ADAPTIF ────────────────
  // ✅ FIX: dulu fixed `ResolutionPreset.veryHigh` (preset tertinggi,
  // bisa 4K+ tergantung sensor). Ini dua kali sia-sia:
  //  1. Preview live di layar jadi berat → FPS drop, terutama di
  //     device low-end/entry-level yang banyak dipakai di lapangan.
  //  2. Foto hasil jepretan tetap di-downscale lagi ke maxDimension
  //     1920px oleh ImageCompressor — jadi resolusi sensor penuh di
  //     atas itu cuma menambah beban decode/encode tanpa menambah
  //     kualitas akhir yang benar-benar dipakai.
  //
  // Sekarang default `ResolutionPreset.high` (umumnya ~1080p, pas
  // dengan target 1920px itu), TAPI turun ke `ResolutionPreset.medium`
  // di device yang oleh Android sendiri ditandai low-RAM
  // (`ActivityManager.isLowRamDevice()`, diekspos device_info_plus
  // sebagai `isLowRamDevice`) — ini flag resmi dari OS, bukan tebakan,
  // jadi lebih bisa diandalkan daripada menebak dari model/brand.
  // iOS tidak punya konsep low-RAM device yang setara & perangkatnya
  // jauh lebih seragam, jadi selalu pakai `high`.
  Future<ResolutionPreset> _pickResolutionPreset() async {
    if (!Platform.isAndroid) return ResolutionPreset.high;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.isLowRamDevice) {
        debugPrint('📉 Low-RAM device terdeteksi → preview kamera pakai ResolutionPreset.medium');
        return ResolutionPreset.medium;
      }
    } catch (e) {
      debugPrint('⚠️ Gagal deteksi isLowRamDevice, fallback ke ResolutionPreset.high: $e');
    }
    return ResolutionPreset.high;
  }

  Future<void> _initCamera() async {
    try {
      // ✅ FIX: tunggu disposal controller lama (kalau ada) selesai dulu,
      // supaya tidak initialize() controller baru sementara native side
      // masih membereskan controller lama.
      if (_disposeFuture != null) {
        await _disposeFuture;
        _disposeFuture = null;
      }
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _errorText = 'Kamera tidak ditemukan di perangkat ini');
        return;
      }
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        backCamera,
        await _pickResolutionPreset(),
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      debugPrint('❌ Gagal inisialisasi kamera in-app: $e');
      if (mounted) {
        setState(() => _errorText = 'Gagal membuka kamera: $e');
      }
    }
  }

  // ─── Cache logo (SEKALI, bukan tiap tick) ──────────────────

  Future<void> _loadLogoIfNeeded() async {
    if (!_wmSettings.hasLogo) return;
    final path = _wmSettings.logoPath;
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      // targetWidth kecil cukup untuk pratinjau di layar — resolusi
      // final tetap ditentukan sendiri oleh WatermarkRenderer.render()
      // saat proses watermark permanen setelah foto diambil.
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 200);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      _logoImage = frame.image;
      // Trigger satu repaint supaya logo langsung muncul setelah selesai
      // di-decode, tanpa menunggu tick clock berikutnya.
      _liveData.value = _buildLiveData();
    } catch (e) {
      debugPrint('⚠️ Gagal cache logo untuk pratinjau live: $e');
    }
  }

  // ─── Bangun WatermarkData "murah" — hanya bagian yang berubah ──
  // Konstruksi ini identik dengan yang dibuat WatermarkRenderer secara
  // internal (lihat render()/renderOverlayPng()) — bukan logika baru,
  // hanya dipindah ke sini supaya tidak perlu membungkusnya lewat
  // ScanEntry + renderOverlayPng untuk sekadar pratinjau di layar.
  // ✅ FIX EVIDENCE INTEGRITY: capture di layar ini TIDAK menunggu GPS
  // lock (beda dari video/gallery-photo yang selalu lewat
  // `awaitEvidenceReady()`, yang dijamin hanya mengembalikan state
  // `isEvidenceReady == true` atau null). Demi latency, itu tetap
  // dipertahankan — TAPI kalau operator menjepret saat lokasi belum
  // lolos confidence gate (`isEvidenceReady == false`, mis. masih
  // "acquiring"/akurasi rendah), alamat/koordinat yang tercetak di
  // watermark ditandai eksplisit supaya tidak terlihat seolah-olah
  // bukti lokasi final padahal belum terkunci. Tanda ini ikut terbawa
  // ke `locationName` yang dikonsumsi ScanEntry → WatermarkRenderer,
  // jadi otomatis muncul di watermark akhir tanpa perlu field baru.
  static const String _unlockedPrefix = '⚠ GPS belum terkunci · ';

  // ✅ FIX #2 (evidence integrity, lanjutan): sebelumnya isEvidenceReady
  // == true diperlakukan seragam, padahal itu bisa berarti dua hal
  // yang kualitasnya beda jauh: (a) lock genuine (confidence tembus
  // gate accuracy/GNSS/velocity secara wajar), atau (b) fallback lock
  // paksa dari PodGpsEngine._forceLock() setelah timeout — engine
  // SUDAH melacak ini lewat `isFallbackLock`, tapi sebelumnya info itu
  // mati di dalam service, tidak pernah sampai ke watermark/UI. Sekarang
  // fallback lock juga ditandai eksplisit di locationName.
  static const String _fallbackPrefix = '⚠ GPS cadangan · ';

  // ✅ FIX AUDIT LINTAS FILE: penanda tadinya SUFFIX (di akhir string),
  // tapi stamp_layout/minimal_layout/polaroid_layout merender lokasi
  // dengan maxLines:1 + TextOverflow.ellipsis. Alamat Indonesia yang
  // panjang bikin ellipsis motong dari BELAKANG — jadi suffix di ujung
  // justru yang PERTAMA hilang, persis di layout yang paling butuh
  // sinyal ini (watermark yang sudah dibakar ke file). Prefix jauh
  // lebih aman: ellipsis motong ekor alamat, bukan kepala peringatan.

  WatermarkData _buildLiveData() {
    final locState = _wmSettings.gpsWatermarkEnabled
        ? PodLocationService.instance.currentState
        : null;
    String? locationName;
    if (locState != null && locState.address.isNotEmpty) {
      if (!locState.isEvidenceReady) {
        locationName = '$_unlockedPrefix${locState.address}';
      } else if (locState.isFallbackLock) {
        locationName = '$_fallbackPrefix${locState.address}';
      } else {
        locationName = locState.address;
      }
    }
    return WatermarkData(
      timestamp: DateTime.now(),
      operatorName: _wmSettings.operatorName,
      companyName: _wmSettings.companyName,
      barcodeValue: null,
      barcodeFormat: null,
      latitude: locState?.lat,
      longitude: locState?.lon,
      locationName: locationName,
      logoPath: _wmSettings.logoPath,
      position: _wmSettings.position,
      fontSize: _wmSettings.fontSize,
      backgroundOpacity: _wmSettings.backgroundOpacity,
      fontFamily: _wmSettings.fontFamily,
    );
  }

  // ─── Capture ─────────────────────────────────────────────────

  // ✅ FIX QUALITY-BEFORE-CAPTURE: seberapa lama shutter boleh menunggu
  // lock GPS mencapai tier "good" (canCapture) sebelum tetap lanjut
  // dengan fix terbaik yang ada. Sengaja pendek — dengan quick-lock
  // engine sekarang (biasanya 2-4 detik outdoor untuk tier "good"),
  // ceiling ini jarang benar-benar terpakai penuh; cuma jaring pengaman
  // supaya shutter tidak menjepret dengan fix "poor"/"searching" yang
  // kebetulan tersedia di milidetik tombol ditekan.
  static const Duration _gpsQualityWaitCeiling = Duration(seconds: 4);

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }
    if (_wmSettings.gpsWatermarkEnabled &&
        PodLocationService.instance.currentState.mockDetected) {
      unawaited(PodLocationService.instance.acquireForCapture());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'GPS palsu terdeteksi. Nonaktifkan aplikasi lokasi palsu lalu coba lagi.',
          ),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    setState(() => _isCapturing = true);
    try {
      // Tunggu SEBENTAR (maks _gpsQualityWaitCeiling) kalau lock belum
      // mencapai tier "good" — lihat catatan di atas. Kalau ceiling
      // habis atau lokasi tetap tidak layak, tetap lanjut capture
      // dengan fix terbaik yang ada; _buildLiveData() di bawah sudah
      // menandai "⚠ GPS belum terkunci"/"⚠ GPS cadangan" bila
      // kualitasnya di bawah standar, jadi tidak pernah menyamar
      // sebagai bukti final yang sudah terkunci penuh.
      if (_wmSettings.gpsWatermarkEnabled &&
          !PodLocationService.instance.currentState.confidence.canCapture) {
        try {
          await PodLocationService.instance.stream
              .firstWhere(
                (s) => s.confidence.canCapture || s.mockDetected,
              )
              .timeout(_gpsQualityWaitCeiling);
        } catch (_) {
          // Timeout/stream error — lanjut capture dengan fix terbaik
          // yang ada saat ini.
        }
      }
      if (!mounted || _controller == null || !_controller!.value.isInitialized) {
        setState(() => _isCapturing = false);
        return;
      }

      HapticFeedback.mediumImpact();
      // ✅ Snapshot PERSIS apa yang sedang tampil di live preview SAAT
      // ini — dibangun lewat fungsi yang SAMA (_buildLiveData()) yang
      // dipakai overlay di layar, jadi lat/lon/alamat dijamin identik
      // dengan yang dilihat operator. Hanya timestamp yang di-refresh
      // ke waktu jepret sebenarnya (bukan sisa tick jam terakhir).
      final capturedData = _buildLiveData().copyWith(timestamp: DateTime.now());
      final xfile = await _controller!.takePicture();
      if (mounted) {
        Navigator.pop(
          context,
          CameraCaptureResult(file: xfile, watermarkData: capturedData),
        );
      }
    } catch (e) {
      debugPrint('❌ Gagal mengambil foto: $e');
      if (mounted) {
        setState(() => _isCapturing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengambil foto: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final next = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await controller.setFlashMode(next);
      if (mounted) setState(() => _flashMode = next);
    } catch (e) {
      debugPrint('⚠️ Gagal mengatur flash: $e');
    }
  }

  // ─── Lifecycle ───────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ✅ FIX: `inactive` sering terpicu oleh hal sesaat (notifikasi masuk,
    // dialog sistem, quick-settings) TANPA app benar-benar di-background.
    // Dulu di-treat sama seperti `paused` → kamera langsung di-dispose,
    // lalu begitu app balik `resumed` dengan cepat, controller baru mulai
    // initialize() sementara dispose() controller lama masih berjalan di
    // native → race yang bikin capture gagal (channel-error). Sekarang
    // hanya `paused` (app benar-benar ke background) yang men-dispose.
    if (state == AppLifecycleState.paused) {
      final controller = _controller;
      if (controller != null && controller.value.isInitialized) {
        _controller = null;
        _disposeFuture = controller.dispose();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_controller == null) {
        setState(() {
          _errorText = null;
          _initFuture = _initCamera();
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer?.cancel();
    _gpsSub?.cancel();
    _liveData.dispose();
    _logoImage?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  // ─── UI ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (_errorText != null) return _buildError(_errorText!);
          if (snapshot.connectionState != ConnectionState.done || _controller == null) {
            return const Center(
              child: CircularProgressIndicator(color: AppTheme.accentOrange),
            );
          }
          return _buildCameraBody();
        },
      ),
    );
  }

  Widget _buildError(String msg) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.no_photography_outlined, color: AppTheme.error, size: 48),
              const SizedBox(height: 12),
              Text(
                msg,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentOrange,
                  foregroundColor: Colors.black,
                ),
                child: const Text('Kembali'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCameraBody() {
    final controller = _controller!;
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: 1 / controller.value.aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(controller),
                if (_overlaySupported) _buildLiveOverlay(),
              ],
            ),
          ),
        ),
        if (!_overlaySupported) _buildUnsupportedBadge(),
        if (_wmSettings.gpsWatermarkEnabled) _buildGpsConfidenceBadge(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildRoundIconButton(
                  icon: Icons.close,
                  onTap: () => Navigator.pop(context),
                ),
                _buildRoundIconButton(
                  icon: _flashMode == FlashMode.torch
                      ? Icons.flash_on
                      : Icons.flash_off,
                  onTap: _toggleFlash,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 28,
          child: SafeArea(
            top: false,
            child: Center(child: _buildShutterButton()),
          ),
        ),
      ],
    );
  }

  // ─── Overlay: RepaintBoundary + ValueListenableBuilder SEMPIT ──
  // Dua layer terpisah, masing-masing RepaintBoundary sendiri:
  //  - Static: logo, background bar, brand, kode verifikasi, meta.
  //    Hanya repaint kalau setting/logo/barcode/operator berubah.
  //  - Dynamic: jam, tanggal, koordinat, alamat. Repaint tiap tick
  //    clock/GPS — TAPI tidak memicu repaint layer static.
  // CameraPreview & seluruh chrome UI di sekitarnya TIDAK ikut
  // rebuild, karena tidak ada setState() di root State untuk itu.
  Widget _buildLiveOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<WatermarkData>(
          valueListenable: _liveData,
          builder: (context, data, _) {
            return Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: WatermarkStaticPainter(
                        layout: _layout,
                        data: data,
                        logoImage: _logoImage,
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: WatermarkDynamicPainter(
                        layout: _layout,
                        data: data,
                        logoImage: _logoImage,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildRoundIconButton({required IconData icon, required VoidCallback onTap}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 24),
        onPressed: onTap,
      ),
    );
  }

  // ─── Badge confidence GPS live (opsi 3) ─────────────────────
  // Non-blocking: shutter tetap bisa ditekan kapan saja (latency
  // scan-to-capture tidak boleh terganggu), badge ini murni sinyal
  // visual supaya operator SENDIRI yang memutuskan tunggu sebentar
  // atau langsung jepret. Kalau langsung jepret saat belum locked,
  // watermark akhir tetap ditandai lewat `_unlockedSuffix` di atas.
  Widget _buildGpsConfidenceBadge() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 56),
          child: Center(
            child: StreamBuilder<PodLocationState>(
              stream: PodLocationService.instance.stream,
              initialData: PodLocationService.instance.currentState,
              builder: (context, snapshot) {
                final state = snapshot.data;
                if (state == null) return const SizedBox.shrink();
                final locked = state.isEvidenceReady;
                final isFallback = locked && state.isFallbackLock;
                final color = !locked
                    ? ((state.confidence == PodConfidence.searching ||
                            state.confidence == PodConfidence.poor)
                        ? AppTheme.error
                        : AppTheme.accentOrange)
                    : (isFallback ? AppTheme.accentOrange : AppTheme.success);
                final label = isFallback
                    ? '${state.confidence.label} (cadangan)'
                    : state.confidence.label;

                // ⭐ BARU: hint spesifik saat gate GNSS/velocity yang
                // menahan lock (bukan sekadar accuracy) — lebih actionable
                // daripada label confidence generik ("Stabilisasi…"),
                // karena operator langsung tahu tindakan konkret yang
                // perlu diambil. Velocity diprioritaskan di atas GNSS
                // karena solusinya lebih pasti di tangan operator
                // (berhenti jalan) dibanding menunggu sinyal GNSS membaik.
                String? gateHint;
                if (!locked) {
                  if (state.velocityGateActive) {
                    gateHint = '⏸️ Berhenti sebentar untuk mengunci lokasi';
                  } else if (state.gnssGateActive) {
                    gateHint = '📡 Sinyal GNSS lemah — dekati jendela/area terbuka';
                  }
                }

                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: color, width: 1.2),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      if (gateHint != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          gateHint,
                          style: const TextStyle(color: Colors.white70, fontSize: 10),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUnsupportedBadge() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 56, left: 24, right: 24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              'Pratinjau watermark tidak tersedia untuk gaya ini di kamera — '
              'watermark tetap diterapkan penuh setelah foto diambil',
              style: TextStyle(color: Colors.white, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShutterButton() {
    return GestureDetector(
      onTap: _isCapturing ? null : _capture,
      child: Container(
        width: 74,
        height: 74,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          border: Border.fromBorderSide(BorderSide(color: Colors.white, width: 4)),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: _isCapturing ? 30 : 58,
            height: _isCapturing ? 30 : 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isCapturing ? Colors.grey : AppTheme.accentOrange,
            ),
          ),
        ),
      ),
    );
  }
}
