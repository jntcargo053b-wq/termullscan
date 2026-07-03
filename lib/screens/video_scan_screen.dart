// ============================================================
// lib/screens/video_scan_screen.dart (FINAL – TANPA DUPLIKASI)
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
  bool _isSaving = false;
  bool _isWatermarking = false;
  String _statusText = '';

  Timer? _progressTimer;
  int _progressDotCount = 0;

  static const int _maxVideoSizeBytes = 50 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    PermissionService.requestGalleryPermission();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  void _startProgressAnimation(String baseMessage) {
    _progressDotCount = 0;
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted || !_isWatermarking) {
        timer.cancel();
        return;
      }
      _progressDotCount = (_progressDotCount + 1) % 4;
      setState(() {
        _statusText = '$baseMessage${List.filled(_progressDotCount, '.').join()}';
      });
    });
  }

  void _stopProgressAnimation() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

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

  Future<void> _pickAndRecord() async {
    if (_isSaving || _isWatermarking) return;
    if (!await _ensureCameraPermission()) return;

    setState(() => _statusText = 'Membuka kamera...');
    try {
      final XFile? videoFile = await _picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(seconds: 20),
        preferredCameraDevice: CameraDevice.rear,
      );
      if (!mounted) return;
      if (videoFile == null) {
        setState(() => _statusText = 'Dibatalkan');
        return;
      }
      await _processVideo(videoFile);
    } catch (e) {
      debugPrint('❌ Gagal merekam video: $e');
      if (mounted) {
        setState(() => _statusText = 'Gagal merekam');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal merekam: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Alur baru: temp kamera → watermark (temp) → galeri → hapus temp
  Future<void> _processVideo(XFile videoFile) async {
    if (!mounted) return;
    setState(() { _isSaving = true; _statusText = 'Memproses video...'; });

    String? finalPath;
    String? thumbnailPath;
    int durationSeconds = 0;

    try {
      final file = File(videoFile.path);
      if (!await file.exists()) throw Exception('File video tidak ditemukan');

      final fileSize = await file.length();
      if (fileSize > _maxVideoSizeBytes) {
        await file.delete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video terlalu besar. Maks 50 MB.'), backgroundColor: Colors.red),
          );
          setState(() => _isSaving = false);
        }
        return;
      }

      // 1. Dapatkan durasi video (dari file mentah)
      try {
        final vc = VideoPlayerController.file(file);
        await vc.initialize();
        durationSeconds = vc.value.duration.inSeconds;
        await vc.dispose();
      } catch (_) {}

      // 2. Buat output watermark di cache (temp)
      final tempDir = await getTemporaryDirectory();
      final wmOutputPath = '${tempDir.path}/wm_${DateTime.now().millisecondsSinceEpoch}.mp4';

      setState(() {
        _isSaving = false;
        _isWatermarking = true;
        _statusText = 'Menambahkan watermark';
      });
      _startProgressAnimation('Menambahkan watermark');

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

      _stopProgressAnimation();

      if (!mounted) return;

      if (wmResult != null) {
        // 4. Watermark berhasil → generate thumbnail dari hasil watermark
        final thumbRaw = await _generateThumbnail(wmResult);
        thumbnailPath = thumbRaw;

        // 5. Ekspor ke galeri (SATU-SATUNYA file final)
        setState(() => _statusText = 'Menyimpan ke Gallery...');
        final galleryPath = await _saveToGalleryAndGetPath(wmResult);

        if (galleryPath != null) {
          // Sukses ekspor: hapus file temp (video mentah + watermark)
          await file.delete();
          await File(wmResult).delete();

          finalPath = galleryPath; // gunakan path galeri
          setState(() => _statusText = 'Video tersimpan di Gallery');
        } else {
          // Gagal ekspor: simpan watermark ke internal sebagai fallback
          final savedPath = await _storage.saveVideo(wmResult, name: widget.barcode);
          if (savedPath.isNotEmpty) {
            finalPath = savedPath;
            await file.delete(); // tetap hapus video mentah
          } else {
            throw Exception('Gagal menyimpan video (gallery & internal)');
          }
          setState(() => _statusText = 'Video tersimpan di internal (gagal ekspor)');
        }
      } else {
        // 6. Watermark gagal → simpan video mentah ke internal
        setState(() => _statusText = 'Watermark gagal, menyimpan video mentah...');
        final savedPath = await _storage.saveVideo(videoFile.path, name: widget.barcode);
        if (savedPath.isEmpty) throw Exception('Gagal menyimpan video mentah');
        finalPath = savedPath;

        // Generate thumbnail dari video mentah
        thumbnailPath = await _generateThumbnail(savedPath);

        // Hapus file temp (videoFile.path sudah di-cache, tapi _storage.saveVideo menggunakan rename, jadi file sudah dipindahkan)
        // Jika masih ada, hapus
        if (await file.exists()) await file.delete();

        setState(() => _statusText = 'Video tersimpan (tanpa watermark)');
      }

      // 7. Simpan entry ke database
      if (finalPath != null) {
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

        if (mounted) {
          setState(() {
            _isWatermarking = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('✅ Video tersimpan: ${entry.value}'), backgroundColor: Colors.green),
          );
          Navigator.pop(context, {'entry': entry});
        }
      }
    } catch (e, stack) {
      _stopProgressAnimation();
      debugPrint('❌ Error processing video: $e\n$stack');
      if (mounted) {
        setState(() {
          _isSaving = false;
          _isWatermarking = false;
          _statusText = 'Gagal memproses';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      // Pastikan semua file temp dihapus
      try {
        final tempDir = await getTemporaryDirectory();
        final tempFiles = await tempDir.list().where((e) => e is File && e.path.contains('wm_')).toList();
        for (final f in tempFiles) {
          try { await File(f.path).delete(); } catch (_) {}
        }
      } catch (_) {}
    }
  }

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

  /// Ekspor ke galeri dan kembalikan path file yang disimpan (atau null jika gagal)
  Future<String?> _saveToGalleryAndGetPath(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final String filename = '${_entryFilenameBase(filePath)}_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final result = await SaverGallery.saveFile(
        file: filePath,
        name: filename,
        androidRelativePath: 'Movies/TERMULScan',
        androidExistNotSave: false,
      );

      if (result.isSuccess && result.filePath != null) {
        return result.filePath;
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error _saveToGalleryAndGetPath: $e');
      return null;
    }
  }

  String _entryFilenameBase(String path) {
    final base = path.split('/').last;
    return base.split('.').first;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: Text('Rekam Video ${widget.barcode ?? ""}')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120, height: 120,
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
              if (_isWatermarking) ...[
                const LinearProgressIndicator(),
                const Gap(16),
              ],
              if (_statusText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_statusText, style: const TextStyle(color: Colors.grey)),
                ),
              ElevatedButton.icon(
                onPressed: (_isSaving || _isWatermarking) ? null : _pickAndRecord,
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
