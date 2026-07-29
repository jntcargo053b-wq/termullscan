// lib/screens/barcode_scan_screen.dart
// ============================================================================
// VERSI FINAL – SIAP PAKAI (tanpa error analyzer)
// ============================================================================

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

// ============================================================================
// TOKEN PEMBATALAN
// ============================================================================

class _CancelToken {
  final Completer<void> _completer = Completer<void>();
  bool get isCompleted => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

// ============================================================================
// STATE WIDGET
// ============================================================================

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen>
    with WidgetsBindingObserver {
  // ─── SCANNER CONTROLLER ──────────────────────────────────────
  final MobileScannerController _scannerController = MobileScannerController(
    formats: [BarcodeFormat.qrCode, BarcodeFormat.code128, BarcodeFormat.ean13],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  // ─── STATE VARIABLES ──────────────────────────────────────────
  bool _isProcessingLocked = false;
  Completer<void>? _processingCompleter;
  _CancelToken? _cancelToken;

  bool _resumeScheduled = false;

  bool _manualFlowBusy = false;
  int _processingCount = 0;
  bool _isNavigating = false;

  final ValueNotifier<BarcodeCapture?> _activeScanVN = ValueNotifier(null);

  // ─── LIFECYCLE ────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startScannerWithRetry();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scannerController.dispose();
    _activeScanVN.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumeScanning();
    }
  }

  // ─── SCANNER CONTROL ──────────────────────────────────────────

  Future<void> _startScannerWithRetry() async {
    try {
      await _scannerController.start();
      debugPrint('✅ Scanner started');
    } catch (e) {
      debugPrint('❌ Scanner start error: $e');
      Future.delayed(const Duration(seconds: 2), _startScannerWithRetry);
    }
  }

  // ─── RESUME SCANNING (RACE CONDITION FIX) ────────────────────

  Future<void> _resumeScanning() async {
    if (_resumeScheduled) {
      debugPrint('⚠️ Resume already scheduled, skipping');
      return;
    }

    _resumeScheduled = true;

    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      debugPrint('⚠️ Resume skipped: camera permission not granted');
      _resumeScheduled = false;
      return;
    }

    try {
      await _scannerController.start();
      debugPrint('✅ Scanner resumed');
    } catch (e) {
      debugPrint('❌ Resume start error: $e');
      Future.delayed(const Duration(seconds: 1), _startScannerWithRetry);
    } finally {
      _resumeScheduled = false;
    }
  }

  // ─── PROCESSING LOCK ──────────────────────────────────────────

  Future<void> _executeWithProcessingLock(
    Future<void> Function(_CancelToken token) action,
  ) async {
    if (_isProcessingLocked) {
      debugPrint('⏳ Menunggu lock...');
      final waitingOn = _processingCompleter;
      if (waitingOn != null) {
        try {
          await waitingOn.future.timeout(const Duration(seconds: 60));
        } on TimeoutException catch (_) {
          debugPrint('🚨 Force unlock setelah 60s (deadlock terdeteksi)');
          _cancelToken?.cancel();
          _isProcessingLocked = false;
          _processingCompleter = null;
          _cancelToken = null;
        }
      }

      if (_isProcessingLocked) {
        debugPrint('⚠️ Lock diambil alih, aksi dibatalkan');
        return;
      }
    }

    final token = _CancelToken();
    _cancelToken = token;
    _isProcessingLocked = true;
    _processingCompleter = Completer<void>();

    debugPrint('🔒 Lock acquired');

    try {
      await action(token).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('⏰ Timeout 30s, kirim sinyal batal...');
          token.cancel();
          return Future.delayed(const Duration(milliseconds: 200));
        },
      );
      debugPrint('✅ Processing selesai');
    } finally {
      _isProcessingLocked = false;
      _processingCompleter?.complete();
      _processingCompleter = null;
      _cancelToken = null;
      debugPrint('🔓 Lock released');
    }
  }

  // ─── PROSES BARCODE ──────────────────────────────────────────

  void _processBarcode(String code) {
    if (_isNavigating || _manualFlowBusy) {
      debugPrint('⏭️ Skip scan: busy');
      return;
    }

    _executeWithProcessingLock((token) async {
      _processingCount++;
      try {
        final valid = await _validateBarcodeLocally(code);
        if (token.isCompleted) return;

        if (!valid) {
          _showError('Kode tidak valid');
          return;
        }

        final existing = await _checkExistingEntry(code);
        if (token.isCompleted) return;

        if (existing != null) {
          _showDuplicateDialog(existing);
          return;
        }

        final entry = await _saveEntryToFirebase(code);
        if (token.isCompleted) {
          debugPrint('⛔ Hasil Firebase diabaikan (cancelled)');
          return;
        }

        await _updateUIAfterSave(entry);
      } finally {
        _processingCount--;
      }
    }).catchError((e) {
      _showError('Gagal memproses barcode: $e');
    });
  }

  // ─── MANUAL INPUT ─────────────────────────────────────────────

  void _showManualInput() {
    if (_manualFlowBusy) return;
    _manualFlowBusy = true;
    _lockNavigation();

    bool submitted = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ManualInputDialog(
        onSubmitted: (code) {
          submitted = true;
          _confirmAndProcessManualCode(code);
        },
      ),
    ).whenComplete(() {
      _unlockNavigation();
      if (!submitted) {
        _manualFlowBusy = false;
        debugPrint('🔄 Manual input dismissed without submit');
        if (_processingCount == 0 && mounted) {
          _resumeScanning();
        }
      }
    });
  }

  Future<void> _confirmAndProcessManualCode(String code) async {
    try {
      await _executeWithProcessingLock((token) async {
        _processingCount++;
        try {
          final valid = await _validateBarcodeLocally(code);
          if (token.isCompleted) return;
          if (!valid) {
            _showError('Kode tidak valid');
            return;
          }

          final existing = await _checkExistingEntry(code);
          if (token.isCompleted) return;
          if (existing != null) {
            _showDuplicateDialog(existing);
            return;
          }

          final entry = await _saveEntryFromManual(code);
          if (token.isCompleted) return;
          await _updateUIAfterSave(entry);
        } finally {
          _processingCount--;
        }
      });
    } catch (e) {
      _showError('Gagal menyimpan manual: $e');
    } finally {
      _manualFlowBusy = false;
      if (_processingCount == 0 && mounted) {
        _resumeScanning();
      }
    }
  }

  // ─── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Barcode'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _scannerController.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: (capture) {
              final barcodes = capture.barcodes;
              if (barcodes.isNotEmpty) {
                final code = barcodes.first.rawValue;
                if (code != null && code.isNotEmpty) {
                  _activeScanVN.value = capture;
                  _processBarcode(code);
                }
              }
            },
          ),
          ValueListenableBuilder<BarcodeCapture?>(
            valueListenable: _activeScanVN,
            builder: (_, capture, __) {
              if (capture == null) return const SizedBox.shrink();
              return Positioned(
                top: 100,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: Colors.black54,
                  child: const Text(
                    '📷 Mendeteksi...',
                    style: TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            },
          ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton.extended(
                onPressed: _manualFlowBusy ? null : _showManualInput,
                icon: const Icon(Icons.edit),
                label: const Text('Input Manual'),
              ),
            ),
          ),
          if (_processingCount > 0)
            const Positioned(
              bottom: 120,
              left: 0,
              right: 0,
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }

  // ─── HELPERS ──────────────────────────────────────────────────

  void _lockNavigation() => _isNavigating = true;
  void _unlockNavigation() => _isNavigating = false;

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showDuplicateDialog(dynamic existing) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Kode sudah ada'),
        content: Text('Entry dengan kode ini sudah tersimpan.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // PLACEHOLDER – GANTI DENGAN IMPLEMENTASI NYATA
  // ==========================================================================

  Future<bool> _validateBarcodeLocally(String code) async {
    return code.isNotEmpty && code.length >= 4;
  }

  Future<dynamic> _checkExistingEntry(String code) async {
    return null;
  }

  Future<dynamic> _saveEntryToFirebase(String code) async {
    await Future.delayed(const Duration(seconds: 2));
    return {'id': 'fire_$code', 'code': code, 'timestamp': DateTime.now()};
  }

  Future<dynamic> _saveEntryFromManual(String code) async {
    await Future.delayed(const Duration(seconds: 1));
    return {'id': 'manual_$code', 'code': code, 'timestamp': DateTime.now()};
  }

  Future<void> _updateUIAfterSave(dynamic entry) async {
    debugPrint('✅ Entry tersimpan: $entry');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ Berhasil: ${entry['code']}')),
    );
  }
}

// ============================================================================
// DIALOG INPUT MANUAL
// ============================================================================

class _ManualInputDialog extends StatefulWidget {
  final void Function(String code) onSubmitted;
  const _ManualInputDialog({required this.onSubmitted});

  @override
  State<_ManualInputDialog> createState() => _ManualInputDialogState();
}

class _ManualInputDialogState extends State<_ManualInputDialog> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        top: 20,
        left: 20,
        right: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Masukkan Kode Manual',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Contoh: 1234567890',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.qr_code),
            ),
            onSubmitted: (value) => _submit(),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Batal'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _submit,
                child: const Text('Submit'),
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.isNotEmpty) {
      widget.onSubmitted(code);
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kode tidak boleh kosong'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }
}
