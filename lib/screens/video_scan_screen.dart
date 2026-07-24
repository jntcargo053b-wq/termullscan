// ============================================================
// lib/screens/video_scan_screen.dart (FIXED)
// ============================================================
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saver_gallery/saver_gallery.dart';
import '../models/scan_entry.dart';
import '../services/storage_service.dart';
import '../services/permission_service.dart';
import '../services/pod_location_service.dart';
import '../theme/app_theme.dart';
import '../watermark/watermark_settings.dart';
import '../watermark/video_watermark_service.dart';
import 'watermark_settings_sheet.dart';
import 'preview_screen.dart';

class VideoScanScreen extends StatefulWidget {
  final String? barcode;
  final String? entryId;
  const VideoScanScreen({super.key, this.barcode, this.entryId});

  @override
  State<VideoScanScreen> createState() => _VideoScanScreenState();
}

class _VideoScanScreenState extends State<VideoScanScreen> {
  final StorageService _storage = StorageService();
  final WatermarkSettings _wmSettings = WatermarkSettings();
  final ImagePicker _picker = ImagePicker();

  bool _isRecording = false;
  bool _isProcessing = false;
  String? _videoPath;
  int? _videoDuration;
  String? _thumbnailPath;
  bool _hasGalleryPermission = false;

  // ─── LIFECYCLE ──────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    if (_wmSettings.gpsWatermarkEnabled) {
      unawaited(PodLocationService.instance.acquireForCapture());
    }
  }

  @override
  void dispose() {
    if (_wmSettings.gpsWatermarkEnabled) {
      PodLocationService.instance.releaseAfterCapture();
    }
    super.dispose();
  }

  // ─── PERMISSIONS ────────────────────────────────────────────

  Future<void> _requestPermissions() async {
    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      final result = await Permission.camera.request();
      if (!mounted) return;
      if (!result.isGranted) {
        if (result.isPermanentlyDenied) {
          _showPermissionDeniedDialog(
            'Izin Kamera',
            'Aplikasi membutuhkan kamera untuk merekam video.',
          );
        }
        return;
      }
    }

    // 🔥 FIX: gunakan await untuk mendapatkan bool
    final storageGranted = await Permission.storage.isGranted;
    final manageGranted = await Permission.manageExternalStorage.isGranted;

    if (!storageGranted && !manageGranted) {
      final storageResult = await Permission.storage.request();
      final manageResult = await Permission.manageExternalStorage.request();
      if (mounted) {
        setState(() {
          _hasGalleryPermission = storageResult.isGranted || manageResult.isGranted;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _hasGalleryPermission = storageGranted || manageGranted;
        });
      }
    }
  }

  void _showPermissionDeniedDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('Buka Pengaturan'),
          ),
        ],
      ),
    );
  }

  // ─── RECORD VIDEO ───────────────────────────────────────────

  Future<void> _recordVideo() async {
    if (_isRecording || _isProcessing) return;

    try {
      setState(() {
        _isRecording = true;
        _isProcessing = true;
      });

      final xfile = await _picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(minutes: 5),
      );

      if (!mounted) {
        setState(() => _isProcessing = false);
        return;
      }

      if (xfile != null) {
        final savedPath = await _saveVideo(xfile.path);
        if (savedPath != null) {
          setState(() {
            _videoPath = savedPath;
            _isRecording = false;
          });
          await _processVideo(savedPath);
        } else {
          setState(() => _isProcessing = false);
        }
      } else {
        setState(() => _isProcessing = false);
      }
    } catch (e) {
      debugPrint('❌ Error recording video: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal merekam video: $e')),
        );
      }
    }
  }

  // ─── PICK FROM GALLERY ─────────────────────────────────────

  Future<void> _pickFromGallery() async {
    if (_isProcessing) return;

    try {
      setState(() => _isProcessing = true);

      final xfile = await _picker.pickVideo(
        source: ImageSource.gallery,
      );

      if (!mounted) {
        setState(() => _isProcessing = false);
        return;
      }

      if (xfile != null) {
        final savedPath = await _saveVideo(xfile.path);
        if (savedPath != null) {
          setState(() {
            _videoPath = savedPath;
          });
          await _processVideo(savedPath);
        } else {
          setState(() => _isProcessing = false);
        }
      } else {
        setState(() => _isProcessing = false);
      }
    } catch (e) {
      debugPrint('❌ Error picking video: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal memilih video: $e')),
        );
      }
    }
  }

  // ─── SAVE VIDEO ─────────────────────────────────────────────

  Future<String?> _saveVideo(String sourcePath) async {
    try {
      final file = File(sourcePath);
      if (!await file.exists()) {
        throw Exception('File video tidak ditemukan');
      }

      final size = await file.length();
      if (size == 0) {
        throw Exception('File video kosong');
      }

      final name = widget.barcode ?? 'video_${DateTime.now().millisecondsSinceEpoch}';
      final savedPath = await _storage.saveVideo(sourcePath, name: name);

      debugPrint('✅ Video saved: $savedPath');
      return savedPath;
    } catch (e) {
      debugPrint('❌ Error saving video: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan video: $e')),
        );
      }
      return null;
    }
  }

  // ─── PROCESS VIDEO ──────────────────────────────────────────

  Future<void> _processVideo(String videoPath) async {
    try {
      setState(() => _isProcessing = true);

      // Dapatkan durasi
      final duration = await _getVideoDuration(videoPath);
      if (duration != null) {
        setState(() => _videoDuration = duration);
      }

      // Buat thumbnail
      final thumbnailPath = await _generateThumbnail(videoPath);
      if (thumbnailPath != null) {
        setState(() => _thumbnailPath = thumbnailPath);
      }

      // Simpan ke gallery
      if (_hasGalleryPermission) {
        final saved = await SaverGallery.saveFile(
          filePath: videoPath,
          fileName: videoPath.split('/').last,
          androidRelativePath: 'Movies/TERMULScan',
          skipIfExists: false,
        );
        if (saved.isSuccess) {
          debugPrint('✅ Video saved to gallery');
        }
      }

      // ─── GABUNGKAN KE SCAN ENTRY ─────────────────────────────
      // Jika video ini hasil dari alur "Rekam Video" setelah scan
      // barcode, entryId sudah ada → video digabung ke record yang
      // sama (satu paket bukti pengiriman: barcode + foto + video +
      // GPS + timestamp), bukan jadi record terpisah.
      //
      // ✅ FIX RACE CONDITION ALAMAT: dulu pakai `.currentState`
      // (snapshot instan). Karena reverse-geocoding adalah panggilan
      // jaringan (Nominatim/Photon/Android Geocoder) yang bisa makan
      // beberapa detik, watermark video sering sudah "dibakar" ke
      // pixel duluan sebelum alamat siap — hasilnya cuma koordinat
      // yang tampil, walau `_attachLocationUpdate()` di bawah nanti
      // berhasil dapat alamat (tapi sudah terlambat untuk video yang
      // sudah jadi file). Untuk aplikasi POD, alamat adalah bagian
      // penting dari bukti pengiriman, jadi di sini kita tunggu dulu
      // (dengan timeout wajar) sebelum entry final dibuat & video
      // di-watermark.
      //
      // ✅ FIX #2: timeout di sini sempat cuma 6 detik walau
      // `_attachLocationUpdate()` di bawah (dan barcode_scan_screen)
      // sudah pakai 10 detik — inkonsistensi ini yang bikin gejala di
      // atas ("hasilnya cuma koordinat") masih sering muncul walau
      // sudah menunggu. Disamakan ke 10 detik.
      final locState = _wmSettings.gpsWatermarkEnabled
          ? await PodLocationService.instance.awaitAddressReady(
              timeout: const Duration(seconds: 10),
            )
          : null;

      ScanEntry entry;
      final existingEntry = widget.entryId != null
          ? await _storage.getEntry(widget.entryId!)
          : null;

      if (existingEntry != null) {
        entry = existingEntry.copyWith(
          videoPath: videoPath,
          videoDuration: duration,
          latitude: locState?.lat ?? existingEntry.latitude,
          longitude: locState?.lon ?? existingEntry.longitude,
          locationName: (locState != null && locState.address.isNotEmpty)
              ? locState.address
              : existingEntry.locationName,
        );
        await _storage.update(entry);
      } else {
        entry = ScanEntry(
          id: _storage.generateId(),
          value: widget.barcode ?? 'VIDEO_${DateTime.now().millisecondsSinceEpoch}',
          type: ScanType.video,
          videoPath: videoPath,
          timestamp: DateTime.now(),
          operatorName: _wmSettings.operatorName.isNotEmpty
              ? _wmSettings.operatorName
              : 'Operator',
          companyName: _wmSettings.companyName,
          latitude: locState?.lat,
          longitude: locState?.lon,
          locationName: (locState != null && locState.address.isNotEmpty)
              ? locState.address
              : null,
          videoDuration: duration,
          isManual: false,
        );
        await _storage.add(entry);
      }

      // Safety-net: kalau timeout di atas terlampaui & alamat masih
      // belum siap, tetap coba update record (bukan watermark video
      // yang sudah jadi, tapi minimal data di riwayat/gallery benar).
      if (_wmSettings.gpsWatermarkEnabled) {
        unawaited(_attachLocationUpdate(entry.id));
      }

      // Render watermark ke video
      await _renderWatermark(videoPath, entry);

      if (!mounted) return;

      // Tampilkan preview
      final result = await _showPreview(videoPath);

      if (result == 'save') {
        setState(() => _isProcessing = false);
        Navigator.pop(context, {'path': videoPath, 'duration': duration});
      } else if (result == 'retake') {
        try {
          final file = File(videoPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
        setState(() {
          _videoPath = null;
          _videoDuration = null;
          _thumbnailPath = null;
          _isProcessing = false;
        });
      } else {
        setState(() => _isProcessing = false);
      }
    } catch (e) {
      debugPrint('❌ Error processing video: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal memproses video: $e')),
        );
      }
    }
  }

  // ─── GET VIDEO DURATION ─────────────────────────────────────

  Future<int?> _getVideoDuration(String videoPath) async {
    try {
      final file = File(videoPath);
      if (!await file.exists()) return null;

      // Gunakan FFmpeg untuk mendapatkan durasi
      final result = await Process.run(
        'ffprobe',
        [
          '-v',
          'error',
          '-show_entries',
          'format=duration',
          '-of',
          'default=noprint_wrappers=1:nokey=1',
          videoPath,
        ],
      );

      if (result.exitCode == 0) {
        final durationStr = result.stdout.toString().trim();
        if (durationStr.isNotEmpty) {
          return (double.tryParse(durationStr)?.ceil()) ?? null;
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error getting video duration: $e');
    }
    return null;
  }

  // ─── GENERATE THUMBNAIL ─────────────────────────────────────

  Future<String?> _generateThumbnail(String videoPath) async {
    try {
      final dir = File(videoPath).parent.path;
      final baseName = videoPath.split('/').last.split('.').first;
      final thumbPath = '$dir/${baseName}_thumb.jpg';

      final result = await Process.run(
        'ffmpeg',
        [
          '-i',
          videoPath,
          '-ss',
          '00:00:01',
          '-vframes',
          '1',
          '-q:v',
          '2',
          thumbPath,
          '-y',
        ],
      );

      if (result.exitCode == 0 && await File(thumbPath).exists()) {
        return thumbPath;
      }
    } catch (e) {
      debugPrint('⚠️ Error generating thumbnail: $e');
    }
    return null;
  }

  // ─── RENDER WATERMARK ──────────────────────────────────────

  Future<void> _renderWatermark(String videoPath, ScanEntry entry) async {
    try {
      final outputDir = await getTemporaryDirectory();
      final outputPath = '${outputDir.path}/watermarked_${DateTime.now().millisecondsSinceEpoch}.mp4';

      final result = await VideoWatermarkService.renderVideo(
        videoPath: videoPath,
        outputPath: outputPath,
        settings: _wmSettings,
        entry: entry,
      );

      if (result != null && await File(result).exists()) {
        final savedPath = await _storage.saveVideo(result);
        if (savedPath.isNotEmpty) {
          final updated = entry.copyWith(videoPath: savedPath);
          await _storage.update(updated);
          setState(() => _videoPath = savedPath);
        }
      } else {
        debugPrint('⚠️ Watermark render failed, using original video');
      }
    } catch (e) {
      debugPrint('⚠️ Error rendering watermark: $e');
    }
  }

  // ─── ATTACH LOCATION UPDATE ────────────────────────────────

  Future<void> _attachLocationUpdate(String entryId) async {
    try {
      final locState = await PodLocationService.instance.awaitAddressReady(
        timeout: const Duration(seconds: 10),
      );
      if (!locState.hasPosition) return;
      final stored = await _storage.getEntry(entryId);
      if (stored == null) return;
      final updated = stored.copyWith(
        latitude: locState.lat,
        longitude: locState.lon,
        locationName: locState.address.isNotEmpty ? locState.address : null,
      );
      await _storage.update(updated);
    } catch (e) {
      debugPrint('❌ Error _attachLocationUpdate: $e');
    }
  }

  // ─── SHOW PREVIEW ───────────────────────────────────────────

  Future<String?> _showPreview(String videoPath) async {
    final file = XFile(videoPath);
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => PreviewScreen(
          file: file,
          mediaType: MediaType.video,
          onSave: () => Navigator.pop(context, 'save'),
          onRetake: () => Navigator.pop(context, 'retake'),
        ),
      ),
    );
  }

  // ─── WATERMARK SETTINGS ─────────────────────────────────────

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

  // ─── BUILD ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isProcessing = _isProcessing || _isRecording;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(widget.barcode != null
            ? 'Video: ${widget.barcode}'
            : 'Rekam Video'),
        actions: [
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
              // Icon
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
                child: _isRecording
                    ? const Icon(
                        Icons.circle,
                        color: Colors.red,
                        size: 52,
                      )
                    : const Icon(
                        Icons.videocam,
                        color: AppTheme.accentOrange,
                        size: 52,
                      ),
              ),

              const Gap(24),

              // Header
              Text(
                _isRecording ? 'Merekam...' : 'Rekam Video',
                style: Theme.of(context).textTheme.titleLarge,
              ),

              const Gap(8),

              Text(
                _isRecording
                    ? 'Ketik tombol stop untuk menyelesaikan'
                    : 'Video otomatis disertai timestamp & watermark',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),

              if (_videoDuration != null) ...[
                const Gap(8),
                Text(
                  'Durasi: ${_formatDuration(_videoDuration!)}',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
              ],

              const Gap(48),

              // Action Buttons
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: isProcessing ? null : _recordVideo,
                  icon: isProcessing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2),
                        )
                      : const Icon(Icons.videocam, size: 22),
                  label: Text(isProcessing ? 'Memproses...' : 'Rekam Video'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentOrange,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    textStyle: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
              ),

              const Gap(14),

              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: isProcessing ? null : _pickFromGallery,
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
              ),

              const Gap(32),

              // Info Box
              Container(
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
                        'Video akan otomatis diberi watermark sesuai pengaturan',
                        style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),

              if (_isProcessing)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(
                    backgroundColor: Colors.grey[800],
                    valueColor: AlwaysStoppedAnimation(AppTheme.accentOrange),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }
}
