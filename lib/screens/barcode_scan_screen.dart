// ============================================================
// lib/screens/barcode_scan_screen.dart (PRODUKSI FINAL - ALL ERRORS FIXED)
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

// ─── STATE MACHINE ────────────────────────────────────────────
enum _ScannerState {
  idle,
  running,
  paused,
  processing,
  navigating,
  error,
}

/// Snapshot barcode yang sedang aktif
@immutable
class _ActiveScan {
  final String barcode;
  final String? entryId;
  final int photoCount;
  final int videoCount;

  const _ActiveScan({
    required this.barcode,
    this.entryId,
    this.photoCount = 0,
    this.videoCount = 0,
  });

  _ActiveScan copyWith({
    String? entryId,
    int? photoCount,
    int? videoCount,
  }) => _ActiveScan(
        barcode: barcode,
        entryId: entryId ?? this.entryId,
        photoCount: photoCount ?? this.photoCount,
        videoCount: videoCount ?? this.videoCount,
      );
}

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen>
    with WidgetsBindingObserver, RestorationMixin {
  // ─── RESTORATION ─────────────────────────────────────────────
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
      _activeScanVN.value = _ActiveScan(
        barcode: _activeBarcodeRestorer.value,
        entryId: _activeEntryIdRestorer.value.isEmpty ? null : _activeEntryIdRestorer.value,
        photoCount: _activePhotoCountRestorer.value,
        videoCount: _activeVideoCountRestorer.value,
      );
      _scanCountVN.value = _scanCountRestorer.value;
    }
  }

  // ─── STATE ────────────────────────────────────────────────────
  bool _scanning = true;
  bool _processingScan = false;
  bool _navigationLocked = false;
  bool _resumeScheduled = false;
  Timer? _processingWatchdog;
  Timer? _scannerWatchdog;
  _ScannerState _scannerState = _ScannerState.idle;

  // ─── MUTEX UNTUK PROCESSING ─────────────────────────────────
  Completer<void>? _processingCompleter;
  bool _isProcessingLocked = false;

  // ─── STATE (mempengaruhi UI) ────────────────────────────────
  final ValueNotifier<_ActiveScan?> _activeScanVN = ValueNotifier(null);
  final ValueNotifier<int> _scanCountVN = ValueNotifier(0);

  // ─── DEBOUNCE ────────────────────────────────────────────────
  Timer? _debounceTimer;
  static const Duration _debounceDuration = Duration(milliseconds: 250);

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

  // ─── GETTER ──────────────────────────────────────────────────
  bool get _isScannerRunning => _scannerController.value.isRunning;
  bool get _canResume =>
      _scannerState == _ScannerState.idle ||
      _scannerState == _ScannerState.paused ||
      _scannerState == _ScannerState.error;

  // ─── LIFECYCLE ────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _startScannerWatchdog();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounceTimer?.cancel();
    _processingWatchdog?.cancel();
    _scannerWatchdog?.cancel();
    _activeScanVN.dispose();
    _scanCountVN.dispose();
    _scanCountRestorer.dispose();
    _activeBarcodeRestorer.dispose();
    _activeEntryIdRestorer.dispose();
    _activePhotoCountRestorer.dispose();
    _activeVideoCountRestorer.dispose();
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
        _scannerState = _ScannerState.paused;
        debugPrint('📱 App background: scanner stopped');
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!_scanning && !_navigationLocked) {
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
      if (mounted) await _resumeScanning();
    } else {
      if (mounted) await _resumeScanning();
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

  // ─── NAVIGATION LOCK ─────────────────────────────────────────

  void _lockNavigation() {
    _navigationLocked = true;
    debugPrint('🔒 Navigation locked');
  }

  void _unlockNavigation() {
    _navigationLocked = false;
    debugPrint('🔓 Navigation unlocked');
  }

  // ─── SCANNER CONTROL ──────────────────────────────────────

  Future<bool> _startScannerWithRetry() async {
    for (int i = 0; i < 3; i++) {
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
            return true;
          }
        } else {
          return true;
        }
      } catch (e) {
        debugPrint('⚠️ Start attempt ${i + 1} failed: $e');
        if (i < 2) {
          await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
        }
      }
    }
    return false;
  }

  Future<void> _resumeScanning() async {
    if (!mounted) return;
    if (_resumeScheduled || _processingScan) return;
    if (!_canResume) {
      debugPrint('⚠️ Cannot resume from state: $_scannerState');
      return;
    }

    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      debugPrint('⚠️ Resume skipped: camera permission not granted');
      return;
    }

    _resumeScheduled = true;
    bool started = false;
    
    try {
      started = await _startScannerWithRetry();
      
      if (started && _isScannerRunning) {
        _scannerState = _ScannerState.running;
        debugPrint('✅ Scanner resumed successfully');
      } else {
        _scannerState = _ScannerState.error;
        debugPrint('⚠️ Scanner failed to resume');
      }
    } catch (e) {
      debugPrint('⚠️ Resume scanner error: $e');
      _scannerState = _ScannerState.error;
    } finally {
      _resumeScheduled = false;
    }

    if (!mounted) return;
    
    if (started && _isScannerRunning) {
      _scanning = true;
      _debounceTimer?.cancel();
      _debounceTimer = Timer(_debounceDuration, () {});
      debugPrint('✅ Scanner resumed successfully, state: $_scannerState');
    } else {
      _scanning = false;
      debugPrint('⚠️ Scanner failed to resume, state: $_scannerState');
    }
  }

  Future<void> _stopScannerSafely() async {
    try {
      if (_isScannerRunning) {
        await _scannerController.stop();
        _scannerState = _ScannerState.paused;
        debugPrint('✅ Scanner stopped, state: $_scannerState');
      }
    } catch (e) {
      debugPrint('⚠️ Error stopping scanner: $e');
      _scannerState = _ScannerState.error;
    }
  }

  Future<void> _restartScanner() async {
    if (!mounted) {
      debugPrint('⚠️ Restart skipped: not mounted');
      return;
    }
    if (_navigationLocked) {
      debugPrint('⚠️ Restart skipped: navigation locked');
      return;
    }
    if (_processingScan) {
      debugPrint('⚠️ Restart skipped: processing scan');
      return;
    }
    if (_activeScanVN.value != null) {
      debugPrint('⚠️ Restart skipped: active scan exists');
      return;
    }
    if (_resumeScheduled) {
      debugPrint('⚠️ Restart skipped: resume already scheduled');
      return;
    }
    
    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      debugPrint('⚠️ Restart skipped: camera permission not granted');
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
        debugPrint('⚠️ Scanner still running after 2s, forcing reset');
        _scannerState = _ScannerState.error;
        _scanning = false;
        return;
      }
      
      debugPrint('✅ Scanner stopped after ${attempts * 50}ms');
      
      bool started = false;
      for (int i = 0; i < 3; i++) {
        try {
          if (!_isScannerRunning) {
            await _scannerController.start();
            
            int waitAttempts = 0;
            while (!_isScannerRunning && waitAttempts < 10) {
              await Future.delayed(const Duration(milliseconds: 50));
              waitAttempts++;
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
          debugPrint('⚠️ Start attempt ${i + 1} failed: $e');
          if (i < 2) {
            await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
          }
        }
      }
      
      if (started && _isScannerRunning) {
        _scanning = true;
        _scannerState = _ScannerState.running;
        _debounceTimer?.cancel();
        _debounceTimer = Timer(_debounceDuration, () {});
        debugPrint('✅ Scanner restarted successfully');
      } else {
        _scanning = false;
        _scannerState = _ScannerState.error;
        debugPrint('❌ Scanner restart failed after 3 attempts');
      }
    } catch (e) {
      debugPrint('❌ Restart failed: $e');
      _scanning = false;
      _scannerState = _ScannerState.error;
    }
  }

  // ─── WATCHDOG METHODS ──────────────────────────────────────

  void _startProcessingWatchdog() {
    _processingWatchdog?.cancel();
    _processingWatchdog = Timer(const Duration(seconds: 20), () {
      if (_processingScan) {
        debugPrint('⚠️ Processing watchdog triggered - resetting state');
        _processingScan = false;
        _activeScanVN.value = null;
        if (!_navigationLocked && mounted) {
          _resumeScanning();
        }
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
      if (!cameraStatus.isGranted) {
        debugPrint('⚠️ Scanner watchdog: Camera permission not granted');
        return;
      }
      
      if (_scanning && 
          !_isScannerRunning && 
          !_processingScan && 
          !_navigationLocked &&
          _activeScanVN.value == null) {
        debugPrint('⚠️ Scanner watchdog: State mismatch - running: $_scanning, actual: $_isScannerRunning');
        _restartScanner();
      }
    });
  }

  void _scheduleActiveScanClear() {
    Future.delayed(const Duration(seconds: 30), () {
      if (mounted && _activeScanVN.value != null) {
        final active = _activeScanVN.value;
        if (active != null && active.photoCount == 0 && active.videoCount == 0) {
          _activeScanVN.value = null;
          _activeBarcodeRestorer.value = '';
          _activeEntryIdRestorer.value = '';
          _activePhotoCountRestorer.value = 0;
          _activeVideoCountRestorer.value = 0;
          debugPrint('🗑️ Active scan cleared after 30s timeout');
          if (!_navigationLocked) {
            _resumeScanning();
          }
        }
      }
    });
  }

  // ─── PROCESSING LOCK ─────────────────────────────────────────

  Future<void> _executeWithProcessingLock(Future<void> Function() action) async {
    if (_isProcessingLocked) {
      debugPrint('⚠️ Processing already locked, waiting...');
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

  // ─── TORCH & CAMERA ────────────────────────────────────────────

  void _toggleTorch() {
    try {
      // ✅ FIX: Cek torchState untuk mengetahui apakah torch tersedia
      // MobileScanner versi 5.x menggunakan torchState
      if (_scannerController.value.torchState != null) {
        _scannerController.toggleTorch();
        debugPrint('✅ Torch toggled');
      } else {
        debugPrint('⚠️ Device does not support torch');
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
      debugPrint('⚠️ Error toggling torch: $e');
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
      // ✅ FIX: Langsung switch, MobileScanner akan throw jika tidak tersedia
      _scannerController.switchCamera();
      debugPrint('✅ Camera switched');
    } catch (e) {
      debugPrint('⚠️ Error switching camera: $e');
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

  // ─── BARCODE DETECTION ────────────────────────────────────

  void _onDetect(BarcodeCapture capture) {
    if (!_scanning || _processingScan) return;
    if (_debounceTimer?.isActive ?? false) return;

    final barcode = capture.barcodes.isNotEmpty ? capture.barcodes.first : null;
    if (barcode == null) return;
    
    final code = barcode.rawValue ?? barcode.displayValue;
    if (code == null || code.isEmpty) return;

    _processingScan = true;
    _scannerState = _ScannerState.processing;
    _startProcessingWatchdog();
    _scanning = false;
    _debounceTimer = Timer(_debounceDuration, () {});
    _activeScanVN.value = _ActiveScan(barcode: code);
    
    _activeBarcodeRestorer.value = code;
    _activeEntryIdRestorer.value = '';
    _activePhotoCountRestorer.value = 0;
    _activeVideoCountRestorer.value = 0;

    unawaited(_processDetectedBarcode(code: code, format: barcode.format.name));
  }

  Future<void> _processDetectedBarcode({
    required String code,
    required String format,
  }) async {
    await _executeWithProcessingLock(() async {
      try {
        HapticFeedback.mediumImpact();

        if (_wmSettings.gpsWatermarkEnabled) {
          unawaited(PodLocationService.instance.acquireForCapture());
        }
        
        final gpsOn = _wmSettings.gpsWatermarkEnabled;
        final locState = gpsOn ? PodLocationService.instance.currentState : null;
        
        final entry = ScanEntry(
          id: _storage.generateId(),
          type: ScanType.barcode,
          value: code,
          timestamp: DateTime.now(),
          operatorName: _wmSettings.operatorName.isNotEmpty 
              ? _wmSettings.operatorName 
              : 'Operator',
          companyName: _wmSettings.companyName,
          latitude: locState?.lat,
          longitude: locState?.lon,
          locationName: (locState != null && locState.address.isNotEmpty) ? locState.address : null,
          isManual: false,
        );
        await _storage.add(entry);
        if (gpsOn) unawaited(_attachLocationUpdate(entry.id));

        if (!mounted) return;
        _scanCountVN.value++;
        _scanCountRestorer.value = _scanCountVN.value;
        _activeScanVN.value = _activeScanVN.value?.copyWith(entryId: entry.id);
        
        _activeEntryIdRestorer.value = entry.id;
        
        _scheduleActiveScanClear();

        await _stopScannerSafely();
        
      } catch (e) {
        debugPrint('❌ Error _processDetectedBarcode: $e');
        _activeScanVN.value = null;
        _activeBarcodeRestorer.value = '';
        _activeEntryIdRestorer.value = '';
        _activePhotoCountRestorer.value = 0;
        _activeVideoCountRestorer.value = 0;
        _processingWatchdog?.cancel();
        _processingScan = false;
        _scannerState = _ScannerState.error;
        if (mounted) {
          await _resumeScanning();
        }
      } finally {
        if (_wmSettings.gpsWatermarkEnabled) {
          PodLocationService.instance.releaseAfterCapture();
        }
        _processingWatchdog?.cancel();
        _processingScan = false;
        _scannerState = _ScannerState.paused;
      }
    });
  }

  // ─── MANUAL INPUT ─────────────────────────────────────────

  void _showManualInput() {
    if (_processingScan || _activeScanVN.value != null) return;
    
    _lockNavigation();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ManualInputDialog(
        onSubmitted: (code) => _confirmAndProcessManualCode(code),
      ),
    ).whenComplete(() {
      _unlockNavigation();
      if (!_processingScan && mounted) {
        _resumeScanning();
      }
    });
  }

  Future<void> _confirmAndProcessManualCode(String code) async {
    if (!mounted) return;

    bool isDuplicate = false;
    try {
      final existing = await _storage.getEntries(
        searchQuery: code,
        period: 'Hari ini',
        limit: 5,
      );
      isDuplicate = existing.any((e) => e.value == code);
    } catch (e) {
      debugPrint('⚠️ Gagal cek duplikat kode manual: $e');
      isDuplicate = false;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
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
              style: TextStyle(color: isDuplicate ? AppTheme.error : AppTheme.accent),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _processManualCode(code);
    } else if (mounted) {
      _showManualInput();
    }
  }

  Future<void> _processManualCode(String code) async {
    await _executeWithProcessingLock(() async {
      try {
        HapticFeedback.mediumImpact();

        if (_wmSettings.gpsWatermarkEnabled) {
          unawaited(PodLocationService.instance.acquireForCapture());
        }
        
        final gpsOn = _wmSettings.gpsWatermarkEnabled;
        final locState = gpsOn ? PodLocationService.instance.currentState : null;
        
        final entry = ScanEntry(
          id: _storage.generateId(),
          type: ScanType.manual,
          value: code,
          timestamp: DateTime.now(),
          operatorName: _wmSettings.operatorName.isNotEmpty 
              ? _wmSettings.operatorName 
              : 'Operator',
          companyName: _wmSettings.companyName,
          latitude: locState?.lat,
          longitude: locState?.lon,
          locationName: (locState != null && locState.address.isNotEmpty) ? locState.address : null,
          isManual: true,
        );
        await _storage.add(entry);
        if (gpsOn) unawaited(_attachLocationUpdate(entry.id));

        if (!mounted) return;
        _scanCountVN.value++;
        _scanCountRestorer.value = _scanCountVN.value;
        _activeScanVN.value = _activeScanVN.value?.copyWith(entryId: entry.id);
        
        _activeBarcodeRestorer.value = code;
        _activeEntryIdRestorer.value = entry.id;
        _activePhotoCountRestorer.value = 0;
        _activeVideoCountRestorer.value = 0;
        
        _scheduleActiveScanClear();

        await _stopScannerSafely();
        
      } catch (e) {
        debugPrint('❌ Error _processManualCode: $e');
        _activeScanVN.value = null;
        _activeBarcodeRestorer.value = '';
        _activeEntryIdRestorer.value = '';
        _activePhotoCountRestorer.value = 0;
        _activeVideoCountRestorer.value = 0;
        _processingWatchdog?.cancel();
        _processingScan = false;
        _scannerState = _ScannerState.error;
        if (mounted) {
          await _resumeScanning();
        }
      } finally {
        if (_wmSettings.gpsWatermarkEnabled) {
          PodLocationService.instance.releaseAfterCapture();
        }
        _processingWatchdog?.cancel();
        _processingScan = false;
        _scannerState = _ScannerState.paused;
      }
    });
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

    final barcode = active.barcode;
    final entryId = active.entryId!; // ✅ Non-null assertion

    _lockNavigation();
    _scannerState = _ScannerState.navigating;
    _scanning = false;

    try {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoScanScreen(
            barcode: barcode,
            entryId: entryId,
            batchMode: false,
          ),
        ),
      );

      final entry = await _storage.getEntry(entryId);
      final photoCount = entry?.imagePath?.split(',').length ?? 0;
      final videoCount = entry?.videoPath != null ? 1 : 0;

      if (mounted) {
        _activeScanVN.value = _ActiveScan(
          barcode: barcode,
          entryId: entryId,
          photoCount: photoCount,
          videoCount: videoCount,
        );
        _activePhotoCountRestorer.value = photoCount;
        _activeVideoCountRestorer.value = videoCount;
        debugPrint('📊 Media counts from DB - Photos: $photoCount, Videos: $videoCount');
      }
    } catch (e) {
      debugPrint('❌ Error navigasi ke foto scan: $e');
    } finally {
      _unlockNavigation();
      if (mounted) {
        _scannerState = _ScannerState.paused;
        await _resumeScanning();
      }
    }
  }

  Future<void> _goToVideoScan() async {
    final active = _activeScanVN.value;
    if (active == null || active.entryId == null) return;

    final barcode = active.barcode;
    final entryId = active.entryId!; // ✅ Non-null assertion

    _lockNavigation();
    _scannerState = _ScannerState.navigating;
    _scanning = false;

    try {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoScanScreen(
            barcode: barcode,
            entryId: entryId,
          ),
        ),
      );

      final entry = await _storage.getEntry(entryId);
      final photoCount = entry?.imagePath?.split(',').length ?? 0;
      final videoCount = entry?.videoPath != null ? 1 : 0;

      if (mounted) {
        _activeScanVN.value = _ActiveScan(
          barcode: barcode,
          entryId: entryId,
          photoCount: photoCount,
          videoCount: videoCount,
        );
        _activePhotoCountRestorer.value = photoCount;
        _activeVideoCountRestorer.value = videoCount;
        debugPrint('📊 Media counts from DB - Photos: $photoCount, Videos: $videoCount');
      }
    } catch (e) {
      debugPrint('❌ Error navigasi ke video scan: $e');
    } finally {
      _unlockNavigation();
      if (mounted) {
        _scannerState = _ScannerState.paused;
        await _resumeScanning();
      }
    }
  }

  // ─── WATERMARK SETTINGS ──────────────────────────────────

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
      debugPrint('❌ Error membuka pengaturan watermark: $e');
      _unlockNavigation();
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
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  // ─── TOMBOL CLOSE ─────────────────────────────
                  if (active != null)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () {
                          _activeScanVN.value = null;
                          _activeBarcodeRestorer.value = '';
                          _activeEntryIdRestorer.value = '';
                          _activePhotoCountRestorer.value = 0;
                          _activeVideoCountRestorer.value = 0;
                          _resumeScanning();
                        },
                        tooltip: 'Tutup',
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
  final Future<void> Function(String code) onSubmitted;
  
  const _ManualInputDialog({
    required this.onSubmitted,
    super.key,
  });

  @override
  State<_ManualInputDialog> createState() => _ManualInputDialogState();
}

class _ManualInputDialogState extends State<_ManualInputDialog> {
  static const int _minCodeLength = 4;

  late TextEditingController _controller;
  String? _errorText;
  bool _isSubmitting = false;

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
                onPressed: _isSubmitting ? null : () => setState(() {
                  _controller.clear();
                  _errorText = null;
                }),
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
              icon: _isSubmitting
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
