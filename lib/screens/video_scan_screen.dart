import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/permission_service.dart';
import '../services/task_queue.dart';
import '../services/background/video_processing_service.dart';
import '../services/pod_location_service.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/watermark_style.dart';
import '../services/watermark/watermark_service.dart';
import '../theme/app_theme.dart';
import '../utils/file_helper.dart';
import 'preview_screen.dart';
import 'watermark_settings_sheet.dart';

class VideoScanScreen extends StatefulWidget {
  final String? barcode;
  const VideoScanScreen({super.key, this.barcode});

  @override
  State<VideoScanScreen> createState() => _VideoScanScreenState();
}

class _VideoScanScreenState extends State<VideoScanScreen> {
  final ImagePicker _picker = ImagePicker();
  final StorageService _storage = StorageService();

  late final TaskQueue _taskQueue = TaskQueue(
    maxWorkers: 1,
    onActiveStart: () => unawaited(VideoProcessingService.markBusy(
      title: 'TERMULScan',
      text: 'Menyiapkan render video...',
    )),
    onActiveEnd: () => unawaited(VideoProcessingService.markIdle()),
  );
  int _pendingTasks = 0;
  int _runningTasks = 0;

  bool _isSaving = false;
  bool _isProcessing = false;
  String _statusText = '';
  double _progress = 0.0;

  static const int _maxVideoSizeBytes = 50 * 1024 * 1024;
  static const int _minVideoDurationSeconds = 3;

  @override
  void initState() {
    super.initState();
    PermissionService.requestGalleryPermission();
    unawaited(VideoProcessingService.requestPermissions());
    _taskQueue.statusStream.listen((task) {
      if (!mounted) return;
      setState(() {
        _pendingTasks = _taskQueue.pendingCount;
        _runningTasks = _taskQueue.runningCount;
        _isProcessing = _pendingTasks > 0 || _runningTasks > 0;
      });
    });
    unawaited(PodLocationService.instance.acquireForCapture());
  }

  @override
  void dispose() {
    _taskQueue.dispose();
    PodLocationService.instance.releaseAfterCapture();
    super.dispose();
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  // ─── Permission ─────────────────────────────────────────────
  Future<bool> _ensureCameraPermission() async {
    final status = await Permission.camera.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Izin kamera ditolak permanen. Buka pengaturan.')),
        );
        await openAppSettings();
      }
      return false;
    }
    final result = await Permission.camera.request();
    if (result.isGranted) return true;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Izin kamera diperlukan untuk merekam video')),
      );
    }
    return false;
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

  // ─── Pick & Record ──────────────────────────────────────────
  Future<void> _pickAndRecord() async {
    if (_isSaving || _isProcessing) return;
    if (!await _ensureCameraPermission()) return;

    setState(() {
      _isSaving = true;
      _statusText = 'Membuka kamera...';
    });

    try {
      final XFile? videoFile = await _picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(seconds: 20),
        preferredCameraDevice: CameraDevice.rear,
      );
      if (!mounted) return;
      if (videoFile == null) {
        setState(() {
          _isSaving = false;
          _statusText = 'Dibatalkan';
        });
        return;
      }

      final previewResult = await _showPreview(videoFile, MediaType.video);
      if (previewResult == 'save') {
        _taskQueue.add(
          label: 'Video ${widget.barcode ?? ''}',
          priority: TaskPriority.high,
          maxRetries: 2,
          work: () => _processVideo(videoFile),
          onSuccess: (entry) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✅ Video tersimpan: ${(entry as ScanEntry).value}'),
                backgroundColor: Colors.green,
              ),
            );
            Navigator.pop(context, {'entry': entry});
          },
          onError: (error) {
            if (!mounted) return;
            _showError('Gagal memproses video: $error');
          },
        );
        setState(() {
          _isSaving = false;
          _statusText = 'Video direkam, memproses di background...';
        });
      } else {
        try { await File(videoFile.path).delete(); } catch (_) {}
        setState(() {
          _isSaving = false;
          _statusText = 'Dibatalkan';
        });
      }
    } catch (e) {
      debugPrint('❌ Gagal merekam video: $e');
      if (mounted) {
        setState(() {
          _isSaving = false;
          _statusText = 'Gagal merekam';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal merekam: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  // ─── Core Processing ────────────────────────────────────────
  Future<bool> _maybeDeleteLocalCopy(String path, bool galleryOk) async {
    if (!galleryOk) return false;
    final settings = context.read<WatermarkSettings>();
    if (!settings.deleteLocalVideoAfterGalleryExport) return false;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
      debugPrint('🗑️ Salinan lokal dihapus (sudah ada di Galeri): $path');
      return true;
    } catch (e) {
      debugPrint('⚠️ Gagal menghapus salinan lokal: $e');
      return false;
    }
  }

  Future<ScanEntry> _processVideo(XFile videoFile) async {
    final settings = context.read<WatermarkSettings>();

    String? finalPath;
    String? thumbnailPath;
    int durationSeconds = 0;
    bool galleryOk = false;
    bool localCopyDeleted = false;

    try {
      final file = File(videoFile.path);
      if (!await file.exists()) throw Exception('File video tidak ditemukan');

      final fileSize = await file.length();
      if (fileSize > _maxVideoSizeBytes) {
        await file.delete();
        throw Exception('Video terlalu besar. Maks 50 MB.');
      }

      // 1. Durasi video
      try {
        final vc = VideoPlayerController.file(file);
        await vc.initialize();
        durationSeconds = vc.value.duration.inSeconds;
        await vc.dispose();
      } catch (_) {}

      if (durationSeconds > 0 && durationSeconds < _minVideoDurationSeconds) {
        await file.delete();
        throw Exception(
          'Video terlalu pendek (${durationSeconds}s). Minimal $_minVideoDurationSeconds detik.',
        );
      }

      // 2. Output watermark di cache
      final tempDir = await getTemporaryDirectory();
      final wmOutputPath = '${tempDir.path}/wm_${DateTime.now().millisecondsSinceEpoch}.mp4';

      _safeSetState(() {
        _statusText = 'Menambahkan watermark...';
        _progress = 0.0;
      });

      // ============================================================
      // ✅ PERBAIKAN: Gunakan VideoWatermarkService
      // ============================================================
      final wmLocState = PodLocationService.instance.currentState;
      final wmResult = await VideoWatermarkService.addWatermark(
        inputPath: videoFile.path,
        outputPath: wmOutputPath,
        settings: settings,
        keepAudio: true,
        entry: ScanEntry(
          id: _storage.generateId(),
          type: ScanType.video,
          value: widget.barcode ?? 'video_${DateTime.now().millisecondsSinceEpoch}',
          timestamp: DateTime.now(),
          latitude: wmLocState.lat,
          longitude: wmLocState.lon,
          locationName: wmLocState.address.isNotEmpty ? wmLocState.address : null,
        ),
        onProgress: (p) {
          _safeSetState(() => _progress = p);
        },
      );

      if (wmResult == null && VideoWatermarkService.lastError != null) {
        debugPrint('🩺 Diagnosis watermark video: ${VideoWatermarkService.lastError}');
      }

      _safeSetState(() {
        _progress = 1.0;
        _statusText = wmResult != null ? 'Watermark selesai!' : 'Watermark gagal';
      });

      if (wmResult != null) {
        // 4. Watermark berhasil
        _safeSetState(() => _statusText = 'Menyimpan video...');
        final savedPath = await _storage.saveVideo(wmResult, name: widget.barcode);
        if (savedPath.isEmpty) throw Exception('Gagal menyimpan video watermark');
        finalPath = savedPath;

        thumbnailPath = await _generateThumbnail(savedPath);

        _safeSetState(() => _statusText = 'Ekspor ke Gallery...');
        galleryOk = await _saveToGallery(savedPath);

        if (galleryOk) {
          debugPrint('✅ Video berhasil diekspor ke gallery');
        } else {
          debugPrint('⚠️ Gagal ekspor ke gallery setelah percobaan, file tetap tersimpan di internal');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Video tersimpan di internal, gagal ekspor ke gallery'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }

        await file.delete();
        localCopyDeleted = await _maybeDeleteLocalCopy(savedPath, galleryOk);

        _safeSetState(() => _statusText = galleryOk
            ? (localCopyDeleted
                ? 'Video tersimpan di Galeri (lokal dihapus)'
                : 'Video tersimpan di internal & Gallery')
            : 'Video tersimpan di internal (gagal ekspor)');
      } else {
        // 5. Watermark gagal → simpan video mentah
        final diagnosis = VideoWatermarkService.lastError;
        debugPrint('❌ Watermark video gagal${diagnosis != null ? ': $diagnosis' : ''}');
        _showError(diagnosis != null
            ? 'Watermark gagal ($diagnosis). Video disimpan tanpa watermark.'
            : 'Watermark gagal. Video disimpan tanpa watermark.');

        _safeSetState(() => _statusText = 'Watermark gagal, menyimpan video mentah...');
        final savedPath = await _storage.saveVideo(videoFile.path, name: widget.barcode);
        if (savedPath.isEmpty) throw Exception('Gagal menyimpan video mentah');
        finalPath = savedPath;

        thumbnailPath = await _generateThumbnail(savedPath);
        if (await file.exists()) await file.delete();

        _safeSetState(() => _statusText = 'Ekspor ke Gallery...');
        galleryOk = await _saveToGallery(savedPath);
        localCopyDeleted = await _maybeDeleteLocalCopy(savedPath, galleryOk);

        _safeSetState(() => _statusText = galleryOk
            ? (localCopyDeleted
                ? 'Video tersimpan di Galeri (lokal dihapus)'
                : 'Video tersimpan (tanpa watermark) & Gallery')
            : 'Video tersimpan (tanpa watermark), gagal ekspor ke Gallery');
      }

      // 6. Simpan entry database
      if (finalPath == null) throw Exception('Gagal menyimpan video');

      final finalLocState = PodLocationService.instance.currentState;
      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.video,
        value: widget.barcode ?? 'video_${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        latitude: finalLocState.lat,
        longitude: finalLocState.lon,
        locationName: finalLocState.address.isNotEmpty ? finalLocState.address : null,
        videoPath: finalPath,
        videoDuration: durationSeconds,
        videoThumbnail: thumbnailPath,
        galleryExported: galleryOk,
        videoLocalDeleted: localCopyDeleted,
      );
      await _storage.add(entry);

      return entry;
    } catch (e) {
      debugPrint('❌ Error processing video: $e');
      _progress = 0.0;
      _safeSetState(() {});
      rethrow;
    } finally {
      try {
        final tempDir = await getTemporaryDirectory();
        final tempFiles = await tempDir.list().where((e) => e is File && e.path.contains('wm_')).toList();
        for (final f in tempFiles) {
          try { await File(f.path).delete(); } catch (_) {}
        }
      } catch (_) {}
      await FileHelper.deleteIfExists(videoFile.path);
    }
  }

  // ─── Helper ─────────────────────────────────────────────────
  Future<String?> _generateThumbnail(String videoPath) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: dir.path,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 200,
        quality: 75,
      );
    } catch (e) {
      debugPrint('Thumbnail error: $e');
      return null;
    }
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

      debugPrint('📤 Mengekspor video: $filePath (${fileSize ~/ 1024}KB)');

      const maxRetries = 2;
      for (int attempt = 0; attempt <= maxRetries; attempt++) {
        try {
          final filename = '${_entryFilenameBase(filePath)}_${DateTime.now().millisecondsSinceEpoch}.mp4';
          // ✅ PERBAIKAN: filePath: dan name:
          final result = await SaverGallery.saveFile(
            filePath: filePath,
            name: filename,
            androidRelativePath: 'Movies/TERMULScan',
          );
          if (result.isSuccess) {
            debugPrint('✅ Ekspor gallery berhasil: $filename');
            return true;
          }
          debugPrint('⚠️ Percobaan ${attempt + 1} gagal, retry...');
          if (attempt < maxRetries) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (!await file.exists()) {
              debugPrint('❌ File hilang saat retry: $filePath');
              break;
            }
          }
        } catch (e) {
          debugPrint('⚠️ Error ekspor (attempt ${attempt + 1}): $e');
          if (attempt == maxRetries) rethrow;
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      return false;
    } catch (e, stack) {
      debugPrint('❌ Error _saveToGallery: $e\n$stack');
      return false;
    }
  }

  String _entryFilenameBase(String path) {
    final base = path.split('/').last;
    return base.split('.').first;
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
        title: Text('Rekam Video ${widget.barcode ?? ""}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune, color: Colors.grey),
            tooltip: 'Gaya watermark video',
            onPressed: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: AppTheme.surface,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                builder: (_) => const WatermarkSettingsSheet(),
              );
            },
          ),
          if (_pendingTasks > 0)
            IconButton(
              icon: const Icon(Icons.cancel, color: AppTheme.error),
              onPressed: () {
                _taskQueue.cancelAllPending();
                setState(() {});
              },
              tooltip: 'Batalkan antrian',
            ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: AppTheme.accentOrange.withOpacity(0.1),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppTheme.accentOrange.withOpacity(0.4), width: 2),
                ),
                child: const Icon(Icons.videocam, size: 52, color: AppTheme.accentOrange),
              ),
              const Gap(24),
              Text('Rekam Video', style: Theme.of(context).textTheme.titleLarge),
              const Gap(8),
              Text('Maksimal 20 detik, akan diberi watermark otomatis',
                  style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
              const Gap(48),
              if (isProcessing) ...[
                LinearProgressIndicator(value: _progress.clamp(0.0, 1.0)),
                const Gap(8),
                Text(
                  '${(_progress * 100).toInt()}%',
                  style: const TextStyle(color: Colors.grey),
                ),
                const Gap(16),
              ],
              if (_statusText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_statusText, style: const TextStyle(color: Colors.grey)),
                ),
              if (_pendingTasks > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('$_pendingTasks video dalam antrian...', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ),
              if (_runningTasks > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('$_runningTasks video sedang diproses...', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ),
              ElevatedButton.icon(
                onPressed: (_isSaving || isProcessing) ? null : _pickAndRecord,
                icon: const Icon(Icons.videocam),
                label: const Text('Rekam Video'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentOrange,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
