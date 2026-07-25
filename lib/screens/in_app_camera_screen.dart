// lib/screens/in_app_camera_screen.dart
// ============================================================
// KAMERA IN-APP DENGAN PRATINJAU WATERMARK LIVE
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

  // ─── Cache elemen statis ────────────────────────────
  late final WatermarkLayout _layout;
  late final bool _overlaySupported;
  ui.Image? _logoImage;

  // ─── Data live ──────────────────────────────────────
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

  // ─── PILIH RESOLUSI ────────────────────────────────
  Future<ResolutionPreset> _pickResolutionPreset() async {
    if (!Platform.isAndroid) return ResolutionPreset.high;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.isLowRamDevice) {
        debugPrint('📉 Low-RAM device → ResolutionPreset.medium');
        return ResolutionPreset.medium;
      }
    } catch (e) {
      debugPrint('⚠️ Gagal deteksi isLowRamDevice: $e');
    }
    return ResolutionPreset.high;
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _errorText = 'Kamera tidak ditemukan');
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
      debugPrint('✅ Kamera in-app berhasil dibuka');
    } catch (e) {
      debugPrint('❌ Gagal inisialisasi kamera in-app: $e');
      if (mounted) {
        setState(() => _errorText = 'Gagal membuka kamera: $e');
      }
    }
  }

  // ─── Cache logo ──────────────────────────────────────
  Future<void> _loadLogoIfNeeded() async {
    if (!_wmSettings.hasLogo) return;
    final path = _wmSettings.logoPath;
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 200);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      _logoImage = frame.image;
      _liveData.value = _buildLiveData();
    } catch (e) {
      debugPrint('⚠️ Gagal cache logo: $e');
    }
  }

  // ─── Build WatermarkData ────────────────────────────
  WatermarkData _buildLiveData() {
    final locState = _wmSettings.gpsWatermarkEnabled
        ? PodLocationService.instance.currentState
        : null;
    return WatermarkData(
      timestamp: DateTime.now(),
      operatorName: _wmSettings.operatorName,
      companyName: _wmSettings.companyName,
      barcodeValue: null,
      barcodeFormat: null,
      latitude: locState?.lat,
      longitude: locState?.lon,
      locationName:
          (locState != null && locState.address.isNotEmpty) ? locState.address : null,
      logoPath: _wmSettings.logoPath,
      position: _wmSettings.position,
      fontSize: _wmSettings.fontSize,
      backgroundOpacity: _wmSettings.backgroundOpacity,
      fontFamily: _wmSettings.fontFamily,
    );
  }

  // ─── CAPTURE ────────────────────────────────────────
  Future<void> _capture() async {
    // ✅ Cek ketat: controller harus ada, terinisialisasi, dan tidak sedang sibuk
    final controller = _controller;
    if (controller == null) {
      _showError('Kamera belum siap');
      return;
    }
    if (!controller.value.isInitialized) {
      _showError('Kamera belum diinisialisasi');
      return;
    }
    if (_isCapturing) {
      debugPrint('⏳ Masih mengambil foto sebelumnya');
      return;
    }

    setState(() => _isCapturing = true);
    try {
      HapticFeedback.mediumImpact();

      // ✅ Pastikan kamera dalam keadaan idle sebelum takePicture
      if (controller.value.isRecordingVideo) {
        debugPrint('⚠️ Kamera sedang merekam, tidak bisa ambil foto');
        return;
      }

      final xfile = await controller.takePicture();
      if (!mounted) {
        return;
      }

      // ✅ Berhasil, kembali dengan file
      Navigator.pop(context, xfile);
    } catch (e, stack) {
      debugPrint('❌ Gagal mengambil foto: $e\n$stack');
      if (mounted) {
        _showError('Gagal mengambil foto: ${_formatErrorMessage(e)}');
        setState(() => _isCapturing = false);
      }
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
  }

  String _formatErrorMessage(dynamic e) {
    final msg = e.toString();
    if (msg.contains('channel-error') || msg.contains('Unable to establish connection')) {
      return 'Kamera tidak merespons, coba buka ulang kamera';
    }
    return msg;
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppTheme.error,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ─── FLASH ──────────────────────────────────────────
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

  // ─── LIFECYCLE ──────────────────────────────────────
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
    _clockTimer?.cancel();
    _gpsSub?.cancel();
    _liveData.dispose();
    _logoImage?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  // ─── UI ─────────────────────────────────────────────
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
                onPressed: () {
                  setState(() {
                    _errorText = null;
                    _initFuture = _initCamera();
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentOrange,
                  foregroundColor: Colors.black,
                ),
                child: const Text('Coba Ulang'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Kembali', style: TextStyle(color: Colors.white54)),
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
