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
import 'watermark_settings_sheet.dart';

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  bool _scanning = true;
  bool _isSaving = false;
  String? _lastCode;
  DateTime? _lastScanTime; // ✅ Bug C - untuk deteksi duplikat
  int _scanCount = 0;
  bool _settingsLoaded = false;
  bool _processingScan = false;
  bool _sheetOpen = false;

  final StorageService _storage = StorageService();
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
    await _scannerController.start();
    if (mounted) {
      setState(() {
        _scanning = true;
        _lastCode = null;
      });
    }
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
    if (!_scanning || _isSaving || _processingScan) return;

    _processingScan = true;

    final barcode = capture.barcodes.isNotEmpty ? capture.barcodes.first : null;
    if (barcode == null || barcode.rawValue == null) {
      _processingScan = false;
      return;
    }

    final code = barcode.rawValue!;
    final format = barcode.format.name;

    // ✅ Bug C - Cegah duplikat beruntun
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
    });

    try {
      HapticFeedback.mediumImpact();

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

      // ✅ Bug A - Cek mounted sebelum setState
      if (!mounted) return;
      setState(() {
        _scanCount++;
      });

      if (mounted) {
        await _scannerController.stop();
        try {
          await _takePhotoAndShow(entry);
        } catch (e) {
          debugPrint('Error _takePhotoAndShow: $e');
          if (mounted) _resumeScanning();
        }
      }
    } catch (e) {
      debugPrint('Error _onDetect: $e');
      if (mounted) _resumeScanning();
    } finally {
      _processingScan = false;

      // ✅ Bug B - Recovery scanner jika terkunci
      if (mounted && !_scanning && !_isSaving && !_sheetOpen) {
        Future.delayed(
          const Duration(milliseconds: 300),
          () {
            if (mounted) {
              _resumeScanning();
            }
          },
        );
      }
    }
  }

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
                width: 40, height: 4,
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
    if (_isSaving) return;

    setState(() {
      _scanning = false;
      _lastCode = code;
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
      );
      await _storage.add(entry);

      if (!mounted) return;
      setState(() => _scanCount++);

      if (mounted) {
        await _scannerController.stop();
        try {
          await _takePhotoAndShow(entry);
        } catch (e) {
          debugPrint('Error _takePhotoAndShow: $e');
          if (mounted) _resumeScanning();
        }
      }
    } catch (e) {
      debugPrint('Error _processManualCode: $e');
      if (mounted) _resumeScanning();
    }
  }

  Future<void> _takePhotoAndShow(ScanEntry entry) async {
    if (_sheetOpen) {
      debugPrint('⚠️ Bottom sheet already open, skipping');
      return;
    }
    _sheetOpen = true;

    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        imageQuality: 65,
      );
    } catch (e) {
      debugPrint('Error opening camera: $e');
      _sheetOpen = false;
      if (mounted) _resumeScanning();
      return;
    }

    if (file == null) {
      _sheetOpen = false;
      if (mounted) _resumeScanning();
      return;
    }

    if (mounted) setState(() => _isSaving = true);

    try {
      final updatedEntry = entry.copyWith(
        latitude: null,
        longitude: null,
        locationName: null,
      );
      await _storage.update(updatedEntry);

      final stateNotifier = ValueNotifier<_ResultState>(
        _ResultState(entry: updatedEntry, photoPath: null, processing: true),
      );

      showModalBottomSheet(
        context: context,
        isDismissible: true,
        isScrollControlled: true,
        builder: (_) => _ResultSheet(
          notifier: stateNotifier,
          storage: _storage,
          onSaveToGallery: _saveToGallery,
        ),
      ).whenComplete(() {
        stateNotifier.dispose();
        _sheetOpen = false;
        if (mounted) _resumeScanning();
      });

      String wmPath;
      try {
        wmPath = await _addWatermarkInIsolate(file.path, updatedEntry);
      } catch (e) {
        debugPrint('Watermark error: $e');
        wmPath = file.path;
      }

      final savedPhotoPath = await _storage.savePhoto(wmPath, name: entry.value);

      final photoEntry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: savedPhotoPath,
        timestamp: DateTime.now(),
        latitude: null,
        longitude: null,
        locationName: null,
      );
      await _storage.add(photoEntry);

      stateNotifier.value = _ResultState(
        entry: updatedEntry,
        photoPath: savedPhotoPath,
        processing: false,
      );
    } catch (e) {
      debugPrint('Error in _takePhotoAndShow: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red,
            content: Text('Gagal memproses: $e'),
          ),
        );
        _resumeScanning();
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<String> _addWatermarkInIsolate(String imagePath, ScanEntry entry) async {
    final outputPath =
        '${File(imagePath).parent.path}/wm_${DateTime.now().millisecondsSinceEpoch}.png';

    final result = await WatermarkRenderer.render(
      imagePath: imagePath,
      outputPath: outputPath,
      settings: _wmSettings,
      entry: entry,
    );

    if (result == null) throw Exception('Watermark isolate gagal');

    if (result != imagePath) {
      final file = File(imagePath);
      try {
        final parentPath = file.parent.path.toLowerCase();
        if (parentPath.contains('cache') ||
            parentPath.contains('tmp') ||
            parentPath.contains('.cache')) {
          await file.delete();
          debugPrint('✅ Cache file deleted: $imagePath');
        } else {
          debugPrint('⏭️ Skipped deleting non-cache file: $imagePath');
        }
      } catch (e) {
        debugPrint('⚠️ Error deleting file: $e');
      }
    }

    return result;
  }

  Future<bool> _saveToGallery(String filePath, ScanEntry entry) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('❌ File not found: $filePath');
        return false;
      }

      final granted = await PermissionService.requestGalleryPermission();
      if (!granted) {
        debugPrint('❌ Gallery permission denied');
        return false;
      }

      final filename = 'scan_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final result = await SaverGallery.saveFile(
        file: filePath,
        name: filename,
        androidRelativePath: 'Pictures/TERMULScan',
        androidExistNotSave: false,
      );

      await Future.delayed(const Duration(milliseconds: 500));
      return result.isSuccess;
    } catch (e) {
      debugPrint('❌ Error _saveToGallery: $e');
      return false;
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
                    right: 0, top: 0,
                    child: Container(
                      width: 8, height: 8,
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
          if (_settingsLoaded &&
              _wmSettings.operatorName.isNotEmpty &&
              !_isSaving)
            Positioned(
              top: 12,
              left: 0, right: 0,
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
          if (!_isSaving)
            Positioned(
              bottom: 40,
              left: 0, right: 0,
              child: Center(
                child: TextButton.icon(
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
              ),
            ),
          if (_isSaving)
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

// ── Result State ──────────────────────────────────────────────────────────
class _ResultState {
  final ScanEntry entry;
  final String? photoPath;
  final bool processing;
  final bool error;
  const _ResultState({
    required this.entry,
    required this.photoPath,
    required this.processing,
    this.error = false,
  });
}

// ── Result Sheet ──────────────────────────────────────────────────────────
class _ResultSheet extends StatefulWidget {
  final ValueNotifier<_ResultState> notifier;
  final StorageService storage;
  final Future<bool> Function(String, ScanEntry) onSaveToGallery;
  const _ResultSheet({
    required this.notifier,
    required this.storage,
    required this.onSaveToGallery,
  });

  @override
  State<_ResultSheet> createState() => _ResultSheetState();
}

class _ResultSheetState extends State<_ResultSheet> {
  final TextEditingController _noteController = TextEditingController();
  bool _isSaved = false;
  bool _isSaving = false;
  bool _isEditingNote = false;
  bool _noteSaved = false;

  bool get _isManual => widget.notifier.value.entry.barcodeFormat == 'MANUAL';

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_ResultState>(
      valueListenable: widget.notifier,
      builder: (context, state, _) {
        final entry = state.entry;
        final photoPath = state.photoPath;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20, 16, 20,
            MediaQuery.of(context).viewInsets.bottom + 32,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (_isManual)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.amber.withOpacity(0.4)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.keyboard, color: Colors.amber, size: 13),
                      Gap(5),
                      Text('Input Manual',
                          style: TextStyle(
                            color: Colors.amber,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          )),
                    ],
                  ),
                ),
              if (photoPath != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(photoPath),
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                )
              else if (state.processing)
                Container(
                  height: 200,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 24, height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        Gap(8),
                        Text('Memproses foto & ...',
                            style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                )
              else if (state.error)
                Container(
                  height: 80,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(
                    child: Text('Gagal memproses foto',
                        style: TextStyle(color: Colors.red, fontSize: 12)),
                  ),
                ),
              const Gap(12),
              Text(
                entry.value,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const Gap(4),
              Text(
                DateFormat('dd/MM/yyyy HH:mm:ss').format(entry.timestamp),
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const Gap(4),
              Text(
                'GPS dinonaktifkan',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const Gap(12),
              if (!_isEditingNote && !_noteSaved)
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _isEditingNote = true),
                    icon: const Icon(Icons.note_add_outlined, size: 18),
                    label: const Text('Tambah Catatan'),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: Colors.grey,
                    ),
                  ),
                ),
              if (_isEditingNote)
                Column(
                  children: [
                    TextField(
                      controller: _noteController,
                      autofocus: true,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: 'Tulis catatan...',
                        isDense: true,
                        contentPadding: const EdgeInsets.all(10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const Gap(8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => setState(() {
                              _isEditingNote = false;
                              _noteController.clear();
                            }),
                            child: const Text('Batal'),
                          ),
                        ),
                        const Gap(8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final note = _noteController.text.trim();
                              if (note.isNotEmpty) {
                                final updated = entry.copyWith(note: note);
                                await widget.storage.update(updated);
                                widget.notifier.value = _ResultState(
                                  entry: updated,
                                  photoPath: state.photoPath,
                                  processing: state.processing,
                                  error: state.error,
                                );
                              }
                              setState(() {
                                _isEditingNote = false;
                                _noteSaved = note.isNotEmpty;
                              });
                            },
                            child: const Text('Simpan Catatan'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              if (_noteSaved)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green, size: 16),
                      const Gap(8),
                      Expanded(
                        child: Text(
                          _noteController.text,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() {
                          _noteSaved = false;
                          _isEditingNote = true;
                        }),
                        child: const Icon(Icons.edit, size: 16, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              const Gap(12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: (_isSaved || _isSaving || photoPath == null)
                          ? null
                          : () async {
                              setState(() => _isSaving = true);
                              final success = await widget.onSaveToGallery(photoPath!, entry);
                              setState(() {
                                _isSaving = false;
                                _isSaved = success;
                              });
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(success
                                        ? '✓ Foto tersimpan ke galeri'
                                        : 'Gagal menyimpan — cek permission'),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              }
                            },
                      icon: _isSaving
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(_isSaved ? Icons.check : Icons.save_alt),
                      label: Text(_isSaving
                          ? 'Menyimpan...'
                          : _isSaved ? 'Tersimpan' : 'Simpan'),
                    ),
                  ),
                  const Gap(10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan Lagi'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
