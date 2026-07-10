import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/permission_service.dart';
import '../services/task_queue.dart';
import '../services/pod_location_service.dart';
import '../config/app_config.dart';
import '../theme/app_theme.dart';
import '../watermark/watermark_renderer.dart';
import '../watermark/watermark_settings.dart';
import '../utils/image_compressor.dart';
import '../utils/file_helper.dart';
import 'watermark_settings_sheet.dart';
import 'preview_screen.dart';

// ─── WIDGET: Camera Icon ──────────────────────────────────────
class _CameraIconWidget extends StatelessWidget {
  final bool batchMode;
  final int photoCount;
  const _CameraIconWidget({required this.batchMode, required this.photoCount});

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
                const Icon(Icons.camera_alt, size: 52, color: AppTheme.accentOrange),
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
          : const Icon(Icons.camera_alt, size: 52, color: AppTheme.accentOrange),
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

  static const int _maxThumbnails = 20;

  @override
  Widget build(BuildContext context) {
    if (photoPaths.isEmpty) return const SizedBox.shrink();

    final displayPaths = photoPaths.length > _maxThumbnails
        ? photoPaths.sublist(photoPaths.length - _maxThumbnails)
        : photoPaths;

    return Column(
      children: [
        const Gap(16),
        SizedBox(
          height: 60,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: displayPaths.length,
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(displayPaths[index]),
                    width: 60,
                    height: 60,
                    fit: BoxFit.cover,
                    cacheWidth: 150,
                    cacheHeight: 150,
                    errorBuilder: (_, __, ___) => Container(
                      width: 60,
                      height: 60,
                      color: Colors.grey[800],
                      child: const Icon(Icons.broken_image, size: 24),
                    ),
                  ),
                ),
              );
            },
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
  final bool isProcessing;
  const _ActionButtonsWidget({
    required this.onTakePhoto,
    required this.onPickGallery,
    required this.isSaving,
    required this.isCapturing,
    required this.isProcessing,
  });

  @override
  Widget build(BuildContext context) {
    final bool disabled = isSaving || isCapturing || isProcessing;
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
            label: Text(disabled ? 'Memproses...' : 'Ambil Foto'),
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
              backgroundColor: AppTheme.success,
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
          Icon(Icons.info_outline, size: 16, color: AppTheme.accentBlue),
          const Gap(10),
          Expanded(
            child: Text(
              batchMode
                  ? 'Ambil banyak foto untuk satu barcode. Tekan "Selesai Batch" jika sudah.'
                  : 'Setiap foto otomatis dicatat: waktu & watermark',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
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

  final TaskQueue _taskQueue = TaskQueue(maxWorkers: 2);
  int _pendingTasks = 0;
  int _runningTasks = 0;
  int _nextPhotoIndex = 1;

  bool _isSaving = false;
  bool _isCapturing = false;
  bool _processingRequest = false;
  int _photoCount = 0;
  bool _cameraGranted = false;
  final List<String> _photoPaths = [];
  String _statusText = '';

  late Directory _pendingDir;

  static const int _maxCachedPaths = 100;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _taskQueue.statusStream.listen((task) {
      if (!mounted) return;
      setState(() {
        _pendingTasks = _taskQueue.pendingCount;
        _runningTasks = _taskQueue.runningCount;
      });
    });
    _initPendingDir();
    unawaited(PodLocationService.instance.acquireForCapture());
  }

  Future<void> _initPendingDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    _pendingDir = Directory('${appDir.path}/pending');
    await _pendingDir.create(recursive: true);
  }

  @override
  void dispose() {
    _taskQueue.dispose();
    PodLocationService.instance.releaseAfterCapture();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      if (cameraStatus.isPermanentlyDenied) {
        _showError('Izin kamera ditolak permanen. Buka pengaturan.');
        await openAppSettings();
        return;
      }
      final result = await Permission.camera.request();
      if (mounted) setState(() => _cameraGranted = result.isGranted);
      if (!result.isGranted && mounted) {
        _showError('Izin kamera diperlukan untuk mengambil foto');
        return;
      }
    } else {
      if (mounted) setState(() => _cameraGranted = true);
    }

    if (Platform.isAndroid) {
      final sdkInt = await _getAndroidSdkVersion();
      if (sdkInt >= 29) return;
    }
    await PermissionService.requestGalleryPermission();
  }

  Future<int> _getAndroidSdkVersion() async {
    if (!Platform.isAndroid) return 0;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt;
    } catch (_) {
      return 29;
    }
  }

  Future<bool> _ensureCameraPermission() async {
    if (_cameraGranted) return true;
    final status = await Permission.camera.status;
    if (status.isGranted) {
      if (mounted) setState(() => _cameraGranted = true);
      return true;
    }
    if (status.isPermanentlyDenied) {
      _showError('Izin kamera ditolak permanen. Buka pengaturan.');
      await openAppSettings();
      return false;
    }
    final result = await Permission.camera.request();
    final granted = result.isGranted;
    if (mounted) setState(() => _cameraGranted = granted);
    if (!granted) _showError('Izin kamera ditolak');
    return granted;
  }

  void _openWatermarkSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const WatermarkSettingsSheet(),
    );
  }

  String _resolveFileName(int photoIndex) {
    if (widget.barcode == null) return 'photo_$photoIndex';
    return photoIndex == 1
        ? widget.barcode!
        : '${widget.barcode}${photoIndex.toString().padLeft(3, '0')}';
  }

  Future<String> _saveToPending(XFile xfile) async {
    final file = File(xfile.path);
    if (!await file.exists()) {
      throw Exception('File tidak ditemukan: ${xfile.path}');
    }
    final ext = file.path.split('.').last;
    final destName = 'pending_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final destPath = '${_pendingDir.path}/$destName';
    await file.copy(destPath);
    debugPrint('📁 File disimpan ke pending: $destPath');
    return destPath;
  }

  Future<String> _applyWatermark(String imagePath, DateTime timestamp, int photoIndex) async {
    final fileName = _resolveFileName(photoIndex);
    final outputPath =
        '${File(imagePath).parent.path}/wm_${DateTime.now().millisecondsSinceEpoch}.png';

    final locState = PodLocationService.instance.currentState;
    final tempEntry = ScanEntry(
      id: _storage.generateId(),
      type: ScanType.photo,
      value: fileName,
      barcodeFormat: null,
      timestamp: timestamp,
      latitude: locState.lat,
      longitude: locState.lon,
      locationName: locState.address.isNotEmpty ? locState.address : null,
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
        if (await FileHelper.isTemporaryFile(imagePath)) {
          await file.delete();
          debugPrint('✅ Cache file deleted: $imagePath');
        }
      } catch (e) {
        debugPrint('⚠️ Error deleting file: $e');
      }
    }

    return result ?? imagePath;
  }

  // ─── ✅ PERBAIKAN: _saveToGallery untuk saver_gallery 3.0.10 ──
  Future<bool> _saveToGallery(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('❌ File tidak ditemukan untuk ekspor: $filePath');
        return false;
      }

      final fileSize = await file.length();
      if (fileSize == 0) {
        debugPrint('❌ File kosong: $filePath');
        return false;
      }

      debugPrint('📤 Mengekspor foto: $filePath (${fileSize ~/ 1024}KB)');

      const maxRetries = 2;
      for (int attempt = 0; attempt <= maxRetries; attempt++) {
        try {
          final filename = file.path.split('/').last;
          // ✅ PERBAIKAN: filePath: dan fileName:
          final result = await SaverGallery.saveFile(
            filePath: filePath,
            fileName: filename,
            androidRelativePath: 'Pictures/TERMULScan',
          );
          if (result.isSuccess) {
            debugPrint('✅ Ekspor gallery berhasil: $filename');
            return true;
          }
          debugPrint('⚠️ Percobaan ${attempt + 1} gagal, retry...');
          if (attempt < maxRetries) {
            await Future.delayed(const Duration(milliseconds: 300));
            if (!await file.exists()) {
              debugPrint('❌ File hilang saat retry: $filePath');
              break;
            }
          }
        } catch (e) {
          debugPrint('⚠️ Error ekspor (attempt ${attempt + 1}): $e');
          if (attempt == maxRetries) rethrow;
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
      return false;
    } catch (e, stack) {
      debugPrint('❌ Error _saveToGallery: $e\n$stack');
      return false;
    }
  }

  Future<String?> _showPreview(XFile file, MediaType type) async {
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => PreviewScreen(
          file: file,
          mediaType: type,
          onSave: () => Navigator.pop(context, 'save'),
          onRetake: () => Navigator.pop(context, 'retake'),
        ),
      ),
    );
  }

  Future<void> _takePhoto() async {
    if (_isSaving || _isCapturing || _processingRequest) return;
    if (!await _ensureCameraPermission()) return;

    _processingRequest = true;
    setState(() {
      _isSaving = true;
      _isCapturing = true;
    });

    try {
      final xfile = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (!mounted) return;
      if (xfile != null) {
        final previewResult = await _showPreview(xfile, MediaType.photo);
        if (previewResult == 'save') {
          final pendingPath = await _saveToPending(xfile);
          final photoIndex = _nextPhotoIndex++;

          _taskQueue.add(
            label: 'Foto $photoIndex',
            priority: TaskPriority.high,
            maxRetries: 3,
            work: () => _processPhoto(pendingPath, photoIndex),
            onSuccess: (path) {
              if (mounted) {
                setState(() {
                  _photoPaths.add(path);
                  _photoCount++;
                  if (_photoPaths.length > _maxCachedPaths) {
                    _photoPaths.removeAt(0);
                  }
                });
                if (!widget.batchMode) {
                  _showSuccess();
                  Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
                }
              }
              try { File(pendingPath).delete(); } catch (_) {}
            },
            onError: (error) {
              if (mounted) {
                _showError('Gagal memproses foto: $error');
                if (!widget.batchMode) {
                  Navigator.pop(context, {'error': error.toString()});
                }
              }
              try { File(pendingPath).delete(); } catch (_) {}
            },
          );
          if (!widget.batchMode) {
            setState(() => _statusText = 'Memproses foto...');
          }
        } else {
          try { await File(xfile.path).delete(); } catch (_) {}
          if (mounted) setState(() => _statusText = 'Dibatalkan');
        }
      }
    } catch (e) {
      _showError('Gagal membuka kamera');
    } finally {
      _processingRequest = false;
      if (mounted) {
        setState(() {
          _isSaving = false;
          _isCapturing = false;
        });
      }
    }
  }

  Future<void> _pickFromGallery() async {
    if (_isSaving || _isCapturing || _processingRequest) return;

    _processingRequest = true;
    setState(() {
      _isSaving = true;
      _isCapturing = true;
    });

    try {
      final xfile = await _picker.pickImage(
        source: ImageSource.gallery,
      );
      if (!mounted) return;
      if (xfile != null) {
        final previewResult = await _showPreview(xfile, MediaType.photo);
        if (previewResult == 'save') {
          final pendingPath = await _saveToPending(xfile);
          final photoIndex = _nextPhotoIndex++;

          _taskQueue.add(
            label: 'Foto dari Galeri $photoIndex',
            priority: TaskPriority.high,
            maxRetries: 3,
            work: () => _processPhoto(pendingPath, photoIndex),
            onSuccess: (path) {
              if (mounted) {
                setState(() {
                  _photoPaths.add(path);
                  _photoCount++;
                  if (_photoPaths.length > _maxCachedPaths) {
                    _photoPaths.removeAt(0);
                  }
                });
                if (!widget.batchMode) {
                  _showSuccess();
                  Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
                }
              }
              try { File(pendingPath).delete(); } catch (_) {}
            },
            onError: (error) {
              if (mounted) {
                _showError('Gagal memproses foto: $error');
                if (!widget.batchMode) {
                  Navigator.pop(context, {'error': error.toString()});
                }
              }
              try { File(pendingPath).delete(); } catch (_) {}
            },
          );
          if (!widget.batchMode) {
            setState(() => _statusText = 'Memproses foto...');
          }
        } else {
          try { await File(xfile.path).delete(); } catch (_) {}
          if (mounted) setState(() => _statusText = 'Dibatalkan');
        }
      }
    } catch (e) {
      _showError('Gagal membuka galeri');
    } finally {
      _processingRequest = false;
      if (mounted) {
        setState(() {
          _isSaving = false;
          _isCapturing = false;
        });
      }
    }
  }

  Future<String> _processPhoto(String imagePath, int photoIndex) async {
    String? watermarkedPath;
    String compressedPath = imagePath;
    bool compressedIsTemp = false;

    try {
      final inputFile = File(imagePath);
      if (!await inputFile.exists()) {
        throw Exception('File input tidak ditemukan: $imagePath');
      }
      final inputSize = await inputFile.length();
      if (inputSize == 0) {
        throw Exception('File input kosong: $imagePath');
      }
      debugPrint('📷 Input file OK: $imagePath (${inputSize ~/ 1024}KB)');

      compressedPath = await ImageCompressor.compressIfNeeded(imagePath);
      compressedIsTemp = compressedPath != imagePath &&
          await FileHelper.isTemporaryFile(compressedPath);

      final compressedFile = File(compressedPath);
      if (!await compressedFile.exists()) {
        throw Exception('File hasil kompresi tidak ditemukan: $compressedPath');
      }
      final compressedSize = await compressedFile.length();
      if (compressedSize == 0) {
        throw Exception('File hasil kompresi kosong: $compressedPath');
      }
      debugPrint('✅ Kompresi OK: $compressedPath (${compressedSize ~/ 1024}KB)');

      final timestamp = DateTime.now();
      watermarkedPath = await _applyWatermark(compressedPath, timestamp, photoIndex);

      if (watermarkedPath == null) {
        throw Exception('Watermark gagal menghasilkan file');
      }
      final watermarkedFile = File(watermarkedPath);
      if (!await watermarkedFile.exists()) {
        throw Exception('File watermark tidak ditemukan: $watermarkedPath');
      }
      final watermarkSize = await watermarkedFile.length();
      if (watermarkSize == 0) {
        throw Exception('File watermark kosong: $watermarkedPath');
      }
      debugPrint('✅ Watermark OK: $watermarkedPath (${watermarkSize ~/ 1024}KB)');

      final name = _resolveFileName(photoIndex);
      final savedPath = await _storage.savePhoto(watermarkedPath, name: name);
      if (savedPath.isEmpty) {
        throw Exception('Gagal menyimpan file foto internal');
      }
      final savedFile = File(savedPath);
      if (!await savedFile.exists()) {
        throw Exception('File internal tidak ditemukan setelah save: $savedPath');
      }
      debugPrint('✅ Internal save OK: $savedPath');

      if (watermarkedPath != savedPath &&
          await FileHelper.isTemporaryFile(watermarkedPath) &&
          await File(watermarkedPath).exists()) {
        try { await File(watermarkedPath).delete(); } catch (_) {}
      }

      if (widget.entryId != null) {
        final barcodeEntry = await _storage.getEntry(widget.entryId!);
        if (barcodeEntry != null) {
          final updated = barcodeEntry.copyWith(photoPaths: List.from(_photoPaths)..add(savedPath));
          await _storage.update(updated);
        }
      }

      final galleryOk = await _saveToGallery(savedPath);
      if (!galleryOk) {
        debugPrint('⚠️ Gagal ekspor ke gallery, file tetap tersimpan di internal');
      }

      if (widget.batchMode && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('📸 Foto $photoIndex berhasil (${widget.barcode ?? 'tanpa barcode'})'),
            duration: const Duration(seconds: 1),
            backgroundColor: AppTheme.success,
          ),
        );
      }

      return savedPath;
    } catch (e, stack) {
      debugPrint('❌ Error processing photo #$photoIndex ($imagePath): $e\n$stack');
      if (watermarkedPath != null && watermarkedPath != compressedPath) {
        try { await File(watermarkedPath).delete(); } catch (_) {}
      }
      if (compressedIsTemp && compressedPath != imagePath) {
        try { await File(compressedPath).delete(); } catch (_) {}
      }
      rethrow;
    } finally {
      if (compressedIsTemp && compressedPath != imagePath) {
        try { await File(compressedPath).delete(); } catch (_) {}
      }
    }
  }

  Future<void> _finishBatch() async {
    if (widget.entryId != null && _photoPaths.isNotEmpty) {
      if (!mounted) return;
      final barcodeEntry = await _storage.getEntry(widget.entryId!);
      if (barcodeEntry != null && mounted) {
        final updated = barcodeEntry.copyWith(photoPaths: List.from(_photoPaths));
        await _storage.update(updated);
      }
    }

    if (_photoPaths.isNotEmpty) {
      await _showBatchSummaryAndPop();
    } else {
      if (mounted) Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
    }
  }

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
              children: _photoPaths.take(10).map((path) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.file(
                    File(path),
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    cacheWidth: 100,
                    cacheHeight: 100,
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
    if (mounted) Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
  }

  void _showSuccess() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppTheme.success,
        duration: const Duration(seconds: 2),
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 18),
            Gap(8),
            Expanded(child: Text('Foto tersimpan', maxLines: 1, overflow: TextOverflow.ellipsis)),
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

  @override
  Widget build(BuildContext context) {
    final bool isProcessing = _pendingTasks > 0 || _runningTasks > 0;

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
                        if (mounted) Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
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
          if (_pendingTasks > 0)
            IconButton(
              icon: const Icon(Icons.cancel, color: AppTheme.error),
              onPressed: () {
                _taskQueue.cancelAllPending();
                setState(() {});
              },
              tooltip: 'Batalkan semua antrian',
            ),
          ListenableBuilder(
            listenable: _wmSettings,
            builder: (context, _) {
              return IconButton(
                onPressed: _openWatermarkSettings,
                icon: Stack(
                  children: [
                    const Icon(Icons.tune, color: Colors.white),
                    if (_wmSettings.operatorName.isNotEmpty || _wmSettings.hasLogo)
                      const Positioned(
                        right: 0,
                        top: 0,
                        child: Icon(Icons.circle, size: 8, color: AppTheme.accent),
                      ),
                  ],
                ),
                tooltip: 'Pengaturan Watermark',
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _CameraIconWidget(batchMode: widget.batchMode, photoCount: _photoCount),
              const Gap(24),
              _HeaderWidget(batchMode: widget.batchMode, photoCount: _photoCount, barcode: widget.barcode),
              if (widget.batchMode && _photoPaths.isNotEmpty)
                _PhotoThumbnailsWidget(photoPaths: _photoPaths),
              const Gap(48),
              _ActionButtonsWidget(
                onTakePhoto: _takePhoto,
                onPickGallery: _pickFromGallery,
                isSaving: _isSaving,
                isCapturing: _isCapturing,
                isProcessing: isProcessing,
              ),
              if (widget.batchMode)
                _BatchFinishButtonWidget(photoCount: _photoCount, onFinish: _finishBatch),
              const Gap(32),
              _InfoBoxWidget(batchMode: widget.batchMode),
              if (_isSaving || isProcessing)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(
                    backgroundColor: Colors.grey[800],
                    valueColor: AlwaysStoppedAnimation(AppTheme.accentOrange),
                  ),
                ),
              if (_statusText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_statusText, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ),
              if (_pendingTasks > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('$_pendingTasks foto dalam antrian...', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ),
              if (_runningTasks > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('$_runningTasks foto sedang diproses...', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
