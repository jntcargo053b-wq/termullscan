// ============================================================
// lib/screens/barcode_scan_screen.dart
// Versi refaktor – tanpa ketergantungan pada camera_diagnostics_log.dart
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

// ─── STATE ENUM ──────────────────────────────────────────────
enum ScannerState {
  idle,
  running,
  paused,
  processing,
  navigating,
  error,
}

// ─── ACTIVE SCAN SNAPSHOT ────────────────────────────────────
@immutable
class ActiveScan {
  final String barcode;
  final String? entryId;
  final int photoCount;
  final int videoCount;

  const ActiveScan({
    required this.barcode,
    this.entryId,
    this.photoCount = 0,
    this.videoCount = 0,
  });

  ActiveScan copyWith({
    String? barcode,
    String? entryId,
    int? photoCount,
    int? videoCount,
  }) {
    return ActiveScan(
      barcode: barcode ?? this.barcode,
      entryId: entryId ?? this.entryId,
      photoCount: photoCount ?? this.photoCount,
      videoCount: videoCount ?? this.videoCount,
    );
  }
}

// ─── MAIN SCREEN ─────────────────────────────────────────────
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen>
    with WidgetsBindingObserver, RestorationMixin {
  // ─── RESTORATION ────────────────────────────────────────────
  @override
  String? get restorationId => 'barcode_scan_screen';

  final RestorableInt _scanCountRestorer = RestorableInt(0);
  final RestorableString _activeBarcodeRestorer = RestorableString('');
  final RestorableString _activeEntryIdRestorer = RestorableString('');
  final RestorableInt _activePhotoCountRestorer = RestorableInt(0);
  final RestorableInt _activeVideoCountRestorer = RestorableInt(0);

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_scanCountRestorer, 'scan_count');
    registerForRestoration(_activeBarcodeRestorer, 'active_barcode');
    registerForRestoration(_activeEntryIdRestorer, 'active_entry_id');
    registerForRestoration(_activePhotoCountRestorer, 'active_photo_count');
    registerForRestoration(_activeVideoCountRestorer, 'active_video_count');

    if (_activeBarcodeRestorer.value.isNotEmpty) {
      _activeScanNotifier.value = ActiveScan(
        barcode: _activeBarcodeRestorer.value,
        entryId:
            _activeEntryIdRestorer.value.isEmpty
                ? null
                : _activeEntryIdRestorer.value,
        photoCount: _activePhotoCountRestorer.value,
        videoCount: _activeVideoCountRestorer.value,
      );
      _scanCountNotifier.value = _scanCountRestorer.value;
    }
  }

  // ─── DEPENDENCIES ───────────────────────────────────────────
  final StorageService _storage = StorageService();
  final WatermarkSettings _watermarkSettings = WatermarkSettings();

  // ─── SCANNER CONTROLLER ────────────────────────────────────
  late MobileScannerController _scannerController;
  int _scannerRebuildKey = 0;

  static MobileScannerController _createScannerController() {
    return MobileScannerController(
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
  }

  // ─── STATE ──────────────────────────────────────────────────
  bool _scanning = false;
  bool _isProcessing = false;
  bool _isNavigationLocked = false;
  bool _isResumeScheduled = false;
  bool _isManualFlowInProgress = false;

  ScannerState _scannerState = ScannerState.idle;

  final ValueNotifier<ActiveScan?> _activeScanNotifier =
      ValueNotifier<ActiveScan?>(null);
  final ValueNotifier<int> _scanCountNotifier = ValueNotifier<int>(0);

  // ─── MUTEX UNTUK PROSES ────────────────────────────────────
  bool _isProcessingLocked = false;
  Completer<void>? _processingCompleter;

  // ─── TIMER ──────────────────────────────────────────────────
  Timer? _debounceTimer;
  Timer? _processingWatchdog;
  Timer? _scannerWatchdog;

  static const Duration _debounceDuration = Duration(milliseconds: 250);
  static const int _maxStartAttempts = 5;
  static const int _maxStartBackoffMs = 1500;
  static const int _persistMaxAttempts = 3;

  // ─── GETTERS ────────────────────────────────────────────────
  bool get _isScannerRunning => _scannerController.value.isRunning;
  bool get _canResume =>
      _scannerState == ScannerState.idle ||
      _scannerState == ScannerState.paused ||
      _scannerState == ScannerState.error;

  // ─── LIFECYCLE ──────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scannerController = _createScannerController();
    _requestPermissions();
    _startScannerWatchdog();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounceTimer?.cancel();
    _processingWatchdog?.cancel();
    _scannerWatchdog?.cancel();
    _activeScanNotifier.dispose();
    _scanCountNotifier.dispose();
    _scanCountRestorer.dispose();
    _activeBarcodeRestorer.dispose();
    _activeEntryIdRestorer.dispose();
    _activePhotoCountRestorer.dispose();
    _activeVideoCountRestorer.dispose();
    try {
      _scannerController.stop();
    } catch (_) {}
    _scannerController.dispose();
    if (_watermarkSettings.gpsWatermarkEnabled) {
      PodLocationService.instance.releaseAfterCapture();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (_scanning) {
        try {
          _scannerController.stop();
        } catch (_) {}
        _scanning = false;
        _scannerState = ScannerState.paused;
        debugPrint('📱 App background: scanner stopped');
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!_scanning && !_isNavigationLocked) {
        unawaited(_resumeScanner());
        debugPrint('📱 App foreground: scanner resumed');
      }
    }
  }

  // ─── PERMISSIONS ────────────────────────────────────────────

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
      if (mounted) await _resumeScanner();
    } else {
      if (mounted) await _resumeScanner();
    }
    await PermissionService.requestGalleryPermission();
  }

  void _showPermissionDeniedDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
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

  // ─── NAVIGATION LOCK ────────────────────────────────────────

  void _lockNavigation() {
    _isNavigationLocked = true;
    debugPrint('🔒 Navigation locked');
  }

  void _unlockNavigation() {
    _isNavigationLocked = false;
    debugPrint('🔓 Navigation unlocked');
  }

  // ─── SCANNER CONTROL ──────────────────────────────────────

  Future<bool> _startScannerWithRetry() async {
    for (int i = 0; i < _maxStartAttempts; i++) {
      try {
        if (!_isScannerRunning) {
          await _scannerController.start();

          int attempts = 0;
          while (!_isScannerRunning && attempts < 10) {
            await Future.delayed(const Duration(milliseconds: 50));
            attempts++;
          }

          if (_isScannerRunning) {
            debugPrint('✅ Scanner started on attempt ${i + 1}');
            if (i > 0) {
              debugPrint(
                '📷 [scanner_start] Berhasil pada percobaan ke-${i + 1}/$_maxStartAttempts',
              );
            }
            return true;
          }
        } else {
          return true;
        }
      } catch (e) {
        debugPrint('⚠️ Start attempt ${i + 1} failed: $e');
        debugPrint(
          '📷 [scanner_start_error] Percobaan ${i + 1}/$_maxStartAttempts gagal: $e',
        );
        if (e.toString().toLowerCase().contains('permission')) {
          try {
            await Permission.camera.request();
          } catch (_) {}
        }
        if (i < _maxStartAttempts - 1) {
          final backoff = (300 * (i + 1)).clamp(0, _maxStartBackoffMs);
          await Future.delayed(Duration(milliseconds: backoff));
        }
      }
    }
    debugPrint(
      '📷 [scanner_start_failed] Gagal start setelah $_maxStartAttempts percobaan',
    );
    return false;
  }

  Future<void> _resumeScanner() async {
    if (!mounted) return;
    if (_isResumeScheduled || _isProcessing) return;
    if (!_canResume) {
      debugPrint('⚠️ Cannot resume from state: $_scannerState');
      return;
    }

    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      debugPrint('⚠️ Resume skipped: camera permission not granted');
      return;
    }

    _isResumeScheduled = true;
    bool started = false;

    try {
      started = await _startScannerWithRetry();
      _scannerState = started && _isScannerRunning
          ? ScannerState.running
          : ScannerState.error;
      if (started && _isScannerRunning) {
        debugPrint('✅ Scanner resumed successfully');
      } else {
        debugPrint('⚠️ Scanner failed to resume');
      }
    } catch (e) {
      debugPrint('⚠️ Resume scanner error: $e');
      _scannerState = ScannerState.error;
    } finally {
      _isResumeScheduled = false;
    }

    if (!mounted) return;
    if (started && _isScannerRunning) {
      _scanning = true;
      _debounceTimer?.cancel();
      _debounceTimer = Timer(_debounceDuration, () {});
      debugPrint('✅ Scanner resumed, state: $_scannerState');
    } else {
      _scanning = false;
      debugPrint('⚠️ Scanner failed, state: $_scannerState');
    }
  }

  Future<void> _stopScannerSafely() async {
    try {
      if (_isScannerRunning) {
        await _scannerController.stop();
        _scannerState = ScannerState.paused;
        debugPrint('✅ Scanner stopped, state: $_scannerState');
      }
    } catch (e) {
      debugPrint('⚠️ Error stopping scanner: $e');
      _scannerState = ScannerState.error;
    }
  }

  // ─── RECREATE CONTROLLER ──────────────────────────────────

  Future<void> _recreateScannerController() async {
    if (!mounted) return;
    debugPrint('📷 [scanner_recreate] Mulai recreate');

    try {
      await _scannerController.stop();
    } catch (e) {
      debugPrint('⚠️ Error stop controller: $e');
      debugPrint('📷 [scanner_recreate] Stop gagal: $e');
    }
    try {
      await _scannerController.dispose();
    } catch (e) {
      debugPrint('⚠️ Error dispose controller: $e');
      debugPrint('📷 [scanner_recreate] Dispose gagal: $e');
    }

    await Future.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;

    setState(() {
      _scannerController = _createScannerController();
      _scannerRebuildKey++;
      _scannerState = ScannerState.idle;
      _scanning = false;
    });

    debugPrint('♻️ Controller recreated (rebuild #$_scannerRebuildKey)');
    await _resumeScanner();
    debugPrint(
      '📷 [scanner_recreate] Selesai, status: $_scannerState, running: $_isScannerRunning',
    );
  }

  Future<void> _restartScanner() async {
    if (!mounted || _isNavigationLocked || _isProcessing || _isResumeScheduled) {
      return;
    }
    if (_activeScanNotifier.value != null) {
      debugPrint('⚠️ Restart skipped: active scan exists');
      return;
    }
    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      debugPrint('⚠️ Restart skipped: no camera permission');
      return;
    }

    debugPrint('🔄 Restarting scanner...');
    try {
      await _scannerController.stop();

      int attempts = 0;
      while (_isScannerRunning && attempts < 40) {
        await Future.delayed(const Duration(milliseconds: 50));
        attempts++;
      }
      if (_isScannerRunning) {
        debugPrint('⚠️ Scanner still running after 2s, force error');
        _scannerState = ScannerState.error;
        _scanning = false;
        return;
      }

      bool started = false;
      for (int i = 0; i < 3; i++) {
        try {
          if (!_isScannerRunning) {
            await _scannerController.start();
            int wait = 0;
            while (!_isScannerRunning && wait < 10) {
              await Future.delayed(const Duration(milliseconds: 50));
              wait++;
            }
            if (_isScannerRunning) {
              started = true;
              break;
            }
          } else {
            started = true;
            break;
          }
        } catch (e) {
          debugPrint('⚠️ Restart attempt ${i + 1} failed: $e');
          if (e.toString().toLowerCase().contains('permission')) {
            await Permission.camera.request();
          }
          if (i < 2) await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
        }
      }

      if (started && _isScannerRunning) {
        _scanning = true;
        _scannerState = ScannerState.running;
        _debounceTimer?.cancel();
        _debounceTimer = Timer(_debounceDuration, () {});
        debugPrint('✅ Scanner restarted successfully');
      } else {
        _scanning = false;
        _scannerState = ScannerState.error;
        debugPrint('❌ Scanner restart failed');
      }
    } catch (e) {
      debugPrint('❌ Restart error: $e');
      _scanning = false;
      _scannerState = ScannerState.error;
    }
  }

  // ─── WATCHDOGS ──────────────────────────────────────────────

  void _startProcessingWatchdog() {
    _processingWatchdog?.cancel();
    _processingWatchdog = Timer(const Duration(seconds: 20), () {
      if (_isProcessing) {
        debugPrint('⚠️ Processing watchdog triggered, resetting');
        _isProcessing = false;
        _activeScanNotifier.value = null;
        if (!_isNavigationLocked && mounted) _resumeScanner();
      }
    });
  }

  void _startScannerWatchdog() {
    _scannerWatchdog?.cancel();
    _scannerWatchdog = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final cameraStatus = await Permission.camera.status;
      if (!cameraStatus.isGranted) return;

      if (_scanning &&
          !_isScannerRunning &&
          !_isProcessing &&
          !_isNavigationLocked &&
          _activeScanNotifier.value == null) {
        debugPrint('⚠️ Watchdog: state mismatch, restarting');
        debugPrint('📷 [scanner_watchdog] State mismatch terdeteksi, memicu _restartScanner()');
        _restartScanner();
      }
    });
  }

  void _scheduleActiveScanClear() {
    Future.delayed(const Duration(seconds: 30), () {
      if (mounted && _activeScanNotifier.value != null) {
        final active = _activeScanNotifier.value;
        if (active != null && active.photoCount == 0 && active.videoCount == 0) {
          _activeScanNotifier.value = null;
          _clearRestorationActive();
          debugPrint('🗑️ Active scan cleared after timeout');
          if (!_isNavigationLocked) _resumeScanner();
        }
      }
    });
  }

  void _clearRestorationActive() {
    _activeBarcodeRestorer.value = '';
    _activeEntryIdRestorer.value = '';
    _activePhotoCountRestorer.value = 0;
    _activeVideoCountRestorer.value = 0;
  }

  // ─── PROCESSING LOCK ────────────────────────────────────────

  Future<void> _executeWithProcessingLock(Future<void> Function() action) async {
    if (_isProcessingLocked) {
      debugPrint('⚠️ Processing locked, waiting...');
      if (_processingCompleter != null) {
        await _processingCompleter!.future;
      }
      return;
    }

    _isProcessingLocked = true;
    _processingCompleter = Completer<void>();
    try {
      await action();
    } finally {
      _isProcessingLocked = false;
      if (_processingCompleter != null && !_processingCompleter!.isCompleted) {
        _processingCompleter!.complete();
      }
      _processingCompleter = null;
    }
  }

  // ─── TORCH & CAMERA ─────────────────────────────────────────

  void _toggleTorch() {
    try {
      if (_scannerController.value.torchState != null) {
        _scannerController.toggleTorch();
        debugPrint('✅ Torch toggled');
      } else {
        debugPrint('⚠️ No torch support');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Device tidak mendukung lampu sentuh'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('⚠️ Torch error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Gagal mengaktifkan lampu sentuh'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  void _switchCamera() {
    try {
      _scannerController.switchCamera();
      debugPrint('✅ Camera switched');
    } catch (e) {
      debugPrint('⚠️ Switch camera error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Device hanya memiliki satu kamera'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  // ─── BARCODE DETECTION ──────────────────────────────────────

  void _onDetect(BarcodeCapture capture) {
    if (!_scanning || _isProcessing) return;
    if (_debounceTimer?.isActive ?? false) return;

    final barcode = capture.barcodes.isNotEmpty ? capture.barcodes.first : null;
    if (barcode == null) return;

    final code = barcode.rawValue ?? barcode.displayValue;
    if (code == null || code.isEmpty) return;

    _isProcessing = true;
    _scannerState = ScannerState.processing;
    _startProcessingWatchdog();
    _scanning = false;
    _debounceTimer = Timer(_debounceDuration, () {});

    final active = ActiveScan(barcode: code);
    _activeScanNotifier.value = active;
    _activeBarcodeRestorer.value = code;
    _activeEntryIdRestorer.value = '';
    _activePhotoCountRestorer.value = 0;
    _activeVideoCountRestorer.value = 0;

    unawaited(_stopScannerSafely());
    unawaited(_processDetectedBarcode(code: code, format: barcode.format.name));
  }

  Future<void> _processDetectedBarcode({
    required String code,
    required String format,
  }) async {
    await _executeWithProcessingLock(() async {
      try {
        HapticFeedback.mediumImpact();

        final gpsOn = _watermarkSettings.gpsWatermarkEnabled;
        if (gpsOn) {
          unawaited(PodLocationService.instance.acquireForCapture());
        }
        final locState = gpsOn ? PodLocationService.instance.currentState : null;

        final entry = ScanEntry(
          id: _storage.generateId(),
          type: ScanType.barcode,
          value: code,
          timestamp: DateTime.now(),
          operatorName:
              _watermarkSettings.operatorName.isNotEmpty
                  ? _watermarkSettings.operatorName
                  : 'Operator',
          companyName: _watermarkSettings.companyName,
          latitude: locState?.lat,
          longitude: locState?.lon,
          locationName: (locState != null && locState.address.isNotEmpty)
              ? locState.address
              : null,
          isManual: false,
        );

        if (!mounted) return;

        _scanCountNotifier.value++;
        _scanCountRestorer.value = _scanCountNotifier.value;
        _activeScanNotifier.value = ActiveScan(
          barcode: code,
          entryId: entry.id,
        );
        _activeEntryIdRestorer.value = entry.id;
        _scheduleActiveScanClear();

        unawaited(_persistEntryAsync(entry, gpsOn));
      } catch (e) {
        debugPrint('❌ Error _processDetectedBarcode: $e');
        _activeScanNotifier.value = null;
        _clearRestorationActive();
        _processingWatchdog?.cancel();
        _isProcessing = false;
        _scannerState = ScannerState.error;
        if (mounted) await _resumeScanner();
      } finally {
        _processingWatchdog?.cancel();
        _isProcessing = false;
        _scannerState = ScannerState.paused;
      }
    });
  }

  // ─── PERSIST ENTRY (ASYNC) ─────────────────────────────────

  Future<void> _persistEntryAsync(ScanEntry entry, bool gpsOn) async {
    Object? lastError;
    for (int i = 0; i < _persistMaxAttempts; i++) {
      try {
        await _storage.add(entry);
        if (gpsOn) {
          unawaited(_attachLocationUpdate(entry.id));
        }
        return;
      } catch (e) {
        lastError = e;
        debugPrint('⚠️ Simpan entry attempt ${i + 1}/$_persistMaxAttempts gagal: $e');
        if (i < _persistMaxAttempts - 1) {
          await Future.delayed(Duration(milliseconds: 200 * (i + 1)));
        }
      }
    }

    debugPrint('❌ Gagal total simpan entry ${entry.id}: $lastError');
    debugPrint(
      '📷 [db_add_error] Gagal simpan entry ${entry.id} setelah $_persistMaxAttempts percobaan: $lastError',
    );

    if (_scanCountNotifier.value > 0) {
      _scanCountNotifier.value--;
      _scanCountRestorer.value = _scanCountNotifier.value;
    }

    if (!mounted) return;

    if (_activeScanNotifier.value?.entryId == entry.id) {
      _activeScanNotifier.value = null;
      _clearRestorationActive();
      if (!_isNavigationLocked) unawaited(_resumeScanner());
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('⚠️ Gagal menyimpan scan ke database, silakan scan ulang'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  // ─── GPS UPDATE ─────────────────────────────────────────────

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

  // ─── MANUAL INPUT ───────────────────────────────────────────

  void _showManualInput() {
    if (_isProcessing || _activeScanNotifier.value != null) return;

    _lockNavigation();
    _isManualFlowInProgress = true;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder:
          (_) => _ManualInputDialog(
            onSubmitted: (code) => _confirmAndProcessManualCode(code),
          ),
    ).whenComplete(() {
      _unlockNavigation();
      if (!_isManualFlowInProgress && !_isProcessing && mounted) {
        _resumeScanner();
      }
    });
  }

  Future<void> _confirmAndProcessManualCode(String code) async {
    if (!mounted) return;
    bool reopenedManualInput = false;

    bool isDuplicate = false;
    try {
      final existing = await _storage.getEntries(
        searchQuery: code,
        period: 'Hari ini',
        limit: 5,
      );
      isDuplicate = existing.any((e) => e.value == code);
    } catch (e) {
      debugPrint('⚠️ Gagal cek duplikat manual: $e');
    }

    if (!mounted) return;

    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (_) => AlertDialog(
              backgroundColor: AppTheme.surface,
              title: Text(
                isDuplicate ? '⚠️ Kode Sudah Pernah Diinput' : 'Konfirmasi Kode',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isDuplicate)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Text(
                        'Kode ini sudah tercatat hari ini. Pastikan tidak salah ketik/duplikat sebelum lanjut.',
                        style: TextStyle(color: AppTheme.error, fontSize: 12.5),
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Text(
                        'Pastikan nomor resi berikut sudah benar sebelum disimpan:',
                        style: TextStyle(color: Colors.grey, fontSize: 12.5),
                      ),
                    ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isDuplicate ? AppTheme.error : AppTheme.accent,
                      ),
                    ),
                    child: Text(
                      code,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Ketik Ulang', style: TextStyle(color: Colors.grey)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(
                    isDuplicate ? 'Tetap Simpan' : 'Konfirmasi',
                    style: TextStyle(
                      color: isDuplicate ? AppTheme.error : AppTheme.accent,
                    ),
                  ),
                ),
              ],
            ),
      );

      if (confirmed == true) {
        await _processManualCode(code);
      } else if (mounted) {
        reopenedManualInput = true;
        _showManualInput();
      }
    } finally {
      if (!reopenedManualInput) {
        _isManualFlowInProgress = false;
        if (mounted && !_isProcessing) {
          await _resumeScanner();
        }
      }
    }
  }

  Future<void> _processManualCode(String code) async {
    await _executeWithProcessingLock(() async {
      try {
        HapticFeedback.mediumImpact();

        final gpsOn = _watermarkSettings.gpsWatermarkEnabled;
        if (gpsOn) {
          unawaited(PodLocationService.instance.acquireForCapture());
        }
        final locState = gpsOn ? PodLocationService.instance.currentState : null;

        final entry = ScanEntry(
          id: _storage.generateId(),
          type: ScanType.manual,
          value: code,
          timestamp: DateTime.now(),
          operatorName:
              _watermarkSettings.operatorName.isNotEmpty
                  ? _watermarkSettings.operatorName
                  : 'Operator',
          companyName: _watermarkSettings.companyName,
          latitude: locState?.lat,
          longitude: locState?.lon,
          locationName: (locState != null && locState.address.isNotEmpty)
              ? locState.address
              : null,
          isManual: true,
        );

        if (!mounted) return;

        _scanCountNotifier.value++;
        _scanCountRestorer.value = _scanCountNotifier.value;
        _activeScanNotifier.value = ActiveScan(barcode: code, entryId: entry.id);
        _activeBarcodeRestorer.value = code;
        _activeEntryIdRestorer.value = entry.id;
        _activePhotoCountRestorer.value = 0;
        _activeVideoCountRestorer.value = 0;

        _scheduleActiveScanClear();
        unawaited(_persistEntryAsync(entry, gpsOn));
        await _stopScannerSafely();
      } catch (e) {
        debugPrint('❌ Error _processManualCode: $e');
        _activeScanNotifier.value = null;
        _clearRestorationActive();
        _processingWatchdog?.cancel();
        _isProcessing = false;
        _scannerState = ScannerState.error;
        if (mounted) await _resumeScanner();
      } finally {
        _processingWatchdog?.cancel();
        _isProcessing = false;
        _scannerState = ScannerState.paused;
      }
    });
  }

  // ─── NAVIGASI KE FOTO / VIDEO ──────────────────────────────

  Future<void> _goToPhotoScan() async {
    await _navigateToMediaScan(isVideo: false);
  }

  Future<void> _goToVideoScan() async {
    await _navigateToMediaScan(isVideo: true);
  }

  Future<void> _navigateToMediaScan({required bool isVideo}) async {
    final active = _activeScanNotifier.value;
    if (active == null || active.entryId == null) return;

    final barcode = active.barcode;
    final entryId = active.entryId!;

    _lockNavigation();
    _scannerState = ScannerState.navigating;
    _scanning = false;

    try {
      if (isVideo) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoScanScreen(barcode: barcode, entryId: entryId),
          ),
        );
      } else {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder:
                (_) => PhotoScanScreen(
                  barcode: barcode,
                  entryId: entryId,
                  batchMode: false,
                ),
          ),
        );
      }

      final entry = await _storage.getEntry(entryId);
      final photoCount = entry?.imagePath?.split(',').length ?? 0;
      final videoCount = entry?.videoPath != null ? 1 : 0;

      if (mounted) {
        _activeScanNotifier.value = ActiveScan(
          barcode: barcode,
          entryId: entryId,
          photoCount: photoCount,
          videoCount: videoCount,
        );
        _activePhotoCountRestorer.value = photoCount;
        _activeVideoCountRestorer.value = videoCount;
        debugPrint('📊 Media: Photos=$photoCount, Videos=$videoCount');
      }
    } catch (e) {
      debugPrint('❌ Error navigasi ke ${isVideo ? "video" : "foto"}: $e');
    } finally {
      if (mounted) {
        await _recreateScannerController();
      }
      _unlockNavigation();
    }
  }

  // ─── WATERMARK SETTINGS ─────────────────────────────────────

  void _openWatermarkSettings() {
    _lockNavigation();
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
        _unlockNavigation();
      });
    } catch (e) {
      debugPrint('❌ Error watermark settings: $e');
      _unlockNavigation();
    }
  }

  // ─── BUILD ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder<int>(
          valueListenable: _scanCountNotifier,
          builder: (context, count, _) => Text('Scanner ($count)'),
        ),
        actions: [
          ValueListenableBuilder<ActiveScan?>(
            valueListenable: _activeScanNotifier,
            builder: (context, active, _) => IconButton(
              onPressed: active != null ? null : _showManualInput,
              icon: const Icon(Icons.keyboard, color: Colors.white),
              tooltip: 'Input Manual',
            ),
          ),
          IconButton(
            onPressed: _toggleTorch,
            icon: const Icon(Icons.flash_on, color: Colors.white),
            tooltip: 'Lampu Sentuh',
          ),
          IconButton(
            onPressed: _switchCamera,
            icon: const Icon(Icons.flip_camera_android, color: Colors.white),
            tooltip: 'Ganti Kamera',
          ),
          ListenableBuilder(
            listenable: _watermarkSettings,
            builder: (context, _) => IconButton(
              onPressed: _openWatermarkSettings,
              icon: Stack(
                children: [
                  const Icon(Icons.tune, color: Colors.white),
                  if (_watermarkSettings.operatorName.isNotEmpty ||
                      _watermarkSettings.hasLogo)
                    const Positioned(
                      right: 0,
                      top: 0,
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
            key: ValueKey(_scannerRebuildKey),
            child: MobileScanner(
              controller: _scannerController,
              onDetect: _onDetect,
            ),
          ),
          ValueListenableBuilder<ActiveScan?>(
            valueListenable: _activeScanNotifier,
            builder: (context, active, _) {
              return Stack(
                children: [
                  // Watermark info (when no active scan)
                  if (active == null) _buildWatermarkInfo(),

                  // Viewfinder overlay (when no active scan)
                  if (active == null)
                    const Positioned.fill(
                      child: IgnorePointer(child: _ScanFrameOverlay()),
                    ),

                  // Active scan info bar
                  if (active != null) _buildActiveScanBar(active),

                  // Close button
                  if (active != null) _buildCloseButton(),

                  // Action buttons (Photo & Video)
                  if (active != null && active.entryId != null)
                    _buildMediaActionButtons(),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ─── UI SUB-WIDGETS ────────────────────────────────────────

  Widget _buildWatermarkInfo() {
    return ListenableBuilder(
      listenable: _watermarkSettings,
      builder: (context, _) {
        if (_watermarkSettings.operatorName.isEmpty &&
            !_watermarkSettings.hasLogo) {
          return const SizedBox.shrink();
        }
        return Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(
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
                  if (_watermarkSettings.operatorName.isNotEmpty) ...[
                    const Icon(Icons.person, color: AppTheme.accent, size: 12),
                    const Gap(5),
                    Text(
                      _watermarkSettings.operatorName,
                      style: const TextStyle(
                        color: AppTheme.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (_watermarkSettings.hasLogo) ...[
                    if (_watermarkSettings.operatorName.isNotEmpty)
                      const Gap(8),
                    const Icon(Icons.business, color: Colors.white54, size: 12),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildActiveScanBar(ActiveScan active) {
    return Positioned(
      top: 12,
      left: 0,
      right: 0,
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
            Row(
              children: [
                if (active.photoCount > 0) ...[
                  const Icon(Icons.photo_camera, color: AppTheme.accent, size: 14),
                  const Gap(4),
                  Text(
                    '${active.photoCount}',
                    style: const TextStyle(
                      color: AppTheme.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (active.videoCount > 0) ...[
                  const Gap(8),
                  const Icon(Icons.videocam, color: Colors.blue, size: 14),
                  const Gap(4),
                  Text(
                    '${active.videoCount}',
                    style: const TextStyle(
                      color: Colors.blue,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (active.photoCount == 0 && active.videoCount == 0) ...[
                  const Text(
                    '0 media',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloseButton() {
    return Positioned(
      top: 12,
      right: 12,
      child: IconButton(
        icon: const Icon(Icons.close, color: Colors.white70),
        onPressed: () {
          _activeScanNotifier.value = null;
          _clearRestorationActive();
          _resumeScanner();
        },
        tooltip: 'Tutup',
      ),
    );
  }

  Widget _buildMediaActionButtons() {
    return Positioned(
      bottom: 40,
      left: 0,
      right: 0,
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
    );
  }
}

// ─── MANUAL INPUT DIALOG ─────────────────────────────────────

class _ManualInputDialog extends StatefulWidget {
  final Future<void> Function(String code) onSubmitted;

  const _ManualInputDialog({required this.onSubmitted, super.key});

  @override
  State<_ManualInputDialog> createState() => _ManualInputDialogState();
}

class _ManualInputDialogState extends State<_ManualInputDialog> {
  static const int _minCodeLength = 4;

  final TextEditingController _controller = TextEditingController();
  String? _errorText;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Kode tidak boleh kosong';
    if (trimmed.length < _minCodeLength) {
      return 'Kode minimal $_minCodeLength karakter';
    }
    return null;
  }

  void _handleSubmit(String rawValue) async {
    if (_isSubmitting) return;

    final trimmed = rawValue.trim();
    final error = _validate(trimmed);
    if (error != null) {
      setState(() => _errorText = error);
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      Navigator.pop(context);
      await widget.onSubmitted(trimmed);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
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
            textCapitalization: TextCapitalization.characters,
            enabled: !_isSubmitting,
            decoration: InputDecoration(
              hintText: 'Contoh: 8991234567890',
              hintStyle: const TextStyle(color: Colors.grey),
              errorText: _errorText,
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
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppTheme.error, width: 1.5),
              ),
              prefixIcon: const Icon(Icons.qr_code, color: Colors.grey),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear, color: Colors.grey, size: 18),
                onPressed:
                    _isSubmitting
                        ? null
                        : () {
                          setState(() {
                            _controller.clear();
                            _errorText = null;
                          });
                        },
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            onChanged: (_) {
              if (_errorText != null) setState(() => _errorText = null);
            },
            textInputAction: TextInputAction.done,
            onSubmitted: _handleSubmit,
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
              onPressed: _isSubmitting ? null : () => _handleSubmit(_controller.text),
              icon:
                  _isSubmitting
                      ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                      : const Icon(Icons.check, size: 18),
              label: Text(
                _isSubmitting ? 'Menyimpan...' : 'Konfirmasi',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── VIEWFINDER OVERLAY ──────────────────────────────────────

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
