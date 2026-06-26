// ============================================================
// lib/screens/barcode_scan_screen.dart (DENGAN BATCH MODE)
// ============================================================
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/location_service.dart';
import '../services/permission_service.dart';
import '../config/app_config.dart';
import '../watermark/watermark_renderer.dart';
import '../watermark/watermark_settings.dart';
import '../utils/image_compressor.dart';
import '../utils/file_helper.dart';
import 'watermark_settings_sheet.dart';
import 'photo_scan_screen.dart';

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  bool _scanning = true;
  bool _isSaving = false;
  String? _lastCode;
  DateTime? _lastScanTime;
  int _scanCount = 0;
  bool _settingsLoaded = false;
  bool _processingScan = false;
  bool _sheetOpen = false;
  bool _resumeScheduled = false;
  bool _isTakingMultiple = false;

  // BATCH MODE STATE
  String? _activeBarcode;
  int _batchPhotoCount = 0;
  bool _batchMode = true; // default true, bisa di-toggle

  final StorageService _storage = StorageService();
  final LocationService _loc = LocationService();
  final ImagePicker _picker = ImagePicker();
  final WatermarkSettings _wmSettings = WatermarkSettings();
  final MobileScannerController _scannerController = MobileScannerController();

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initializeSettings();
  }

  @override
  void dispose() {
    _scannerController.stop();
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _initializeSettings() async {
    await _wmSettings.load();
    if (mounted) {
      setState(() {
        _settingsLoaded = true;
      });
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.camera.request();
    await PermissionService.requestGalleryPermission();
  }

  Future<void> _resumeScanning() async {
    if (_resumeScheduled || _processingScan || _isSaving || _isTakingMultiple) return;
    _resumeScheduled = true;
    await _scannerController.start();
    if (mounted) {
      setState(() {
        _scanning = true;
        _lastCode = null;
      });
    }
    _resumeScheduled = false;
  }

  void _openWatermarkSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const WatermarkSettingsSheet(),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!_scanning || _isSaving || _processingScan || _isTakingMultiple) return;

    _processingScan = true;

    final barcode = capture.barcodes.isNotEmpty ? capture.barcodes.first : null;
    if (barcode == null || barcode.rawValue == null) {
      _processingScan = false;
      return;
    }

    final code = barcode.rawValue!;
    final format = barcode.format.name;

    if (_lastCode == code &&
        _lastScanTime != null &&
        DateTime.now().difference(_lastScanTime!).inSeconds < 2) {
      _processingScan = false;
      return;
    }
    _lastScanTime = DateTime.now();

    if (code == _lastCode) {
      _processingScan = false;
      return;
    }

    setState(() {
      _scanning = false;
      _lastCode = code;
      _activeBarcode = code;
    });

    try {
      HapticFeedback.mediumImpact();

      // Simpan barcode sebagai entri terpisah (tanpa foto)
      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.barcode,
        value: code,
        barcodeFormat: format,
        timestamp: DateTime.now(),
        latitude: null,
        longitude: null,
        locationName: null,
        
      );
      await _storage.add(entry);

      if (!mounted) return;
      setState(() => _scanCount++);

      // Hentikan scanner
      await _scannerController.stop();

      // Buka PhotoScanScreen dengan mode batch
      if (mounted) {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PhotoScanScreen(
              barcode: code,
              batchMode: _batchMode,
              entryId: entry.id,
            ),
          ),
        );
        // Jika kembali dari PhotoScanScreen, refresh count
        if (result != null) {
          _batchPhotoCount = result['count'] ?? 0;
        }
        _activeBarcode = null;
        _resumeScanning();
      }
    } catch (e) {
      debugPrint('Error _onDetect: $e');
      if (mounted) _resumeScanning();
    } finally {
      _processingScan = false;
      if (mounted && !_scanning && !_isSaving && !_sheetOpen && !_resumeScheduled && !_isTakingMultiple) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _resumeScanning();
        });
      }
    }
  }

  // ─── MANUAL INPUT ──────────────────────────────────────────
  void _showManualInput() {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
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
                Icon(Icons.keyboard, color: Colors.amber, size: 20),
                Gap(8),
                Text('Input Manual',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    )),
              ],
            ),
            const Gap(4),
            const Text(
              'Ketik atau paste barcode jika kamera gagal membaca',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const Gap(16),
            TextField(
              controller: controller,
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
                  borderSide: const BorderSide(color: Colors.amber, width: 1.5),
                ),
                prefixIcon: const Icon(Icons.qr_code, color: Colors.grey),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear, color: Colors.grey, size: 18),
                  onPressed: () => controller.clear(),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14,
                ),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (val) {
                if (val.trim().isNotEmpty) {
                  Navigator.pop(ctx);
                  _processManualCode(val.trim());
                }
              },
            ),
            const Gap(16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  final val = controller.text.trim();
                  if (val.isNotEmpty) {
                    Navigator.pop(ctx);
                    _processManualCode(val);
                  }
                },
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Konfirmasi',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _processManualCode(String code) async {
    if (_isSaving || _isTakingMultiple) return;

    setState(() {
      _scanning = false;
      _lastCode = code;
      _activeBarcode = code;
    });

    try {
      HapticFeedback.mediumImpact();

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.barcode,
        value: code,
        barcodeFormat: 'MANUAL',
        timestamp: DateTime.now(),
        latitude: null,
        longitude: null,
        locationName: null,
        photoPaths: null,
      );
      await _storage.add(entry);

      if (!mounted) return;
      setState(() => _scanCount++);

      if (mounted) {
        await _scannerController.stop();
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PhotoScanScreen(
              barcode: code,
              batchMode: _batchMode,
              entryId: entry.id,
            ),
          ),
        );
        if (result != null) {
          _batchPhotoCount = result['count'] ?? 0;
        }
        _activeBarcode = null;
        _resumeScanning();
      }
    } catch (e) {
      debugPrint('Error _processManualCode: $e');
      if (mounted) _resumeScanning();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Scanner ($_scanCount)'),
        actions: [
          IconButton(
            onPressed: _openWatermarkSettings,
            icon: Stack(
              children: [
                const Icon(Icons.tune, color: Colors.white),
                if (_settingsLoaded &&
                    (_wmSettings.operatorName.isNotEmpty ||
                     _wmSettings.hasLogo))
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.amber,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            tooltip: 'Pengaturan Watermark',
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: _onDetect,
          ),
          // Indikator batch mode & barcode aktif
          if (_activeBarcode != null)
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.withOpacity(0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.qr_code, color: Colors.amber, size: 18),
                    const Gap(8),
                    Expanded(
                      child: Text(
                        '$_activeBarcode',
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
                        color: Colors.amber.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$_batchPhotoCount foto',
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_settingsLoaded &&
              _wmSettings.operatorName.isNotEmpty &&
              !_isSaving &&
              !_isTakingMultiple &&
              _activeBarcode == null)
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xAA000000),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.amber.withOpacity(0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person, color: Colors.amber, size: 12),
                      const Gap(5),
                      Text(
                        _wmSettings.operatorName,
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_wmSettings.hasLogo) ...[
                        const Gap(8),
                        const Icon(Icons.business, color: Colors.white54, size: 12),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          if (!_isSaving && !_isTakingMultiple && _activeBarcode == null)
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  // Tombol mode batch toggle
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _batchMode = !_batchMode;
                      });
                    },
                    icon: Icon(
                      _batchMode ? Icons.view_list : Icons.camera_alt,
                      color: Colors.white70,
                      size: 16,
                    ),
                    label: Text(
                      _batchMode ? 'Mode: Batch (1 scan → banyak foto)' : 'Mode: Single (1 scan → 1 foto)',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  const Gap(8),
                  TextButton.icon(
                    onPressed: _showManualInput,
                    icon: const Icon(Icons.keyboard, color: Colors.white70, size: 18),
                    label: const Text(
                      'Input Manual',
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
          if (_isSaving || _isTakingMultiple)
            const ColoredBox(
              color: Color(0x88000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    Gap(12),
                    Text('Memproses...',
                        style: TextStyle(color: Colors.white, fontSize: 16)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
