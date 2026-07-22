// ============================================================
// lib/screens/barcode_scan_screen.dart (PRODUKSI FINAL - FIXED)
// ============================================================
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/permission_service.dart';
import '../services/pod_location_service.dart';
import '../theme/app_theme.dart';
import '../watermark/watermark_settings.dart';
import 'watermark_settings_sheet.dart';
import 'photo_scan_screen.dart';
import 'video_scan_screen.dart';

/// Snapshot barcode yang sedang aktif (sudah discan, menunggu aksi user).
/// Immutable supaya bisa dipakai sebagai value di ValueNotifier.
@immutable
class _ActiveScan {
  final String barcode;
  final String? entryId;
  final int photoCount;

  const _ActiveScan({
    required this.barcode,
    this.entryId,
    this.photoCount = 0,
  });

  _ActiveScan copyWith({String? entryId, int? photoCount}) => _ActiveScan(
        barcode: barcode,
        entryId: entryId ?? this.entryId,
        photoCount: photoCount ?? this.photoCount,
      );
}

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen>
    with WidgetsBindingObserver {
  // ─── STATE (murni logika, TIDAK memicu rebuild) ────────────
  bool _scanning = true;
  String? _lastCode;
  bool _processingScan = false;
  bool _sheetOpen = false;
  bool _resumeScheduled = false;

  // ─── STATE (mempengaruhi UI) ────────────────────────────────
  final ValueNotifier<_ActiveScan?> _activeScanVN = ValueNotifier(null);
  final ValueNotifier<int> _scanCountVN = ValueNotifier(0);

  // ─── DEBOUNCE SCANNER ───────────────────────────────────────
  Timer? _debounceTimer;
  static const Duration _debounceDuration = Duration(milliseconds: 1000);

  // ─── DEPENDENCIES ─────────────────────────────────────────
  final StorageService _storage = StorageService();
  final WatermarkSettings _wmSettings = WatermarkSettings();

  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    returnImage: false,
    facing: CameraFacing.back,
    formats: const [
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.ean13,
      BarcodeFormat.qrCode,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
    ],
  );

  // ─── LIFECYCLE ────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    if (_wmSettings.gpsWatermarkEnabled) {
      unawaited(PodLocationService.instance.acquireForCapture());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounceTimer?.cancel();
    _activeScanVN.dispose();
    _scanCountVN.dispose();
    try {
      _scannerController.stop();
    } catch (_) {}
    _scannerController.dispose();
    if (_wmSettings.gpsWatermarkEnabled) {
      PodLocationService.instance.releaseAfterCapture();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (_scanning) {
        try {
          _scannerController.stop();
        } catch (_) {}
        _scanning = false;
        debugPrint('📱 App background: scanner stopped');
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!_scanning && !_sheetOpen) {
        unawaited(_resumeScanning());
        debugPrint('📱 App foreground: scanner resumed');
      }
    }
  }

  // ─── PERMISSIONS ──────────────────────────────────────────

  Future<void> _requestPermissions() async {
    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      final result = await Permission.camera.request();
      if (!mounted) return;
      if (!result.isGranted) {
        if (result.isPermanentlyDenied) {
          _showPermissionDeniedDialog(
            'Izin Kamera',
            'Aplikasi membutuhkan kamera untuk memindai barcode. '
            'Silakan aktifkan di pengaturan.',
          );
        }
        return;
      }
    }
    await PermissionService.requestGalleryPermission();
  }

  void _showPermissionDeniedDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('Buka Pengaturan'),
          ),
        ],
      ),
    );
  }

  // ─── SCANNER CONTROL ──────────────────────────────────────

  Future<void> _resumeScanning() async {
    if (!mounted) return;
    if (_resumeScheduled || _processingScan) return;

    _resumeScheduled = true;
    bool started = false;
    try {
      await _scannerController.start();
      started = true;
      await Future.delayed(const Duration(milliseconds: 50));
    } catch (e) {
      debugPrint('⚠️ Resume scanner error: $e');
      if (e.toString().contains('permission')) {
        final status = await Permission.camera.request();
        if (status.isGranted) {
          try {
            await _scannerController.start();
            started = true;
            await Future.delayed(const Duration(milliseconds: 50));
          } catch (e2) {
            debugPrint('⚠️ Resume scanner gagal setelah izin diberikan: $e2');
          }
        }
      }
    } finally {
      _resumeScheduled = false;
    }

    if (!mounted) return;
    _scanning = started;
    if (!started) {
      debugPrint('⚠️ Scanner tidak berhasil di-resume, tetap dalam status berhenti.');
    }
  }

  // ─── BARCODE DETECTION ────────────────────────────────────

  void _onDetect(BarcodeCapture capture) {
    if (!_scanning || _processingScan) return;
    if (_debounceTimer?.isActive ?? false) return;

    final barcode = capture.barcodes.isNotEmpty ? capture.barcodes.first : null;
    final code = barcode?.rawValue;
    if (barcode == null || code == null || code.isEmpty) return;

    _processingScan = true;
    _scanning = false;
    _debounceTimer = Timer(_debounceDuration, () {});
    _lastCode = code;
    _activeScanVN.value = _ActiveScan(barcode: code);

    unawaited(_processDetectedBarcode(code: code, format: barcode.format.name));
  }

  Future<void> _processDetectedBarcode({
    required String code,
    required String format,
  }) async {
    try {
      HapticFeedback.mediumImpact();

      final gpsOn = _wmSettings.gpsWatermarkEnabled;
      final locState = gpsOn ? PodLocationService.instance.currentState : null;
      
      // 🔥 FIX: barcodeFormat dihapus, gunakan isManual = false
      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.barcode,
        value: code,
        // barcodeFormat: format, // ← HAPUS!
        timestamp: DateTime.now(),
        operatorName: _wmSettings.operatorName.isNotEmpty 
            ? _wmSettings.operatorName 
            : 'Operator',
        companyName: _wmSettings.companyName,
        latitude: locState?.lat,
        longitude: locState?.lon,
        locationName: (locState != null && locState.address.isNotEmpty) ? locState.address : null,
        isManual: false, // ← PAKAI INI
      );
      await _storage.add(entry);
      if (gpsOn) unawaited(_attachLocationUpdate(entry.id));

      if (!mounted) return;
      _scanCountVN.value++;
      _activeScanVN.value = _activeScanVN.value?.copyWith(entryId: entry.id);

      try {
        await _scannerController.stop();
      } catch (_) {}
    } catch (e) {
      debugPrint('❌ Error _processDetectedBarcode: $e');
      _lastCode = null;
      _activeScanVN.value = null;
      if (mounted) await _resumeScanning();
    } finally {
      _processingScan = false;
    }
  }

  // ─── MANUAL INPUT ─────────────────────────────────────────

  void _showManualInput() {
    if (_processingScan || _activeScanVN.value != null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ManualInputDialog(
        onSubmitted: (code) {
          unawaited(_processManualCode(code));
        },
      ),
    );
  }

  Future<void> _processManualCode(String code) async {
    if (_processingScan || _activeScanVN.value != null) return;

    _processingScan = true;
    _scanning = false;
    _lastCode = code;
    _activeScanVN.value = _ActiveScan(barcode: code);

    try {
      HapticFeedback.mediumImpact();

      final gpsOn = _wmSettings.gpsWatermarkEnabled;
      final locState = gpsOn ? PodLocationService.instance.currentState : null;
      
      // 🔥 FIX: barcodeFormat dihapus, gunakan isManual = true
      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.manual,
        value: code,
        // barcodeFormat: 'MANUAL', // ← HAPUS!
        timestamp: DateTime.now(),
        operatorName: _wmSettings.operatorName.isNotEmpty 
            ? _wmSettings.operatorName 
            : 'Operator',
        companyName: _wmSettings.companyName,
        latitude: locState?.lat,
        longitude: locState?.lon,
        locationName: (locState != null && locState.address.isNotEmpty) ? locState.address : null,
        isManual: true, // ← PAKAI INI
      );
      await _storage.add(entry);
      if (gpsOn) unawaited(_attachLocationUpdate(entry.id));

      if (!mounted) return;
      _scanCountVN.value++;
      _activeScanVN.value = _activeScanVN.value?.copyWith(entryId: entry.id);

      try {
        await _scannerController.stop();
      } catch (_) {}
    } catch (e) {
      debugPrint('❌ Error _processManualCode: $e');
      _lastCode = null;
      _activeScanVN.value = null;
      if (mounted) await _resumeScanning();
    } finally {
      _processingScan = false;
    }
  }

  // ─── GPS: update entry begitu alamat siap ──────────────────

  Future<void> _attachLocationUpdate(String entryId) async {
    try {
      final locState = await PodLocationService.instance.awaitAddressReady(
        timeout: const Duration(seconds: 10),
      );
      if (!locState.hasPosition) return;
      final stored = await _storage.getEntry(entryId);
      if (stored == null) return;
      final updated = stored.copyWith(
        latitude: locState.lat,
        longitude: locState.lon,
        locationName: locState.address.isNotEmpty ? locState.address : null,
      );
      await _storage.update(updated);
    } catch (e) {
      debugPrint('❌ Error _attachLocationUpdate: $e');
    }
  }

  // ─── NAVIGATION HELPERS ──────────────────────────────────

  Future<void> _goToPhotoScan() async {
    final active = _activeScanVN.value;
    if (active == null || active.entryId == null) return;

    try {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoScanScreen(
            barcode: active.barcode,
            entryId: active.entryId,
          ),
        ),
      );
    } catch (e) {
      debugPrint('❌ Error navigasi ke foto scan: $e');
    } finally {
      if (mounted) {
        _lastCode = null;
        _activeScanVN.value = null;
        await _resumeScanning();
      }
    }
  }

  Future<void> _goToVideoScan() async {
    final active = _activeScanVN.value;
    if (active == null) return;

    try {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoScanScreen(
            barcode: active.barcode,
          ),
        ),
      );
    } catch (e) {
      debugPrint('❌ Error navigasi ke video scan: $e');
    } finally {
      if (mounted) {
        _lastCode = null;
        _activeScanVN.value = null;
        await _resumeScanning();
      }
    }
  }

  // ─── WATERMARK SETTINGS ──────────────────────────────────

  void _openWatermarkSettings() {
    _sheetOpen = true;
    try {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppTheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => const WatermarkSettingsSheet(),
      ).whenComplete(() {
        _sheetOpen = false;
      });
    } catch (e) {
      debugPrint('❌ Error membuka pengaturan watermark: $e');
      _sheetOpen = false;
    }
  }

  // ─── BUILD ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder<int>(
          valueListenable: _scanCountVN,
          builder: (context, count, _) => Text('Scanner ($count)'),
        ),
        actions: [
          ValueListenableBuilder<_ActiveScan?>(
            valueListenable: _activeScanVN,
            builder: (context, active, _) => IconButton(
              onPressed: active != null ? null : _showManualInput,
              icon: const Icon(Icons.keyboard, color: Colors.white),
              tooltip: 'Input Manual',
            ),
          ),
          IconButton(
            onPressed: () {
              _scannerController.toggleTorch();
            },
            icon: const Icon(Icons.flash_on, color: Colors.white),
            tooltip: 'Lampu Sentuh',
          ),
          IconButton(
            onPressed: () {
              _scannerController.switchCamera();
            },
            icon: const Icon(Icons.flip_camera_android, color: Colors.white),
            tooltip: 'Ganti Kamera',
          ),
          ListenableBuilder(
            listenable: _wmSettings,
            builder: (context, _) => IconButton(
              onPressed: _openWatermarkSettings,
              icon: Stack(
                children: [
                  const Icon(Icons.tune, color: Colors.white),
                  if (_wmSettings.operatorName.isNotEmpty || _wmSettings.hasLogo)
                    const Positioned(
                      right: 0, top: 0,
                      child: Icon(Icons.circle, size: 8, color: AppTheme.accent),
                    ),
                ],
              ),
              tooltip: 'Pengaturan Watermark',
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          RepaintBoundary(
            child: MobileScanner(
              controller: _scannerController,
              onDetect: _onDetect,
            ),
          ),
          ValueListenableBuilder<_ActiveScan?>(
            valueListenable: _activeScanVN,
            builder: (context, active, _) {
              final showWatermark = active == null;
              return Stack(
                children: [
                  if (showWatermark)
                    Positioned(
                      top: 12, left: 0, right: 0,
                      child: ListenableBuilder(
                        listenable: _wmSettings,
                        builder: (context, _) {
                          if (_wmSettings.operatorName.isEmpty && !_wmSettings.hasLogo) {
                            return const SizedBox.shrink();
                          }
                          return Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xAA000000),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: AppTheme.accent.withOpacity(0.4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_wmSettings.operatorName.isNotEmpty) ...[
                                    const Icon(Icons.person, color: AppTheme.accent, size: 12),
                                    const Gap(5),
                                    Text(
                                      _wmSettings.operatorName,
                                      style: const TextStyle(
                                        color: AppTheme.accent,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                  if (_wmSettings.hasLogo) ...[
                                    if (_wmSettings.operatorName.isNotEmpty) const Gap(8),
                                    const Icon(Icons.business, color: Colors.white54, size: 12),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  if (active == null)
                    const Positioned.fill(
                      child: IgnorePointer(child: _ScanFrameOverlay()),
                    ),
                  if (active != null)
                    Positioned(
                      top: 12, left: 0, right: 0,
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.75),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.accent.withOpacity(0.4)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.qr_code, color: AppTheme.accent, size: 18),
                            const Gap(8),
                            Expanded(
                              child: Text(
                                active.barcode,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Gap(8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppTheme.accent.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${active.photoCount} foto',
                                style: const TextStyle(
                                  color: AppTheme.accent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (active != null && active.entryId != null)
                    Positioned(
                      bottom: 40, left: 0, right: 0,
                      child: Column(
                        children: [
                          TextButton.icon(
                            onPressed: _goToPhotoScan,
                            icon: const Icon(Icons.camera_alt, color: Colors.white70, size: 18),
                            label: const Text(
                              'Ambil Foto',
                              style: TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                            style: TextButton.styleFrom(
                              backgroundColor: const Color(0x88000000),
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                                side: const BorderSide(color: Colors.white24),
                              ),
                            ),
                          ),
                          const Gap(8),
                          TextButton.icon(
                            onPressed: _goToVideoScan,
                            icon: const Icon(Icons.videocam, color: Colors.white70, size: 18),
                            label: const Text(
                              'Rekam Video',
                              style: TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                            style: TextButton.styleFrom(
                              backgroundColor: const Color(0x88000000),
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                                side: const BorderSide(color: Colors.white24),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// ─── Manual Input Dialog ──────────────────────────────────────
class _ManualInputDialog extends StatefulWidget {
  final void Function(String code) onSubmitted;
  const _ManualInputDialog({required this.onSubmitted, super.key});

  @override
  State<_ManualInputDialog> createState() => _ManualInputDialogState();
}

class _ManualInputDialogState extends State<_ManualInputDialog> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: bottomInset + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Gap(16),
          const Row(
            children: [
              Icon(Icons.keyboard, color: AppTheme.accent, size: 20),
              Gap(8),
              Text(
                'Input Manual',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const Gap(4),
          const Text(
            'Ketik atau paste barcode jika kamera gagal membaca',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const Gap(16),
          TextField(
            controller: _controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Contoh: 8991234567890',
              hintStyle: const TextStyle(color: Colors.grey),
              filled: true,
              fillColor: const Color(0xFF2A2A2A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppTheme.accent, width: 1.5),
              ),
              prefixIcon: const Icon(Icons.qr_code, color: Colors.grey),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear, color: Colors.grey, size: 18),
                onPressed: () => _controller.clear(),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (val) {
              if (val.trim().isNotEmpty) {
                Navigator.pop(context);
                widget.onSubmitted(val.trim());
              }
            },
          ),
          const Gap(16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () {
                final val = _controller.text.trim();
                if (val.isNotEmpty) {
                  Navigator.pop(context);
                  widget.onSubmitted(val);
                }
              },
              icon: const Icon(Icons.check, size: 18),
              label: const Text(
                'Konfirmasi',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Viewfinder overlay ──────────────────────────────────────
class _ScanFrameOverlay extends StatelessWidget {
  const _ScanFrameOverlay();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Area bidik barcode. Posisikan barcode di dalam kotak.',
      child: CustomPaint(
        size: Size.infinite,
        painter: _ScanFramePainter(color: AppTheme.accent),
      ),
    );
  }
}

class _ScanFramePainter extends CustomPainter {
  final Color color;
  const _ScanFramePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final boxWidth = size.width * 0.78;
    final boxHeight = boxWidth * 0.62;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.42),
      width: boxWidth,
      height: boxHeight,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(16));

    final overlayPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      overlayPath,
      Paint()..color = Colors.black.withOpacity(0.35),
    );

    const bracketLen = 28.0;
    const strokeW = 3.5;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const r = 16.0;

    void drawCorner(Offset pos, Offset dx, Offset dy) {
      canvas.drawLine(pos + dy * r, pos + dy * bracketLen, paint);
      canvas.drawLine(pos + dx * r, pos + dx * bracketLen, paint);
    }

    drawCorner(rect.topLeft, const Offset(1, 0), const Offset(0, 1));
    drawCorner(rect.topRight, const Offset(-1, 0), const Offset(0, 1));
    drawCorner(rect.bottomLeft, const Offset(1, 0), const Offset(0, -1));
    drawCorner(rect.bottomRight, const Offset(-1, 0), const Offset(0, -1));
  }

  @override
  bool shouldRepaint(covariant _ScanFramePainter oldDelegate) => false;
}
