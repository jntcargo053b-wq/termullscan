// ============================================================
// lib/screens/video_scan_screen.dart (FINAL – TASKQUEUE + TANPA DUPLIKASI)
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
import '../services/video_watermark_service.dart';
import '../services/permission_service.dart';
import '../services/task_queue.dart';
import '../watermark/watermark_settings.dart';
import '../theme/app_theme.dart';
import '../utils/file_helper.dart';

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
  final TaskQueue _taskQueue = TaskQueue(maxWorkers: 1); // video lebih berat, cukup 1 worker
  int _pendingTasks = 0;
  int _runningTasks = 0;

  bool _isSaving = false;
  bool _isProcessing = false; // untuk tombol disabled
  String _statusText = '';

  static const int _maxVideoSizeBytes = 50 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    PermissionService.requestGalleryPermission();
    // Subscribe ke status stream TaskQueue
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

      // Tambahkan ke TaskQueue, langsung kembali tanpa menunggu
      _taskQueue.add(
        label: 'Video ${widget.barcode ?? ''}',
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

  /// Proses video dan mengembalikan [ScanEntry] yang sudah tersimpan.
  Future<ScanEntry> _processVideo(XFile videoFile) async {
    String? finalPath;
    String? thumbnailPath;
    int durationSeconds = 0;

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

      // 2. Output watermark di cache
      final tempDir = await getTemporaryDirectory();
      final wmOutputPath = '${tempDir.path}/wm_${DateTime.now().millisecondsSinceEpoch}.mp4';

      // Update status (melalui stream, tidak langsung)
      setState(() {
        _statusText = 'Menambahkan watermark...';
      });

      // 3. Proses watermark
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
      );

      if (wmResult != null) {
        // 4. Watermark berhasil → simpan ke internal (rename)
        setState(() => _statusText = 'Menyimpan video...');
        final savedPath = await _storage.saveVideo(wmResult, name: widget.barcode);
        if (savedPath.isEmpty) throw Exception('Gagal menyimpan video watermark');
        finalPath = savedPath;

        // 5. Thumbnail
        thumbnailPath = await _generateThumbnail(savedPath);

        // 6. Ekspor ke gallery
        setState(() => _statusText = 'Ekspor ke Gallery...');
        final galleryOk = await _saveToGallery(savedPath);
        if (!galleryOk) {
          debugPrint('⚠️ Gagal ekspor ke gallery, file tetap tersimpan di internal');
        }

        // 7. Hapus video mentah
        await file.delete();

        setState(() => _statusText = galleryOk
            ? 'Video tersimpan di internal & Gallery'
            : 'Video tersimpan di internal (gagal ekspor)');
      } else {
        // 8. Watermark gagal → simpan video mentah
        setState(() => _statusText = 'Watermark gagal, menyimpan video mentah...');
        final savedPath = await _storage.saveVideo(videoFile.path, name: widget.barcode);
        if (savedPath.isEmpty) throw Exception('Gagal menyimpan video mentah');
        finalPath = savedPath;

        thumbnailPath = await _generateThumbnail(savedPath);

        if (await file.exists()) await file.delete();

        setState(() => _statusText = 'Video tersimpan (tanpa watermark)');
      }

      // 9. Simpan entry database
      if (finalPath == null) throw Exception('Gagal menyimpan video');

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.video,
        value: widget.barcode ?? 'video_${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        videoPath: finalPath,
        videoDuration: durationSeconds,
        videoThumbnail: thumbnailPath,
      );
      await _storage.add(entry);

      return entry;
    } catch (e) {
      debugPrint('❌ Error processing video: $e');
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

  Future<bool> _saveToGallery(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;

      final String filename = '${_entryFilenameBase(filePath)}_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final result = await SaverGallery.saveFile(
        file: filePath,
        name: filename,
        androidRelativePath: 'Movies/TERMULScan',
        androidExistNotSave: false,
      );
      return result.isSuccess;
    } catch (e) {
      debugPrint('❌ Error _saveToGallery: $e');
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
                const LinearProgressIndicator(),
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
