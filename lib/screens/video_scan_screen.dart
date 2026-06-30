// ============================================================
// lib/screens/video_scan_screen.dart (FINAL – STABLE IMAGE_PICKER VIDEO)
// ============================================================
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:path_provider/path_provider.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/video_watermark_service.dart';
import '../watermark/watermark_settings.dart';
import '../theme/app_theme.dart';

class VideoScanScreen extends StatefulWidget {
  final String? barcode;
  final bool batchMode;
  final String? entryId;

  const VideoScanScreen({
    super.key,
    this.barcode,
    this.batchMode = false,
    this.entryId,
  });

  @override
  State<VideoScanScreen> createState() => _VideoScanScreenState();
}

class _VideoScanScreenState extends State<VideoScanScreen> {
  final ImagePicker _picker = ImagePicker();
  final StorageService _storage = StorageService();
  bool _isSaving = false;
  bool _isWatermarking = false;
  String _statusText = '';

  static const int _maxVideoSizeBytes = 50 * 1024 * 1024;

  Future<void> _pickAndRecord() async {
    if (_isSaving || _isWatermarking) return;

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
    setState(() {
      _isSaving = true;
      _statusText = 'Menyimpan video...';
    });

    try {
      final file = File(videoFile.path);
      if (!await file.exists()) {
        throw Exception('File video tidak ditemukan');
      }

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

      // Simpan video mentah
      final savedPath = await _storage.saveVideo(videoFile.path, name: widget.barcode);
      if (savedPath.isEmpty) throw Exception('Gagal menyimpan video');

      // Generate thumbnail
      final thumb = await _generateThumbnail(savedPath);

      // Entry awal
      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.video,
        value: widget.barcode ?? 'video_${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        videoPath: savedPath,
        videoDuration: 0, // tidak diketahui durasi pastinya
        videoThumbnail: thumb,
      );
      await _storage.add(entry);

      // Watermark di background
      if (mounted) {
        setState(() {
          _isSaving = false;
          _isWatermarking = true;
          _statusText = 'Menambahkan watermark...';
        });
      }

      final wmPath = '$savedPath.wm.mp4';
      final wmResult = await VideoWatermarkService.addWatermark(
        inputPath: savedPath,
        outputPath: wmPath,
        entry: entry,
        settings: WatermarkSettings(),
      );

      if (mounted) {
        if (wmResult != null) {
          await File(savedPath).delete();
          final updated = entry.copyWith(videoPath: wmResult, videoThumbnail: thumb);
          await _storage.update(updated);
          setState(() {
            _isWatermarking = false;
            _statusText = 'Video tersimpan + watermark';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video berhasil disimpan dengan watermark')),
          );
          Navigator.pop(context, {'entry': updated});
        } else {
          setState(() {
            _isWatermarking = false;
            _statusText = 'Watermark gagal, video mentah disimpan';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Watermark gagal, video mentah disimpan')),
          );
          Navigator.pop(context, {'entry': entry});
        }
      }
    } catch (e, stack) {
      debugPrint('❌ Save video error: $e\n$stack');
      if (mounted) {
        setState(() {
          _isSaving = false;
          _statusText = 'Gagal menyimpan';
        });
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
                child: const Icon(Icons.videocam, size: 52, color: AppTheme.accentOrange),
              ),
              const Gap(24),
              Text(
                'Rekam Video',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Gap(8),
              Text(
                'Maksimal 20 detik, akan diberi watermark otomatis',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const Gap(48),
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
