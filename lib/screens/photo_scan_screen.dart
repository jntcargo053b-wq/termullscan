// ============================================================
// lib/screens/photo_scan_screen.dart (FINAL)
// ============================================================
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/permission_service.dart';
import '../config/app_config.dart';
import '../theme/app_theme.dart';
import '../watermark/watermark_renderer.dart';
import '../watermark/watermark_settings.dart';
import '../utils/image_compressor.dart';
import '../utils/file_helper.dart';
import 'watermark_settings_sheet.dart';

// ─── WIDGET: Camera Icon ──────────────────────────────────────
class _CameraIconWidget extends StatelessWidget {
  final bool batchMode;
  final int photoCount;

  const _CameraIconWidget({
    required this.batchMode,
    required this.photoCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        color: AppTheme.accentOrange.withOpacity(0.1),
        shape: BoxShape.circle,
        border: Border.all(
          color: AppTheme.accentOrange.withOpacity(0.4),
          width: 2,
        ),
      ),
      child: batchMode
          ? Stack(
              alignment: Alignment.center,
              children: [
                const Icon(Icons.camera_alt,
                    size: 52, color: AppTheme.accentOrange),
                if (photoCount > 0)
                  Positioned(
                    bottom: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: AppTheme.accentOrange,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '$photoCount',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            )
          : const Icon(Icons.camera_alt,
              size: 52, color: AppTheme.accentOrange),
    ).animate().scale(duration: 400.ms, curve: Curves.elasticOut);
  }
}

// ─── WIDGET: Header ───────────────────────────────────────────
class _HeaderWidget extends StatelessWidget {
  final bool batchMode;
  final int photoCount;
  final String? barcode;

  const _HeaderWidget({
    required this.batchMode,
    required this.photoCount,
    this.barcode,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          batchMode ? 'Ambil Foto Batch' : 'Siap Ambil Foto',
          style: Theme.of(context).textTheme.titleLarge,
        ).animate().fadeIn(delay: 100.ms),
        const Gap(8),
        Text(
          batchMode
              ? '$photoCount foto diambil untuk ${barcode ?? 'tanpa barcode'}'
              : 'Foto otomatis disertai timestamp & watermark',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ).animate().fadeIn(delay: 200.ms),
      ],
    );
  }
}

// ─── WIDGET: Photo Thumbnails ────────────────────────────────
class _PhotoThumbnailsWidget extends StatelessWidget {
  final List<String> photoPaths;

  const _PhotoThumbnailsWidget({required this.photoPaths});

  @override
  Widget build(BuildContext context) {
    if (photoPaths.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        const Gap(16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: photoPaths.map((path) {
              return Container(
                margin: const EdgeInsets.only(right: 8),
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  image: DecorationImage(
                    image: FileImage(File(path)),
                    fit: BoxFit.cover,
                  ),
                  border: Border.all(color: Colors.grey.shade700),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

// ─── WIDGET: Action Buttons ──────────────────────────────────
class _ActionButtonsWidget extends StatelessWidget {
  final VoidCallback onTakePhoto;
  final VoidCallback onPickGallery;
  final bool isSaving;
  final bool isCapturing;

  const _ActionButtonsWidget({
    required this.onTakePhoto,
    required this.onPickGallery,
    required this.isSaving,
    required this.isCapturing,
  });

  @override
  Widget build(BuildContext context) {
    final bool disabled = isSaving || isCapturing;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: disabled ? null : onTakePhoto,
            icon: disabled
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.black, strokeWidth: 2),
                  )
                : const Icon(Icons.camera_alt, size: 22),
            label: Text(disabled ? 'Menyimpan...' : 'Ambil Foto'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentOrange,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 18),
              textStyle: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
        ).animate().fadeIn(delay: 250.ms),
        const Gap(14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: disabled ? null : onPickGallery,
            icon: const Icon(Icons.photo_library_outlined, size: 20),
            label: const Text('Pilih dari Galeri'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.accentOrange,
              side: BorderSide(
                  color: AppTheme.accentOrange.withOpacity(0.6)),
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ).animate().fadeIn(delay: 300.ms),
      ],
    );
  }
}

// ─── WIDGET: Batch Finish Button ─────────────────────────────
class _BatchFinishButtonWidget extends StatelessWidget {
  final int photoCount;
  final VoidCallback onFinish;

  const _BatchFinishButtonWidget({
    required this.photoCount,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    if (photoCount == 0) return const SizedBox.shrink();
    return Column(
      children: [
        const Gap(16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: onFinish,
            icon: const Icon(Icons.done_all, size: 20),
            label: Text('Selesai Batch (${photoCount} foto)'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              textStyle: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
        ).animate().fadeIn(delay: 350.ms),
      ],
    );
  }
}

// ─── WIDGET: Info Box ─────────────────────────────────────────
class _InfoBoxWidget extends StatelessWidget {
  final bool batchMode;

  const _InfoBoxWidget({required this.batchMode});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              size: 16, color: AppTheme.accentBlue),
          const Gap(10),
          Expanded(
            child: Text(
              batchMode
                  ? 'Ambil banyak foto untuk satu barcode. Tekan "Selesai Batch" jika sudah.'
                  : 'Setiap foto otomatis dicatat: waktu & watermark',
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 350.ms);
  }
}

// ─── MAIN STATE ──────────────────────────────────────────────
class PhotoScanScreen extends StatefulWidget {
  final String? barcode;
  final bool batchMode;
  final String? entryId;

  const PhotoScanScreen({
    super.key,
    this.barcode,
    this.batchMode = false,
    this.entryId,
  });

  @override
  State<PhotoScanScreen> createState() => _PhotoScanScreenState();
}

class _PhotoScanScreenState extends State<PhotoScanScreen> {
  final ImagePicker _picker = ImagePicker();
  final StorageService _storage = StorageService();
  final WatermarkSettings _wmSettings = WatermarkSettings();

  bool _isSaving = false;
  bool _isCapturing = false;
  int _photoCount = 0;
  bool _cameraGranted = false;
  bool _settingsLoaded = false;

  List<String> _photoPaths = [];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initializeSettings();
  }

  @override
  void dispose() {
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
    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      final result = await Permission.camera.request();
      if (mounted) {
        setState(() => _cameraGranted = result.isGranted);
      }
      if (!result.isGranted && mounted) {
        _showError('Izin kamera diperlukan untuk mengambil foto');
      }
    } else {
      if (mounted) {
        setState(() => _cameraGranted = true);
      }
    }

    await PermissionService.requestGalleryPermission();
  }

  Future<bool> _ensureCameraPermission() async {
    if (_cameraGranted) return true;
    final status = await Permission.camera.status;
    if (status.isGranted) {
      if (mounted) {
        setState(() => _cameraGranted = true);
      }
      return true;
    }
    final result = await Permission.camera.request();
    final granted = result.isGranted;
    if (mounted) {
      setState(() => _cameraGranted = granted);
    }
    if (!granted) _showError('Izin kamera ditolak');
    return granted;
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

  // ─── Helper: Resolve file name ─────────────────────────────
  String _resolveFileName(int photoIndex) {
    if (widget.barcode == null) return 'photo_$photoIndex';
    return photoIndex == 1
        ? widget.barcode!
        : '${widget.barcode}${photoIndex.toString().padLeft(3, '0')}';
  }

  // ─── Apply watermark ────────────────────────────────────────
  Future<String> _applyWatermark(String imagePath, DateTime timestamp, int photoIndex) async {
    // Settings sudah di-load di init, tidak perlu load ulang
    final fileName = _resolveFileName(photoIndex);
    final outputPath =
        '${File(imagePath).parent.path}/wm_${DateTime.now().millisecondsSinceEpoch}.png';

    final tempEntry = ScanEntry(
      id: _storage.generateId(),
      type: ScanType.photo,
      value: fileName,
      barcodeFormat: null,
      timestamp: timestamp,
      latitude: null,
      longitude: null,
      locationName: null,
    );

    final result = await WatermarkRenderer.render(
      imagePath: imagePath,
      outputPath: outputPath,
      settings: _wmSettings,
      entry: tempEntry,
    );

    if (result != null && result != imagePath) {
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

    return result ?? imagePath;
  }

  Future<bool> _saveToGallery(String filePath, {ScanEntry? entry}) async {
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

      final String filename = file.path.split('/').last;

      final result = await SaverGallery.saveFile(
        file: filePath,
        name: filename,
        androidRelativePath: 'Pictures/TERMULScan',
        androidExistNotSave: false,
      );

      await Future.delayed(const Duration(milliseconds: 500));

      if (result.isSuccess) {
        debugPrint('✅ Foto tersimpan ke galeri: $filename');
        return true;
      } else {
        debugPrint('❌ Gagal simpan: ${result.errorMessage}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error _saveToGallery: $e');
      return false;
    }
  }

  // ─── TAKE PHOTO ──────────────────────────────────────────────
  Future<void> _takePhoto() async {
    if (_isSaving || _isCapturing) return;

    if (!await _ensureCameraPermission()) return;

    if (mounted) {
      setState(() {
        _isSaving = true;
        _isCapturing = true;
      });
    }

    final XFile? xfile;
    try {
      xfile = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: AppConfig.maxWidth,
        imageQuality: AppConfig.imageQuality,
        preferredCameraDevice: CameraDevice.rear,
      );
    } catch (e) {
      _showError('Gagal membuka kamera');
      if (mounted) {
        setState(() {
          _isSaving = false;
          _isCapturing = false;
        });
      }
      return;
    }

    if (!mounted) return;

    if (xfile == null) {
      setState(() {
        _isSaving = false;
        _isCapturing = false;
      });
      return;
    }

    await _processPhoto(xfile);
  }

  // ─── PICK FROM GALLERY ──────────────────────────────────────
  Future<void> _pickFromGallery() async {
    if (_isSaving || _isCapturing) return;

    if (mounted) {
      setState(() {
        _isSaving = true;
        _isCapturing = true;
      });
    }

    final XFile? xfile;
    try {
      xfile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: AppConfig.maxWidth,
        imageQuality: AppConfig.imageQuality,
      );
    } catch (e) {
      _showError('Gagal membuka galeri');
      if (mounted) {
        setState(() {
          _isSaving = false;
          _isCapturing = false;
        });
      }
      return;
    }

    if (!mounted) return;

    if (xfile == null) {
      setState(() {
        _isSaving = false;
        _isCapturing = false;
      });
      return;
    }

    await _processPhoto(xfile);
  }

  // ─── PROCESS PHOTO ──────────────────────────────────────────
  Future<void> _processPhoto(XFile xfile) async {
    String? watermarkedPath;
    String compressedPath = xfile.path;

    try {
      final fileSize = await File(xfile.path).length();
      if (fileSize > 20 * 1024 * 1024) {
        throw Exception('Ukuran foto terlalu besar (>20MB)');
      }

      compressedPath = await ImageCompressor.compressIfNeeded(xfile.path);

      final timestamp = DateTime.now();
      final photoIndex = _photoCount + 1;

      watermarkedPath = await _applyWatermark(compressedPath, timestamp, photoIndex);

      if (!await File(watermarkedPath).exists()) {
        throw Exception('File watermark tidak ditemukan');
      }

      final name = _resolveFileName(photoIndex);
      final savedPath = await _storage.savePhoto(watermarkedPath, name: name);
      if (savedPath.isEmpty) {
        throw Exception('Gagal menyimpan file foto');
      }

      // Mutasi dan setState digabung
      if (mounted) {
        setState(() {
          _photoPaths.add(savedPath);
          _photoCount++;
        });
      }

      if (widget.entryId != null) {
        final barcodeEntry = await _storage.getEntry(widget.entryId!);
        if (barcodeEntry != null) {
          final updated = barcodeEntry.copyWith(photoPaths: List.from(_photoPaths));
          await _storage.update(updated);
        }
      }

      await _saveToGallery(savedPath);

      if (!widget.batchMode) {
        _showSuccess();
        Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('📸 Foto ${_photoCount} berhasil (${widget.barcode ?? 'tanpa barcode'})'),
            duration: const Duration(seconds: 1),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('Error processing photo: $e\n$stack');
      _showError('Gagal memproses foto: ${e.toString().split(':').last}');
      if (watermarkedPath != null && watermarkedPath != compressedPath) {
        try { await File(watermarkedPath).delete(); } catch (_) {}
      }
    } finally {
      if (compressedPath != xfile.path &&
          await FileHelper.isTemporaryFile(compressedPath)) {
        try { await File(compressedPath).delete(); } catch (_) {}
      }
      if (await FileHelper.isTemporaryFile(xfile.path)) {
        try { await File(xfile.path).delete(); } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _isSaving = false;
          _isCapturing = false;
        });
      }
    }
  }

  // ─── FINISH BATCH ────────────────────────────────────────────
  Future<void> _finishBatch() async {
    if (widget.entryId != null && _photoPaths.isNotEmpty) {
      final barcodeEntry = await _storage.getEntry(widget.entryId!);
      if (barcodeEntry != null) {
        final updated = barcodeEntry.copyWith(photoPaths: List.from(_photoPaths));
        await _storage.update(updated);
      }
    }

    if (_photoPaths.isNotEmpty) {
      await _showBatchSummaryAndPop();
    } else {
      Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
    }
  }

  // ─── BATCH SUMMARY (Dialog lalu pop) ────────────────────────
  Future<void> _showBatchSummaryAndPop() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('✅ Selesai Batch (${widget.barcode ?? ''})'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total foto: $_photoCount'),
            const Gap(8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: _photoPaths.map((path) {
                return Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    image: DecorationImage(
                      image: FileImage(File(path)),
                      fit: BoxFit.cover,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    // Setelah dialog close, pop screen ini
    if (mounted) {
      Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
    }
  }

  void _showSuccess() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 2),
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 18),
            Gap(8),
            Expanded(
              child: Text(
                'Foto tersimpan',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppTheme.error,
        content: Text(msg),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ─── BUILD ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: widget.batchMode
            ? Text('Batch: ${widget.barcode ?? 'Foto'} (${_photoCount})')
            : const Text('Ambil Foto'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (widget.batchMode && _photoCount > 0) {
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Keluar Batch?'),
                  content: Text('${_photoCount} foto sudah diambil. Yakin keluar?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Lanjutkan'),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
                      },
                      child: const Text('Keluar'),
                    ),
                  ],
                ),
              );
            } else {
              Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
            }
          },
        ),
        actions: [
          if (widget.batchMode && _photoCount > 0)
            IconButton(
              icon: const Icon(Icons.done_all, color: Colors.green),
              onPressed: _finishBatch,
              tooltip: 'Selesai Batch',
            ),
          IconButton(
            onPressed: _openWatermarkSettings,
            icon: Stack(
              children: [
                const Icon(Icons.tune, color: Colors.white),
                if (_settingsLoaded && (_wmSettings.operatorName.isNotEmpty ||
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
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _CameraIconWidget(
                batchMode: widget.batchMode,
                photoCount: _photoCount,
              ),
              const Gap(24),
              _HeaderWidget(
                batchMode: widget.batchMode,
                photoCount: _photoCount,
                barcode: widget.barcode,
              ),
              if (widget.batchMode && _photoPaths.isNotEmpty)
                _PhotoThumbnailsWidget(photoPaths: _photoPaths),
              const Gap(48),
              _ActionButtonsWidget(
                onTakePhoto: _takePhoto,
                onPickGallery: _pickFromGallery,
                isSaving: _isSaving,
                isCapturing: _isCapturing,
              ),
              if (widget.batchMode)
                _BatchFinishButtonWidget(
                  photoCount: _photoCount,
                  onFinish: _finishBatch,
                ),
              const Gap(32),
              _InfoBoxWidget(batchMode: widget.batchMode),
            ],
          ),
        ),
      ),
    );
  }
}
