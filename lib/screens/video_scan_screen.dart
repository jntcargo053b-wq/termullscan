// ============================================================
// lib/screens/video_scan_screen.dart (FINAL – STABLE IMAGE_PICKER VIDEO)
// ============================================================
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:path_provider/path_provider.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/video_watermark_service.dart';
import '../services/permission_service.dart';
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

  @override
  void initState() {
    super.initState();
    // Sebelumnya screen ini TIDAK pernah minta izin galeri sama sekali
    // (beda dengan photo_scan_screen.dart). Di Android 9 ke bawah tanpa
    // izin WRITE_EXTERNAL_STORAGE, SaverGallery.saveFile bisa gagal diam
    // -diam. Di Android 10+ scoped storage biasanya tidak butuh ini,
    // tapi memintanya di awal tidak merugikan dan menutup celah di
    // device lama.
    PermissionService.requestGalleryPermission();
  }

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

          setState(() => _statusText = 'Menyalin ke Gallery...');
          final galleryOk = await _saveToGallery(wmResult);
          debugPrint(galleryOk
              ? '✅ Video watermark tersalin ke Gallery'
              : '⚠️ Gagal menyalin video watermark ke Gallery');

          setState(() {
            _isWatermarking = false;
            _statusText = galleryOk
                ? 'Video tersimpan + watermark + Gallery'
                : 'Video tersimpan + watermark (gagal disalin ke Gallery)';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(galleryOk
                ? 'Video berhasil disimpan dengan watermark dan muncul di Gallery'
                : 'Video tersimpan dengan watermark, tapi gagal disalin ke Gallery')),
          );
          Navigator.pop(context, {'entry': updated});
        } else {
          final reason = VideoWatermarkService.lastError ?? 'tidak diketahui';
          debugPrint('🧾 Alasan watermark gagal: $reason');

          final galleryOk = await _saveToGallery(savedPath);
          debugPrint(galleryOk
              ? '✅ Video mentah tersalin ke Gallery'
              : '⚠️ Gagal menyalin video mentah ke Gallery');

          setState(() {
            _isWatermarking = false;
            _statusText = galleryOk
                ? 'Watermark gagal, video mentah disimpan + Gallery'
                : 'Watermark gagal, video mentah disimpan (gagal ke Gallery)';
          });
          if (mounted) {
            await showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Watermark gagal'),
                content: SingleChildScrollView(
                  child: Text(reason, style: const TextStyle(fontSize: 12)),
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: reason));
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('Disalin ke clipboard')),
                        );
                      }
                    },
                    child: const Text('Salin'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Tutup'),
                  ),
                ],
              ),
            );
          }
          if (mounted) Navigator.pop(context, {'entry': entry});
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

  // Video watermark disimpan di storage privat aplikasi
  // (app_flutter/videos/), yang TIDAK pernah di-scan MediaStore —
  // makanya tidak pernah muncul di Gallery meski file-nya sudah ada
  // dan valid. Ini menyalin/mendaftarkan file itu ke MediaStore lewat
  // saver_gallery, persis seperti yang sudah dipakai untuk foto di
  // photo_scan_screen.dart.
  Future<bool> _saveToGallery(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;

      // Nama file asli biasanya "<uuid>.mp4.wm.mp4" (hasil watermark)
      // — kasih ekstensi .mp4 yang bersih supaya Gallery/aplikasi lain
      // mengenali MIME type video dengan benar.
      final String filename =
          '${entryFilenameBase(filePath)}_${DateTime.now().millisecondsSinceEpoch}.mp4';

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

  String entryFilenameBase(String path) {
    final base = path.split('/').last;
    // buang ekstensi ganda seperti ".mp4.wm.mp4" -> nama dasar saja
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
