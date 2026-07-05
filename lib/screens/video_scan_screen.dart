// ============================================================
// lib/screens/video_scan_screen.dart (FINAL – PREVIEW + PROGRESS + RETRY + GALLERY FIX)
// ============================================================
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
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/watermark/watermark_service.dart';
import '../services/permission_service.dart';
import '../services/task_queue.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/watermark_style.dart';
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

  // ─── TaskQueue ──────────────────────────────────────────────
  final TaskQueue _taskQueue = TaskQueue(maxWorkers: 1);
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
    _taskQueue.statusStream.listen((task) {
      if (!mounted) return;
      setState(() {
        _pendingTasks = _taskQueue.pendingCount;
        _runningTasks = _taskQueue.runningCount;
        _isProcessing = _pendingTasks > 0 || _runningTasks > 0;
      });
    });
  }

  @override
  void dispose() {
    _taskQueue.dispose();
    super.dispose();
  }

  /// setState yang aman dipanggil dari task background (_processVideo),
  /// yang bisa saja masih berjalan setelah widget ini sudah di-dispose
  /// (mis. user menekan tombol back sebelum proses watermark selesai).
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

      // ─── Tampilkan Preview ────────────────────────────────
      final previewResult = await _showPreview(videoFile, MediaType.video);
      if (previewResult == 'save') {
        _taskQueue.add(
          label: 'Video ${widget.barcode ?? ''}',
          priority: TaskPriority.high,
          maxRetries: 2,
          work: () => _processVideo(videoFile),
          onSuccess: (entry) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('✅ Video tersimpan: ${(entry as ScanEntry).value}'),
                  backgroundColor: Colors.green,
                ),
              );
              Navigator.pop(context, {'entry': entry});
            }
          },
          onError: (error) {
            if (mounted) {
              _showError('Gagal memproses video: $error');
            }
          },
        );
        setState(() {
          _isSaving = false;
          _statusText = 'Video direkam, memproses di background...';
        });
      } else {
        // Retake → hapus file
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
          SnackBar(content: Text('Gagal merekam: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ─── Core Processing ────────────────────────────────────────

  Future<ScanEntry> _processVideo(XFile videoFile) async {
    String? finalPath;
    String? thumbnailPath;
    int durationSeconds = 0;
    bool galleryOk = false;

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

      // 1b. Tolak video yang terlalu pendek
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

      // 3. Proses watermark dengan callback progress
      final wmResult = await VideoWatermarkService.addWatermark(
        inputPath: videoFile.path,
        outputPath: wmOutputPath,
        entry: ScanEntry(
          id: _storage.generateId(),
          type: ScanType.video,
          value: widget.barcode ?? 'video_${DateTime.now().millisecondsSinceEpoch}',
          timestamp: DateTime.now(),
        ),
        settings: WatermarkSettings(),
        onProgress: (progress) {
          _safeSetState(() {
            _progress = progress;
            _statusText = 'Menambahkan watermark... ${(progress * 100).toInt()}%';
          });
        },
      );

      // Reset progress setelah selesai (sukses atau gagal)
      _progress = 0.0;
      _safeSetState(() {});

      if (wmResult != null) {
        // 4. Watermark berhasil → simpan ke internal (rename)
        _safeSetState(() => _statusText = 'Menyimpan video...');
        final savedPath = await _storage.saveVideo(wmResult, name: widget.barcode);
        if (savedPath.isEmpty) throw Exception('Gagal menyimpan video watermark');
        finalPath = savedPath;

        // 5. Thumbnail
        thumbnailPath = await _generateThumbnail(savedPath);

        // 6. Ekspor ke gallery dengan retry (3 kali) + verifikasi file
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

        // 7. Hapus video mentah
        await file.delete();

        _safeSetState(() => _statusText = galleryOk
            ? 'Video tersimpan di internal & Gallery'
            : 'Video tersimpan di internal (gagal ekspor)');
      } else {
        // 8. Watermark gagal → simpan video mentah
        _safeSetState(() => _statusText = 'Watermark gagal, menyimpan video mentah...');
        final savedPath = await _storage.saveVideo(videoFile.path, name: widget.barcode);
        if (savedPath.isEmpty) throw Exception('Gagal menyimpan video mentah');
        finalPath = savedPath;

        thumbnailPath = await _generateThumbnail(savedPath);
        if (await file.exists()) await file.delete();

        // ✅ FIX: sebelumnya ekspor ke gallery HANYA terjadi jika watermark
        // berhasil. Kalau watermark gagal, video mentah tersimpan di
        // internal tapi tidak pernah sampai ke Gallery. Sekarang tetap
        // dicoba diekspor supaya user selalu punya salinan di Gallery.
        _safeSetState(() => _statusText = 'Ekspor ke Gallery...');
        galleryOk = await _saveToGallery(savedPath);

        _safeSetState(() => _statusText = galleryOk
            ? 'Video tersimpan (tanpa watermark) & Gallery'
            : 'Video tersimpan (tanpa watermark), gagal ekspor ke Gallery');
      }

      // 9. Simpan entry database (termasuk status gallery)
      if (finalPath == null) throw Exception('Gagal menyimpan video');

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.video,
        value: widget.barcode ?? 'video_${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        videoPath: finalPath,
        videoDuration: durationSeconds,
        videoThumbnail: thumbnailPath,
        galleryExported: galleryOk,
      );
      await _storage.add(entry);

      return entry;
    } catch (e) {
      debugPrint('❌ Error processing video: $e');
      // Reset progress jika error
      _progress = 0.0;
      _safeSetState(() {});
      rethrow;
    } finally {
      // Bersihkan file temp
      try {
        final tempDir = await getTemporaryDirectory();
        final tempFiles = await tempDir.list().where((e) => e is File && e.path.contains('wm_')).toList();
        for (final f in tempFiles) {
          try { await File(f.path).delete(); } catch (_) {}
        }
      } catch (_) {}
      // Hapus video mentah jika masih ada (fallback)
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

  // ─── ✅ PERBAIKAN: _saveToGallery dengan verifikasi & retry ──
  Future<bool> _saveToGallery(String filePath) async {
    try {
      // ─── 1. Verifikasi keberadaan file ──────────────────────
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

      // ─── 2. Retry ekspor (2 kali percobaan) ──────────────
      const maxRetries = 2;
      for (int attempt = 0; attempt <= maxRetries; attempt++) {
        try {
          final filename = '${_entryFilenameBase(filePath)}_${DateTime.now().millisecondsSinceEpoch}.mp4';
          final result = await SaverGallery.saveFile(
            file: filePath,
            name: filename,
            androidRelativePath: 'Movies/TERMULScan',
            androidExistNotSave: false,
          );
          if (result.isSuccess) {
            debugPrint('✅ Ekspor gallery berhasil: $filename');
            return true;
          }
          debugPrint('⚠️ Percobaan ${attempt + 1} gagal, retry...');
          if (attempt < maxRetries) {
            await Future.delayed(const Duration(milliseconds: 500));
            // Cek ulang keberadaan file
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
                backgroundColor: const Color(0xFF1E1E1E),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                builder: (_) => const WatermarkSettingsSheet(videoMode: true),
              );
            },
          ),
          if (_pendingTasks > 0)
            IconButton(
              icon: const Icon(Icons.cancel, color: Colors.red),
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
