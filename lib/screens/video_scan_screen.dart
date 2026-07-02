// ============================================================
// lib/screens/video_scan_screen.dart (FINAL – PROGRESS INDICATOR)
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

  // ✅ Timer untuk update teks progress
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

  // ✅ Mulai timer progress (berjalan selama watermarking)
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
      await _saveVideo(videoFile);
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

  Future<void> _saveVideo(XFile videoFile) async {
    if (!mounted) return;
    setState(() { _isSaving = true; _statusText = 'Menyimpan video...'; });

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

      final savedPath = await _storage.saveVideo(videoFile.path, name: widget.barcode);
      if (savedPath.isEmpty) throw Exception('Gagal menyimpan video');

      int actualDuration = 0;
      try {
        final vc = VideoPlayerController.file(File(savedPath));
        await vc.initialize();
        actualDuration = vc.value.duration.inSeconds;
        await vc.dispose();
      } catch (_) {}

      final thumbRaw = await _generateThumbnail(savedPath);

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.video,
        value: widget.barcode ?? 'video_${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        videoPath: savedPath,
        videoDuration: actualDuration,
        videoThumbnail: thumbRaw,
      );
      await _storage.add(entry);

      if (mounted) {
        setState(() {
          _isSaving = false;
          _isWatermarking = true;
        });
        // ✅ Mulai animasi progress
        _startProgressAnimation('Menambahkan watermark');
      }

      final wmPath = '$savedPath.wm.mp4';
      final wmResult = await VideoWatermarkService.addWatermark(
        inputPath: savedPath,
        outputPath: wmPath,
        entry: entry,
        settings: WatermarkSettings(),
      );

      _stopProgressAnimation(); // ✅ Hentikan animasi

      if (mounted) {
        if (wmResult != null) {
          final thumbWm = await _generateThumbnail(wmResult) ?? thumbRaw;
          await File(savedPath).delete();
          final updated = entry.copyWith(videoPath: wmResult, videoThumbnail: thumbWm);
          await _storage.update(updated);

          setState(() => _statusText = 'Menyalin ke Gallery...');
          final galleryOk = await _saveToGallery(wmResult);
          setState(() {
            _isWatermarking = false;
            _statusText = galleryOk
                ? 'Video tersimpan + watermark + Gallery'
                : 'Video tersimpan + watermark';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(galleryOk
                ? 'Video berhasil disimpan dengan watermark dan muncul di Gallery'
                : 'Video tersimpan dengan watermark, tapi gagal disalin ke Gallery')),
          );
          Navigator.pop(context, {'entry': updated});
        } else {
          try { await File(wmPath).delete(); } catch (_) {}

          final reason = VideoWatermarkService.lastError ?? 'tidak diketahui';
          debugPrint('🧾 Alasan watermark gagal: $reason');

          final galleryOk = await _saveToGallery(savedPath);
          setState(() {
            _isWatermarking = false;
            _statusText = galleryOk
                ? 'Watermark gagal, video mentah disimpan + Gallery'
                : 'Watermark gagal, video mentah disimpan';
          });
          if (mounted) {
            await showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Watermark gagal'),
                content: SingleChildScrollView(child: Text(reason, style: const TextStyle(fontSize: 12))),
                actions: [
                  TextButton(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: reason));
                      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Disalin ke clipboard')));
                    },
                    child: const Text('Salin'),
                  ),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
                ],
              ),
            );
          }
          if (mounted) Navigator.pop(context, {'entry': entry});
        }
      }
    } catch (e, stack) {
      _stopProgressAnimation();
      debugPrint('❌ Save video error: $e\n$stack');
      if (mounted) {
        setState(() { _isSaving = false; _statusText = 'Gagal menyimpan'; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan video: $e'), backgroundColor: Colors.red),
        );
      }
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
      debugPrint('❌ Error _saveToGallery (video): $e');
      return false;
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
              // ✅ Tampilkan progress indicator saat watermarking
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
