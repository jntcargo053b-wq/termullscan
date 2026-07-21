// lib/screens/in_app_camera_screen.dart
// ============================================================
// KAMERA IN-APP DENGAN PRATINJAU WATERMARK LIVE
// ============================================================
// Menggantikan alur lama (image_picker → buka app kamera bawaan
// OS → watermark baru terlihat di preview_screen). Sekarang user
// langsung melihat overlay watermark di atas live camera feed
// SEBELUM foto diambil — "what you see is what you get".
//
// PENTING: layar ini TIDAK menulis ulang engine watermark.
// Ia hanya memanggil WatermarkRenderer.renderOverlayPng() yang
// SUDAH ADA (dipakai untuk overlay video) untuk menghasilkan PNG
// transparan berisi elemen watermark saja, lalu menumpuknya di
// atas CameraPreview. Proses watermark FINAL (yang benar-benar
// dibakar ke file foto) tetap 100% memakai WatermarkRenderer.render()
// yang sudah ada di _applyWatermark (photo_scan_screen.dart) —
// tidak berubah sama sekali.
// ============================================================

import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/scan_entry.dart';
import '../services/pod_location_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../watermark/watermark_factory.dart';
import '../watermark/watermark_renderer.dart';
import '../watermark/watermark_settings.dart';

class InAppCameraScreen extends StatefulWidget {
  const InAppCameraScreen({super.key});

  @override
  State<InAppCameraScreen> createState() => _InAppCameraScreenState();
}

class _InAppCameraScreenState extends State<InAppCameraScreen>
    with WidgetsBindingObserver {
  final WatermarkSettings _wmSettings = WatermarkSettings();
  final StorageService _storage = StorageService();

  CameraController? _controller;
  Future<void>? _initFuture;
  String? _errorText;

  bool _overlaySupported = true;
  bool _isRenderingOverlay = false;
  Uint8List? _overlayBytes;
  Timer? _overlayTimer;
  StreamSubscription<PodLocationState>? _gpsSub;

  bool _isCapturing = false;
  FlashMode _flashMode = FlashMode.off;

  static const int _overlayCanvasWidth = 720;
  static const Duration _overlayRefreshInterval = Duration(seconds: 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Style seperti Polaroid punya canvas LEBIH BESAR dari frame foto
    // (border/strip di sekelilingnya) sehingga tidak bisa dipakai sebagai
    // overlay transparan langsung di atas live preview — sama seperti
    // batasan overlay video. Untuk kasus ini kita tampilkan badge info,
    // watermark tetap diterapkan penuh setelah foto diambil.
    final layout = WatermarkFactory.create(_wmSettings.style);
    _overlaySupported = layout.supportsVideoOverlay;

    _initFuture = _initCamera();

    if (_overlaySupported) {
      _overlayTimer = Timer.periodic(
        _overlayRefreshInterval,
        (_) => _refreshOverlay(),
      );
      if (_wmSettings.gpsWatermarkEnabled) {
        _gpsSub = PodLocationService.instance.stream.listen(
          (_) => _refreshOverlay(),
        );
      }
    }
  }

  Future<void> _initCamera() async {
    try {
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
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      unawaited(_refreshOverlay());
    } catch (e) {
      debugPrint('❌ Gagal inisialisasi kamera in-app: $e');
      if (mounted) {
        setState(() => _errorText = 'Gagal membuka kamera: $e');
      }
    }
  }

  // ─── Live watermark overlay ─────────────────────────────────

  Future<void> _refreshOverlay() async {
    if (!mounted || !_overlaySupported || _isRenderingOverlay) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    _isRenderingOverlay = true;
    try {
      // Aspek rasio TAMPILAN (portrait) = 1 / aspectRatio sensor kamera —
      // pola standar plugin `camera` untuk device yang dikunci portrait.
      final displayAspect = 1 / controller.value.aspectRatio;
      final canvasWidth = _overlayCanvasWidth;
      final canvasHeight = (canvasWidth / displayAspect).round();

      final locState = _wmSettings.gpsWatermarkEnabled
          ? PodLocationService.instance.currentState
          : null;

      final tempEntry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: '',
        barcodeFormat: null,
        timestamp: DateTime.now(),
        latitude: locState?.lat,
        longitude: locState?.lon,
        locationName:
            (locState != null && locState.address.isNotEmpty) ? locState.address : null,
      );

      final bytes = await WatermarkRenderer.renderOverlayPng(
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        settings: _wmSettings,
        entry: tempEntry,
      );

      if (mounted && bytes != null) {
        setState(() => _overlayBytes = bytes);
      }
    } catch (e) {
      // Pratinjau gagal → tidak fatal. Watermark FINAL tetap dijamin
      // diterapkan penuh setelah foto diambil lewat _applyWatermark.
      debugPrint('⚠️ Gagal refresh pratinjau watermark: $e');
    } finally {
      _isRenderingOverlay = false;
    }
  }

  // ─── Capture ─────────────────────────────────────────────────

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }
    setState(() => _isCapturing = true);
    try {
      HapticFeedback.mediumImpact();
      final xfile = await controller.takePicture();
      if (mounted) Navigator.pop(context, xfile);
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
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _controller = null;
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      setState(() {
        _errorText = null;
        _initFuture = _initCamera();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _overlayTimer?.cancel();
    _gpsSub?.cancel();
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
                if (_overlaySupported && _overlayBytes != null)
                  IgnorePointer(
                    child: Image.memory(
                      _overlayBytes!,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (!_overlaySupported) _buildUnsupportedBadge(),
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

  Widget _buildRoundIconButton({required IconData icon, required VoidCallback onTap}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 24),
        onPressed: onTap,
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
              color: Colors.black.withOpacity(0.6),
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
