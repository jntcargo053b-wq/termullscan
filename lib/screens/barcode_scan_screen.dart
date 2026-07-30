// lib/screens/barcode_scan_screen.dart
// ============================================================================
// SCAN BARCODE → BUKA KAMERA FOTO/VIDEO
// ============================================================================
// Alur: deteksi barcode → STOP scanner segera → validasi lokal → cek
// duplikat (exact match by value, StorageService.getEntryByValue) →
// navigasi ke PhotoScanScreen/VideoScanScreen sesuai `mode` → tunggu hasil →
// RESUME scanner supaya operator bisa langsung scan paket berikutnya tanpa
// kembali ke Home dulu.
//
// ✅ THROTTLE/DEBOUNCE: `_busy` di-set SYNCHRONOUS di awal `_onDetect()`,
// sebelum await apa pun, jadi deteksi berikutnya (termasuk kode yang
// BERBEDA) langsung diabaikan selama satu kode masih diproses — bukan cuma
// dicek belakangan setelah beberapa await sudah jalan. Scanner juga benar-
// benar di-stop() (bukan cuma diabaikan lewat flag) selama validasi/cek
// duplikat/navigasi berjalan, supaya kamera tidak dipakai dua controller
// sekaligus begitu PhotoScanScreen/VideoScanScreen membuka kameranya sendiri.
//
// ✅ SETSTATE: layar ini TIDAK memakai setState() sama sekali — status
// "mendeteksi"/busy dikirim lewat ValueNotifier + ValueListenableBuilder
// sempit, jadi CameraPreview (MobileScanner) dan chrome UI di sekitarnya
// tidak ikut rebuild tiap kali status berubah.
// ============================================================================

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import 'photo_scan_screen.dart';
import 'video_scan_screen.dart';

enum ScanCaptureMode { photo, video }

class BarcodeScanScreen extends StatefulWidget {
  final ScanCaptureMode mode;
  const BarcodeScanScreen({super.key, required this.mode});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen>
    with WidgetsBindingObserver {
  final MobileScannerController _scannerController = MobileScannerController(
    formats: const [BarcodeFormat.qrCode, BarcodeFormat.code128, BarcodeFormat.ean13],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final StorageService _storage = StorageService();

  // ─── STATUS (ValueNotifier, bukan setState) ──────────────────
  final ValueNotifier<String?> _statusVN = ValueNotifier(null);
  final ValueNotifier<bool> _busyVN = ValueNotifier(false);

  // ─── GUARD REENTRANCY (throttle) ──────────────────────────────
  bool _busy = false;
  bool _resumeScheduled = false;
  int _savedCount = 0;

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
    _statusVN.dispose();
    _busyVN.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `_busy` berarti scanner memang sengaja sedang di-stop (lagi validasi/
    // navigasi) — jangan resume paksa dari sini, biar `_handleCode`/
    // `_showManualInput` yang mengatur resume-nya sendiri setelah selesai.
    if (state == AppLifecycleState.resumed && !_busy) {
      _resumeScanning();
    }
  }

  // ─── SCANNER CONTROL ──────────────────────────────────────────

  Future<void> _startScannerWithRetry() async {
    try {
      await _scannerController.start();
    } catch (e) {
      debugPrint('❌ Scanner start error: $e');
      if (!mounted) return;
      await Future.delayed(const Duration(seconds: 2));
      if (mounted && !_busy) _startScannerWithRetry();
    }
  }

  Future<void> _resumeScanning() async {
    if (_resumeScheduled || !mounted) return;
    _resumeScheduled = true;
    try {
      final cameraStatus = await Permission.camera.status;
      if (!cameraStatus.isGranted) return;
      await _scannerController.start();
    } catch (e) {
      debugPrint('❌ Resume start error: $e');
    } finally {
      _resumeScheduled = false;
    }
  }

  // ─── DETEKSI BARCODE ───────────────────────────────────────────

  void _onDetect(BarcodeCapture capture) {
    if (_busy) return; // throttle: abaikan selama satu kode masih diproses
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final code = barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;

    _busy = true; // ✅ set SYNCHRONOUS sebelum await apa pun
    unawaited(_handleCode(code));
  }

  Future<void> _handleCode(String code) async {
    _busyVN.value = true;
    _statusVN.value = '📷 Memproses $code...';

    // Stop scanner segera — mencegah decode frame sia-sia & rebutan
    // hardware kamera dengan layar foto/video yang akan dibuka.
    try {
      await _scannerController.stop();
    } catch (e) {
      debugPrint('⚠️ Gagal stop scanner: $e');
    }

    try {
      final trimmed = code.trim();
      if (trimmed.length < 4) {
        _showError('Kode tidak valid: terlalu pendek');
        return;
      }

      final existing = await _storage.getEntryByValue(trimmed);
      if (!mounted) return;

      String? entryId;
      if (existing != null) {
        final proceed = await _showDuplicateDialog(existing);
        if (!mounted || proceed != true) return;
        entryId = existing.id;
      }

      await _openCaptureScreen(code: trimmed, entryId: entryId);
    } catch (e) {
      debugPrint('❌ Gagal memproses barcode: $e');
      _showError('Gagal memproses barcode: $e');
    } finally {
      _busy = false;
      _busyVN.value = false;
      _statusVN.value = null;
      if (mounted) unawaited(_resumeScanning());
    }
  }

  Future<void> _openCaptureScreen({required String code, String? entryId}) async {
    if (widget.mode == ScanCaptureMode.photo) {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoScanScreen(barcode: code, entryId: entryId),
        ),
      );
      if (!mounted) return;
      if (result is Map && result['error'] != null) {
        _showError('Gagal menyimpan foto: ${result['error']}');
        return;
      }
      final count = result is Map ? (result['count'] as int? ?? 0) : 0;
      if (count > 0) {
        _savedCount += count;
        _showSuccess(code);
      }
    } else {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoScanScreen(barcode: code, entryId: entryId),
        ),
      );
      if (!mounted) return;
      if (result is Map && result['path'] != null) {
        _savedCount++;
        _showSuccess(code);
      }
    }
  }

  // ─── MANUAL INPUT ─────────────────────────────────────────────

  Future<void> _showManualInput() async {
    if (_busy) return;
    _busy = true;
    _busyVN.value = true;
    try {
      await _scannerController.stop();
    } catch (_) {}

    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _ManualInputSheet(),
    );

    if (!mounted) return;

    if (code == null || code.isEmpty) {
      _busy = false;
      _busyVN.value = false;
      unawaited(_resumeScanning());
      return;
    }

    // `_handleCode` sendiri yang men-toggle `_busy` kembali ke false di
    // blok `finally`-nya begitu selesai (termasuk resume scanner).
    await _handleCode(code);
  }

  // ─── DIALOG & FEEDBACK ──────────────────────────────────────────

  Future<bool?> _showDuplicateDialog(ScanEntry existing) {
    final mediaLabel = widget.mode == ScanCaptureMode.photo ? 'foto' : 'video';
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Kode Sudah Ada'),
        content: Text(
          'Barcode "${existing.value}" sudah tercatat pada '
          '${existing.formattedTimestamp}.\n\n'
          'Tambahkan $mediaLabel baru ke entry yang sama?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Lanjutkan'),
          ),
        ],
      ),
    );
  }

  void _showSuccess(String code) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✅ Berhasil: $code'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

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

  // ─── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithDidPop: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _savedCount > 0 ? {'count': _savedCount} : null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.mode == ScanCaptureMode.photo ? 'Scan Foto' : 'Scan Video'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(
              context,
              _savedCount > 0 ? {'count': _savedCount} : null,
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.flash_on),
              onPressed: () => _scannerController.toggleTorch(),
            ),
          ],
        ),
        body: Stack(
          children: [
            MobileScanner(controller: _scannerController, onDetect: _onDetect),
            ValueListenableBuilder<String?>(
              valueListenable: _statusVN,
              builder: (_, status, __) {
                if (status == null) return const SizedBox.shrink();
                return Positioned(
                  top: 100,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: Colors.black54,
                    child: Text(
                      status,
                      style: const TextStyle(color: Colors.white),
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
                child: ValueListenableBuilder<bool>(
                  valueListenable: _busyVN,
                  builder: (_, busy, __) => FloatingActionButton.extended(
                    onPressed: busy ? null : _showManualInput,
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.edit),
                    label: Text(busy ? 'Memproses...' : 'Input Manual'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// BOTTOM SHEET INPUT MANUAL
// ============================================================================

class _ManualInputSheet extends StatefulWidget {
  const _ManualInputSheet();

  @override
  State<_ManualInputSheet> createState() => _ManualInputSheetState();
}

class _ManualInputSheetState extends State<_ManualInputSheet> {
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

  void _submit() {
    final code = _controller.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kode tidak boleh kosong'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    Navigator.pop(context, code);
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
            onSubmitted: (_) => _submit(),
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
}
