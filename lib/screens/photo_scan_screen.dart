import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
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
import 'in_app_camera_screen.dart';

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
              ? '$photoCount foto siap disimpan untuk ${barcode ?? 'tanpa barcode'}'
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
  final bool isSaving;
  final VoidCallback onFinish;
  const _BatchFinishButtonWidget({
    required this.photoCount,
    required this.onFinish,
    this.isSaving = false,
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
            onPressed: isSaving ? null : onFinish,
            icon: isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.save, size: 20),
            label: Text(isSaving ? 'Menyimpan...' : 'Simpan Semua ($photoCount foto)'),
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
                  ? 'Ambil banyak foto untuk satu barcode, lalu tekan "Simpan Semua" — semua foto disimpan sekaligus.'
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

  // ─── TaskQueue ──────────────────────────────────────────────
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
  // ✅ Foto batch yang sudah dikonfirmasi (preview → "Simpan foto ini")
  // tapi belum di-finalize ke storage/DB — menunggu tombol "Simpan" utama.
  final List<_PendingCapture> _pendingCaptures = [];
  bool _isFinishingBatch = false;
  String _statusText = '';

  // ─── Pending directory ─────────────────────────────────────
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
    if (_wmSettings.gpsWatermarkEnabled) {
      unawaited(PodLocationService.instance.acquireForCapture(owner: this));
    }
  }

  Future<void> _initPendingDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    _pendingDir = Directory('${appDir.path}/pending');
    await _pendingDir.create(recursive: true);
  }

  @override
  void dispose() {
    _taskQueue.dispose();
    PodLocationService.instance.releaseAfterCapture(owner: this);
    // ✅ FIX: kalau layar ditutup selagi masih ada foto yang sudah
    // dikonfirmasi tapi belum di-"Simpan", jangan tinggalkan file
    // watermark/pending-nya menggantung selamanya di storage.
    for (final cap in _pendingCaptures) {
      try { File(cap.watermarkedPath).delete(); } catch (_) {}
      try { File(cap.pendingPath).delete(); } catch (_) {}
    }
    super.dispose();
  }

  // ─── Permission ─────────────────────────────────────────────

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

  // ─── Settings ───────────────────────────────────────────────

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

  // ─── File naming ────────────────────────────────────────────

  String _resolveFileName(int photoIndex) {
    if (widget.barcode == null || widget.barcode!.isEmpty) {
      return 'photo_$photoIndex';
    }
    return photoIndex == 1
        ? widget.barcode!
        : '${widget.barcode}${photoIndex.toString().padLeft(3, '0')}';
  }

  // ─── Pending file helper ─────────────────────────────────────

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

  // ─── Core processing ────────────────────────────────────────

  Future<String> _applyWatermark(String imagePath, DateTime timestamp, int photoIndex) async {
    final fileName = _resolveFileName(photoIndex);
    final outputPath =
        '${File(imagePath).parent.path}/wm_${DateTime.now().millisecondsSinceEpoch}.jpg';

    // ✅ FIX RACE CONDITION ALAMAT: dulu pakai `.currentState` (snapshot
    // instan), sehingga watermark foto sering "kepalang dibakar" duluan
    // sebelum reverse-geocoding (Nominatim/Photon/Android Geocoder)
    // selesai — hasilnya watermark hanya menampilkan koordinat, padahal
    // alamat sebenarnya berhasil didapat beberapa saat kemudian (tapi
    // sudah terlambat karena file sudah jadi). Untuk aplikasi POD,
    // alamat adalah bagian penting dari bukti pengiriman, jadi di sini
    // kita tunggu (dengan timeout wajar) sampai alamat siap — tombol
    // jepret kamera TETAP instan, yang ditunda hanya tahap render
    // watermark (yang memang sudah menampilkan indikator "memproses").
    // ✅ FIX: dulu timeout di sini cuma 6 detik, padahal jalur lain yang
    // menunggu lokasi bukti (barcode_scan_screen, video_scan_screen bagian
    // _attachLocationUpdate) memakai 15 detik. Rantai geocoding
    // (resolveDetailed: Nominatim multi-zoom + POI lookup + Overpass,
    // masing-masing dijaga rate-limit 1req/detik) realistiknya sering
    // butuh lebih dari 6 detik, terutama di area yang datanya kurang
    // lengkap di zoom tinggi — akibatnya alamat sering belum siap saat
    // watermark foto dirender, dan watermark jatuh ke koordinat saja.
    // Disamakan ke 15 detik agar fallback lock GPS 12 detik sempat terpakai.
    final locState = _wmSettings.gpsWatermarkEnabled
        ? await PodLocationService.instance.awaitEvidenceReady(
            timeout: const Duration(seconds: 15),
          )
        : null;

    final tempEntry = ScanEntry(
      id: _storage.generateId(),
      type: ScanType.image,
      value: fileName,
      timestamp: timestamp,
      operatorName: _wmSettings.operatorName.isNotEmpty 
          ? _wmSettings.operatorName 
          : 'Operator',
      companyName: _wmSettings.companyName,
      latitude: locState?.lat,
      longitude: locState?.lon,
      locationName: locState != null && locState.evidenceAddress.isNotEmpty
          ? locState.evidenceAddress
          : null,
      isManual: false,
    );

    final result = await WatermarkRenderer.render(
      imagePath: imagePath,
      outputPath: outputPath,
      settings: _wmSettings,
      entry: tempEntry,
    );

    if (result == null) {
      final diagnosis = WatermarkRenderer.lastError;
      throw Exception(
        diagnosis != null ? 'Watermark foto gagal: $diagnosis' : 'Watermark foto gagal',
      );
    }

    if (result != imagePath) {
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

    return result;
  }

  // ─── Save to Gallery ─────────────────────────────────────────

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
          final filename = file.uri.pathSegments.last;
          final saved = await _storage.savePhotoToGallery(
            filePath,
            fileName: filename,
          );
          if (saved) {
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

  // ─── Preview helper ─────────────────────────────────────────

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

  // ─── Take photo ─────────────────────────────────────────────

  Future<void> _takePhoto() async {
    if (_isSaving || _isCapturing || _processingRequest || _isFinishingBatch) return;
    if (!await _ensureCameraPermission()) return;

    _processingRequest = true;
    setState(() {
      _isSaving = true;
      _isCapturing = true;
    });

    String? pendingPath;
    String? watermarkedPath;

    try {
      final xfile = await Navigator.push<XFile>(
        context,
        MaterialPageRoute(
          builder: (_) => const InAppCameraScreen(),
          fullscreenDialog: true,
        ),
      );
      if (!mounted) return;
      if (xfile != null) {
        pendingPath = await _saveToPending(xfile);
        try { await File(xfile.path).delete(); } catch (_) {}

        setState(() => _statusText = 'Menambahkan watermark...');
        final previewIndex = _nextPhotoIndex;
        watermarkedPath = await _prepareWatermarkedPhoto(pendingPath, previewIndex);
        if (!mounted) return;

        final previewResult = await _showPreview(XFile(watermarkedPath), MediaType.photo);
        if (previewResult == 'save') {
          final photoIndex = _nextPhotoIndex++;
          final finalWatermarkedPath = watermarkedPath;
          final finalPendingPath = pendingPath;

          if (widget.batchMode) {
            // ✅ Batch: jangan finalize sekarang. Cukup simpan sebagai
            // "sudah dikonfirmasi", finalize semuanya sekaligus nanti
            // saat tombol "Simpan" utama ditekan.
            if (mounted) {
              setState(() {
                _pendingCaptures.add(_PendingCapture(
                  watermarkedPath: finalWatermarkedPath,
                  pendingPath: finalPendingPath,
                  photoIndex: photoIndex,
                ));
                _photoPaths.add(finalWatermarkedPath);
                _photoCount++;
                if (_photoPaths.length > _maxCachedPaths) {
                  _photoPaths.removeAt(0);
                }
                _statusText = '$_photoCount foto siap disimpan';
              });
            }
            // watermarkedPath & pendingPath SENGAJA tidak dihapus di sini —
            // masih dibutuhkan nanti saat _saveAllPending() finalize.
          } else {
            final finalizeState = _FinalizeState();
            _taskQueue.add(
              label: 'Foto $photoIndex',
              priority: TaskPriority.high,
              maxRetries: 3,
              work: () => _finalizePhoto(finalWatermarkedPath, finalPendingPath, photoIndex, finalizeState),
              onSuccess: (path) {
                if (mounted) {
                  setState(() {
                    _photoPaths.add(path);
                    _photoCount++;
                    if (_photoPaths.length > _maxCachedPaths) {
                      _photoPaths.removeAt(0);
                    }
                  });
                  _showSuccess();
                  Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
                }
              },
              onError: (error) {
                if (mounted) {
                  _showError('Gagal memproses foto: $error');
                  Navigator.pop(context, {'error': error.toString()});
                }
                try { File(finalWatermarkedPath).delete(); } catch (_) {}
                try { File(finalPendingPath).delete(); } catch (_) {}
              },
            );
            setState(() => _statusText = 'Menyimpan foto...');
          }
        } else {
          try { await File(watermarkedPath).delete(); } catch (_) {}
          try { await File(pendingPath).delete(); } catch (_) {}
          if (mounted) setState(() => _statusText = 'Dibatalkan');
        }
      }
    } catch (e) {
      _showError('Gagal memproses foto: $e');
      if (watermarkedPath != null) {
        try { await File(watermarkedPath).delete(); } catch (_) {}
      }
      if (pendingPath != null) {
        try { await File(pendingPath).delete(); } catch (_) {}
      }
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
    if (_isSaving || _isCapturing || _processingRequest || _isFinishingBatch) return;

    _processingRequest = true;
    setState(() {
      _isSaving = true;
      _isCapturing = true;
    });

    String? pendingPath;
    String? watermarkedPath;

    try {
      final xfile = await _picker.pickImage(
        source: ImageSource.gallery,
      );
      if (!mounted) return;
      if (xfile != null) {
        pendingPath = await _saveToPending(xfile);
        try { await File(xfile.path).delete(); } catch (_) {}

        setState(() => _statusText = 'Menambahkan watermark...');
        final previewIndex = _nextPhotoIndex;
        watermarkedPath = await _prepareWatermarkedPhoto(pendingPath, previewIndex);
        if (!mounted) return;

        final previewResult = await _showPreview(XFile(watermarkedPath), MediaType.photo);
        if (previewResult == 'save') {
          final photoIndex = _nextPhotoIndex++;
          final finalWatermarkedPath = watermarkedPath;
          final finalPendingPath = pendingPath;

          if (widget.batchMode) {
            if (mounted) {
              setState(() {
                _pendingCaptures.add(_PendingCapture(
                  watermarkedPath: finalWatermarkedPath,
                  pendingPath: finalPendingPath,
                  photoIndex: photoIndex,
                ));
                _photoPaths.add(finalWatermarkedPath);
                _photoCount++;
                if (_photoPaths.length > _maxCachedPaths) {
                  _photoPaths.removeAt(0);
                }
                _statusText = '$_photoCount foto siap disimpan';
              });
            }
          } else {
            final finalizeState = _FinalizeState();
            _taskQueue.add(
              label: 'Foto dari Galeri $photoIndex',
              priority: TaskPriority.high,
              maxRetries: 3,
              work: () => _finalizePhoto(finalWatermarkedPath, finalPendingPath, photoIndex, finalizeState),
              onSuccess: (path) {
                if (mounted) {
                  setState(() {
                    _photoPaths.add(path);
                    _photoCount++;
                    if (_photoPaths.length > _maxCachedPaths) {
                      _photoPaths.removeAt(0);
                    }
                  });
                  _showSuccess();
                  Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
                }
              },
              onError: (error) {
                if (mounted) {
                  _showError('Gagal memproses foto: $error');
                  Navigator.pop(context, {'error': error.toString()});
                }
                try { File(finalWatermarkedPath).delete(); } catch (_) {}
                try { File(finalPendingPath).delete(); } catch (_) {}
              },
            );
            setState(() => _statusText = 'Menyimpan foto...');
          }
        } else {
          try { await File(watermarkedPath).delete(); } catch (_) {}
          try { await File(pendingPath).delete(); } catch (_) {}
          if (mounted) setState(() => _statusText = 'Dibatalkan');
        }
      }
    } catch (e) {
      _showError('Gagal memproses foto: $e');
      if (watermarkedPath != null) {
        try { await File(watermarkedPath).delete(); } catch (_) {}
      }
      if (pendingPath != null) {
        try { await File(pendingPath).delete(); } catch (_) {}
      }
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

  // ─── Core processing logic ──────────────────────────────────

  Future<String> _prepareWatermarkedPhoto(String pendingPath, int photoIndex) async {
    final inputFile = File(pendingPath);
    if (!await inputFile.exists()) {
      throw Exception('File input tidak ditemukan: $pendingPath');
    }
    final inputSize = await inputFile.length();
    if (inputSize == 0) {
      throw Exception('File input kosong: $pendingPath');
    }
    debugPrint('📷 Input file OK: $pendingPath (${inputSize ~/ 1024}KB)');

    final compressedPath = await ImageCompressor.compressIfNeeded(pendingPath);
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
    final watermarkedPath = await _applyWatermark(compressedPath, timestamp, photoIndex);

    final watermarkedFile = File(watermarkedPath);
    if (!await watermarkedFile.exists()) {
      throw Exception('File watermark tidak ditemukan: $watermarkedPath');
    }
    final watermarkSize = await watermarkedFile.length();
    if (watermarkSize == 0) {
      throw Exception('File watermark kosong: $watermarkedPath');
    }
    debugPrint('✅ Watermark OK (pre-preview): $watermarkedPath (${watermarkSize ~/ 1024}KB)');

    return watermarkedPath;
  }

  Future<String> _finalizePhoto(
    String watermarkedPath,
    String pendingPath,
    int photoIndex,
    _FinalizeState state, {
    // ✅ FIX URUTAN FOTO: dulu dengan `maxWorkers: 2`, urutan append ke
    // `imagePath` di DB mengikuti siapa yang SELESAI diproses duluan,
    // bukan urutan foto diambil — kalau foto #2 kebetulan selesai lebih
    // cepat dari foto #1 (mis. #1 kena retry watermark), urutan foto di
    // laporan POD bisa terbalik dari urutan pengambilan aslinya.
    // `waitForTurn` (kalau diisi) ditunggu SEBELUM append DB, dan
    // `onTurnDone` dipanggil TEPAT SETELAH append DB ini selesai (baik
    // sukses maupun gagal) — bukan menunggu langkah setelahnya (ekspor
    // galeri) yang bisa lebih lama. Hasilnya: append tetap berjalan satu
    // per satu sesuai photoIndex, tapi tahap lain (compress, watermark,
    // ekspor galeri) tetap paralel seperti biasa.
    Future<void> Function()? waitForTurn,
    void Function()? onTurnDone,
  }) async {
    try {
      String savedPath;

      if (state.savedPath != null) {
        // ✅ FIX RETRY: percobaan sebelumnya sudah berhasil memindah
        // (rename/move) watermarkedPath -> internal storage. Karena
        // _storage.savePhoto() MEMINDAHKAN file (bukan copy), file di
        // watermarkedPath sudah tidak ada lagi setelah sukses — kalau
        // langkah SETELAHNYA (mis. _storage.update / _saveToGallery)
        // baru gagal dan TaskQueue me-retry _finalizePhoto() dari
        // awal, cek exists() di watermarkedPath pasti gagal walau
        // sebenarnya foto SUDAH tersimpan dengan aman. Ini akar dari
        // error "File watermark tidak ditemukan" yang dilaporkan user
        // padahal proses pemindahan filenya sendiri sukses. Solusinya:
        // ingat hasil savePhoto lintas percobaan lewat `state`, dan
        // pada retry langsung lanjut dari langkah setelah move, tanpa
        // mengulang cek/eksekusi move yang sudah tidak relevan lagi.
        savedPath = state.savedPath!;
        debugPrint('↩️ Retry: pakai hasil save sebelumnya: $savedPath');
      } else {
        final watermarkedFile = File(watermarkedPath);
        if (!await watermarkedFile.exists()) {
          throw Exception('File watermark tidak ditemukan: $watermarkedPath');
        }
        final watermarkSize = await watermarkedFile.length();
        if (watermarkSize == 0) {
          throw Exception('File watermark kosong: $watermarkedPath');
        }

        final name = _resolveFileName(photoIndex);
        savedPath = await _storage.savePhoto(watermarkedPath, name: name);
        if (savedPath.isEmpty) {
          throw Exception('Gagal menyimpan file foto internal');
        }
        final savedFile = File(savedPath);
        if (!await savedFile.exists()) {
          throw Exception('File internal tidak ditemukan setelah save: $savedPath');
        }
        state.savedPath = savedPath;
        debugPrint('✅ Internal save OK: $savedPath');
      }

      if (widget.entryId != null && !state.dbUpdated) {
        // Tunggu giliran (foto dengan photoIndex lebih kecil harus
        // append duluan) sebelum kita append.
        if (waitForTurn != null) await waitForTurn();
        try {
          // Append dilakukan di dalam transaksi database. Dengan dua worker,
          // read-modify-write dari state UI dapat membuat update terakhir
          // menimpa path yang baru saja disimpan worker lain — gate di atas
          // memastikan "terakhir" itu selalu foto dengan index terbesar,
          // bukan sekadar siapa yang tercepat.
          final updated =
              await _storage.appendPhotoPath(widget.entryId!, savedPath);
          if (updated == null) {
            throw StateError(
              'Entry ${widget.entryId} tidak ditemukan saat menyimpan foto',
            );
          }
          // ✅ FIX RETRY: tandai sudah dijalankan supaya retry berikutnya
          // (dipicu langkah lain yang gagal setelah ini) tidak mengulang
          // update DB — kalau diulang, `savedPath` bisa ke-append dua kali
          // ke `imagePath` karena `_photoPaths` di state UI baru diperbarui
          // di `onSuccess`, bukan di sini.
          state.dbUpdated = true;
        } finally {
          // Lepas giliran SEGERA setelah append ini selesai (berhasil
          // ataupun gagal) — supaya foto berikutnya tidak ikut menunggu
          // ekspor galeri foto ini yang bisa lebih lama, dan supaya foto
          // berikutnya tidak nyangkut selamanya kalau append ini gagal.
          onTurnDone?.call();
        }
      } else if (state.dbUpdated) {
        debugPrint('↩️ Retry: lewati update DB, sudah sukses sebelumnya');
      } else {
        // entryId null (foto berdiri sendiri) — tidak ada append yang
        // perlu diurutkan, tapi tetap lepas giliran supaya foto
        // berikutnya (jika dipanggil dengan gate) tidak menunggu percuma.
        onTurnDone?.call();
      }

      if (!state.galleryOk) {
        state.galleryOk = await _saveToGallery(savedPath);
        if (!state.galleryOk) {
          debugPrint('⚠️ Gagal ekspor ke gallery, file tetap tersimpan di internal');
        }
      } else {
        debugPrint('↩️ Retry: lewati ekspor gallery, sudah sukses sebelumnya');
      }

      // Cleanup source files SETELAH semua langkah di atas sukses.
      if (watermarkedPath != savedPath && await File(watermarkedPath).exists()) {
        try { await File(watermarkedPath).delete(); } catch (_) {}
      }
      if (pendingPath != savedPath && await File(pendingPath).exists()) {
        try { await File(pendingPath).delete(); } catch (_) {}
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
      debugPrint('❌ Error finalisasi foto #$photoIndex ($watermarkedPath): $e\n$stack');
      rethrow;
    }
  }

  // ─── Batch finish: simpan SEMUA foto pending sekaligus ───────
  // ✅ Ini yang dipanggil tombol "Simpan" utama: baru di titik inilah
  // semua foto yang sudah dikonfirmasi di preview benar-benar di-
  // finalize (dipindah ke storage internal, di-append ke DB, dan
  // diekspor ke galeri) — satu kali proses untuk semua foto, lalu
  // langsung kembali ke menu utama begitu selesai (tanpa dialog ringkasan).
  Future<void> _finishBatch() async {
    if (_pendingCaptures.isEmpty) {
      if (mounted) Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
      return;
    }

    // ✅ FIX URUTAN: urutkan dulu berdasarkan photoIndex (urutan foto
    // diambil), lalu setiap foto menunggu giliran foto sebelumnya selesai
    // append DB dulu sebelum boleh append sendiri — supaya proses tetap
    // paralel (compress/watermark/gallery), tapi urutan foto di DB selalu
    // sesuai urutan pengambilan, bukan siapa yang selesai duluan.
    final captures = List<_PendingCapture>.of(_pendingCaptures)
      ..sort((a, b) => a.photoIndex.compareTo(b.photoIndex));
    setState(() {
      _isFinishingBatch = true;
      _statusText = 'Menyimpan ${captures.length} foto...';
    });

    final savedByIndex = <int, String>{};
    final errors = <Object>[];
    var completedCount = 0;
    final completer = Completer<void>();

    Completer<void>? previousGate;
    for (final cap in captures) {
      final myGate = Completer<void>();
      final waitFor = previousGate;
      _taskQueue.add(
        label: 'Simpan foto batch ${cap.photoIndex}',
        priority: TaskPriority.high,
        maxRetries: 3,
        work: () => _finalizePhoto(
          cap.watermarkedPath,
          cap.pendingPath,
          cap.photoIndex,
          _FinalizeState(),
          waitForTurn: waitFor == null ? null : () => waitFor.future,
          onTurnDone: () {
            if (!myGate.isCompleted) myGate.complete();
          },
        ),
        onSuccess: (path) {
          savedByIndex[cap.photoIndex] = path;
          completedCount++;
          // Jaring pengaman: kalau onTurnDone entah kenapa tidak sempat
          // terpanggil, tetap lepas giliran di sini supaya foto
          // berikutnya tidak nyangkut selamanya.
          if (!myGate.isCompleted) myGate.complete();
          if (mounted) setState(() => _statusText = 'Menyimpan foto... ($completedCount/${captures.length})');
          if (completedCount == captures.length && !completer.isCompleted) {
            completer.complete();
          }
        },
        onError: (error) {
          errors.add(error);
          completedCount++;
          if (!myGate.isCompleted) myGate.complete();
          if (completedCount == captures.length && !completer.isCompleted) {
            completer.complete();
          }
        },
      );
      previousGate = myGate;
    }

    await completer.future;
    _pendingCaptures.clear();

    if (!mounted) return;

    if (errors.isNotEmpty) {
      _showError('${errors.length} dari ${captures.length} foto gagal disimpan. ${savedByIndex.length} foto berhasil.');
    }

    // Urutkan hasil balik sesuai photoIndex juga (bukan urutan selesai).
    final orderedSavedPaths = captures
        .where((c) => savedByIndex.containsKey(c.photoIndex))
        .map((c) => savedByIndex[c.photoIndex]!)
        .toList();

    // ✅ Langsung kembali ke menu utama — tidak ada dialog ringkasan lagi.
    Navigator.pop(context, {'count': orderedSavedPaths.length, 'paths': orderedSavedPaths});
  }

  // ─── Feedback ──────────────────────────────────────────────

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

  // ─── Build ──────────────────────────────────────────────────

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
            if (widget.batchMode && _pendingCaptures.isNotEmpty) {
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Foto Belum Disimpan'),
                  content: Text(
                    '${_pendingCaptures.length} foto sudah diambil tapi belum disimpan. '
                    'Simpan sekarang, atau buang dan keluar?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Lanjutkan'),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context); // tutup dialog
                        // ✅ Buang foto pending (belum tersimpan) & keluar
                        // tanpa menyimpan apa pun.
                        for (final cap in _pendingCaptures) {
                          try { File(cap.watermarkedPath).delete(); } catch (_) {}
                          try { File(cap.pendingPath).delete(); } catch (_) {}
                        }
                        _pendingCaptures.clear();
                        if (mounted) Navigator.pop(context, {'count': 0, 'paths': const <String>[]});
                      },
                      child: const Text('Buang'),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context); // tutup dialog
                        _finishBatch(); // simpan semua lalu keluar
                      },
                      child: const Text('Simpan'),
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
          if (widget.batchMode && _pendingCaptures.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.done_all, color: Colors.green),
              onPressed: _isFinishingBatch ? null : _finishBatch,
              tooltip: 'Simpan Semua',
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
                isSaving: _isSaving || _isFinishingBatch,
                isCapturing: _isCapturing,
                isProcessing: isProcessing,
              ),
              if (widget.batchMode)
                _BatchFinishButtonWidget(
                  photoCount: _pendingCaptures.length,
                  isSaving: _isFinishingBatch,
                  onFinish: _finishBatch,
                ),
              const Gap(32),
              _InfoBoxWidget(batchMode: widget.batchMode),
              if (_isSaving || isProcessing || _isFinishingBatch)
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

/// Menyimpan hasil pemindahan file (savePhoto) dan status langkah-
/// langkah fallible berikutnya lintas percobaan TaskQueue, supaya
/// retry _finalizePhoto() tidak mengulang langkah yang sudah sukses
/// (file sudah dipindah, DB sudah di-update, atau foto sudah masuk
/// galeri).
class _FinalizeState {
  String? savedPath;
  bool dbUpdated = false;
  bool galleryOk = false;
}

/// ✅ Foto batch yang sudah dikonfirmasi user di layar preview (watermark
/// sudah dirender) TAPI belum di-finalize (belum dipindah ke storage
/// internal, belum di-append ke DB, belum diekspor ke galeri). Baru
/// diproses semuanya sekaligus saat user menekan tombol "Simpan".
class _PendingCapture {
  final String watermarkedPath;
  final String pendingPath;
  final int photoIndex;
  const _PendingCapture({
    required this.watermarkedPath,
    required this.pendingPath,
    required this.photoIndex,
  });
}
