// ============================================================
// lib/screens/video_scan_screen.dart (FINAL – CAMERA 0.10.5+5 FIX)
// ============================================================
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart' hide ImageFormat;
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
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

class _VideoScanScreenState extends State<VideoScanScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isRecording = false;
  bool _isStopping = false;
  bool _isSaving = false;
  bool _isWatermarking = false;
  String _statusText = '';
  int _recordedSeconds = 0;
  Timer? _timer;
  XFile? _recordedFile;
  final StorageService _storage = StorageService();

  static const int _maxDurationSeconds = 20;
  static const int _minDurationSeconds = 3;
  static const int _maxVideoSizeBytes = 50 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    // Jangan panggil stopVideoRecording di sini – lifecycle yang menangani
    _cameraController?.dispose();
    _cameraController = null;
    if (_recordedFile != null) {
      File(_recordedFile!.path).delete().catchError((_) {});
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      final controller = _cameraController;
      _cameraController = null;

      if (_isRecording && controller != null) {
        unawaited(_stopRecordingAndSave(showPreviewAfter: false).whenComplete(() {
          controller.dispose();
        }));
      } else {
        controller?.dispose();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_cameraController == null) _initCamera();
    }
  }

  // ─── INISIALISASI KAMERA (FIX) ──────────────────────────
  Future<void> _initCamera() async {
    try {
      final cam = await Permission.camera.request();
      final mic = await Permission.microphone.request();
      if (!cam.isGranted || !mic.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Izin kamera & mikrofon diperlukan')),
          );
          Navigator.pop(context);
        }
        return;
      }

      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tidak ada kamera')),
          );
          Navigator.pop(context);
        }
        return;
      }

      CameraDescription selectedCamera;
      try {
        selectedCamera = _cameras!.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
        );
      } catch (_) {
        selectedCamera = _cameras!.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
        );
      }

      debugPrint('📷 Kamera: ${selectedCamera.name}');

      _cameraController = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.yuv420, // stabil di Android
      );

      // Gunakan variabel lokal untuk listener
      final controller = _cameraController!;
      controller.addListener(() {
        if (!mounted) return;
        if (controller.value.hasError) {
          debugPrint('❌ Camera error: ${controller.value.errorDescription}');
        }
      });

      await controller.initialize();

      if (!controller.value.isInitialized) {
        throw Exception('Camera gagal diinisialisasi');
      }
      if (controller.value.hasError) {
        throw Exception(controller.value.errorDescription);
      }

      // Beri waktu surface benar-benar siap
      await Future.delayed(const Duration(milliseconds: 300));

      if (!mounted) return;
      setState(() {
        _statusText = 'Siap merekam';
      });

      debugPrint('✅ Kamera siap');
    } catch (e, stack) {
      debugPrint('❌ Gagal buka kamera: $e\n$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error kamera: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  // ─── REKAM / STOP ────────────────────────────────────────
  Future<void> _toggleRecording() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kamera belum siap')),
      );
      return;
    }
    if (_isStopping) return;

    if (_isRecording) {
      if (_recordedSeconds < _minDurationSeconds) {
        final sisa = _minDurationSeconds - _recordedSeconds;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Minimal $_minDurationSeconds detik. Tunggu $sisa detik.'),
          ),
        );
        return;
      }
      await _stopRecordingAndSave(showPreviewAfter: false);
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    final controller = _cameraController;
    if (controller == null) return;
    if (!controller.value.isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kamera belum siap')),
      );
      return;
    }
    if (controller.value.isTakingPicture || controller.value.isRecordingVideo) {
      return;
    }

    // ⏱️ Tunggu ImageReader benar-benar siap (CameraX fix)
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    if (!controller.value.isInitialized) return;

    try {
      await controller.startVideoRecording();
      debugPrint('🎥 isRecordingVideo = ${controller.value.isRecordingVideo}');

      setState(() {
        _isRecording = true;
        _recordedSeconds = 0;
        _statusText = 'Merekam...';
      });

      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        final newSec = _recordedSeconds + 1;
        setState(() => _recordedSeconds = newSec);

        if (newSec >= _maxDurationSeconds) {
          timer.cancel();
          if (_isRecording && !_isStopping) {
            unawaited(_stopRecordingAndSave(showPreviewAfter: false));
          }
        }
      });
    } catch (e, stack) {
      debugPrint('❌ Gagal rekam: $e\n$stack');
      if (mounted) {
        setState(() {
          _isRecording = false;
          _statusText = 'Gagal merekam: $e';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal merekam: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ─── STOP & SIMPAN ─────────────────────────────────────
  Future<void> _stopRecordingAndSave({required bool showPreviewAfter}) async {
    if (!_isRecording || _isStopping) return;
    _isStopping = true;
    _timer?.cancel();

    final controller = _cameraController;
    if (controller == null || !controller.value.isRecordingVideo) {
      _isStopping = false;
      return;
    }

    try {
      final XFile videoFile = await controller.stopVideoRecording();
      if (!mounted) return;

      final file = File(videoFile.path);
      if (!await file.exists() || await file.length() < 1000) {
        await file.delete().catchError((_) {});
        throw Exception('Video terlalu pendek / gagal tersimpan');
      }

      setState(() {
        _isRecording = false;
        _recordedFile = videoFile;
        _statusText = 'Menyimpan...';
      });

      if (showPreviewAfter && mounted) {
        final ok = await _showPreviewDialog(videoFile.path);
        if (!mounted) return;
        if (ok != true) {
          await file.delete();
          setState(() => _recordedFile = null);
          return;
        }
      }

      await _saveVideo(videoFile);
    } catch (e) {
      debugPrint('❌ Stop recording error: $e');
      if (mounted) {
        setState(() => _statusText = 'Gagal: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      _isStopping = false;
    }
  }

  // ─── SIMPAN ───────────────────────────────────────────
  Future<void> _saveVideo(XFile videoFile) async {
    if (!mounted) return;
    setState(() => _isSaving = true);
    try {
      final fileSize = await File(videoFile.path).length();
      if (fileSize > _maxVideoSizeBytes) {
        await File(videoFile.path).delete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Video terlalu besar. Maks 50 MB.'), backgroundColor: Colors.red),
          );
          setState(() => _isSaving = false);
        }
        return;
      }

      final savedPath = await _storage.saveVideo(videoFile.path, name: widget.barcode);
      if (savedPath.isEmpty) throw Exception('Gagal menyimpan video');

      final thumb = await _generateThumbnail(savedPath);

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.video,
        value: widget.barcode ?? 'video_${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        videoPath: savedPath,
        videoDuration: _recordedSeconds,
        videoThumbnail: thumb,
      );
      await _storage.add(entry);

      if (mounted) setState(() {
        _isSaving = false;
        _isWatermarking = true;
        _statusText = 'Watermark...';
      });

      final wmPath = '$savedPath.wm.mp4';
      final wmResult = await VideoWatermarkService.addWatermark(
        inputPath: savedPath,
        outputPath: wmPath,
        entry: entry,
        settings: WatermarkSettings(),
      );

      if (wmResult != null) {
        await File(savedPath).delete();
        final updated = entry.copyWith(videoPath: wmResult, videoThumbnail: thumb);
        await _storage.update(updated);
        if (mounted) {
          setState(() => _isWatermarking = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video tersimpan + watermark')),
          );
          Navigator.pop(context, {'entry': updated});
        }
      } else {
        if (mounted) {
          setState(() => _isWatermarking = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video tersimpan (tanpa watermark)')),
          );
          Navigator.pop(context, {'entry': entry});
        }
      }
    } catch (e, stack) {
      debugPrint('❌ Save error: $e\n$stack');
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal simpan: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _recordedFile = null);
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

  String _formatDuration(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  String _formatMaxDuration() => _formatDuration(_maxDurationSeconds);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isRecording,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isRecording) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Hentikan rekaman dulu')),
          );
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text('Rekam Video ${widget.barcode ?? ""}'),
          automaticallyImplyLeading: !_isRecording,
          actions: [
            if (_isRecording)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_formatDuration(_recordedSeconds)} / ${_formatMaxDuration()}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  if (_cameraController != null && _cameraController!.value.isInitialized)
                    CameraPreview(_cameraController!)
                  else
                    const Center(child: CircularProgressIndicator()),
                  if (_isRecording)
                    Positioned(
                      bottom: 0, left: 0, right: 0,
                      child: LinearProgressIndicator(
                        value: _recordedSeconds / _maxDurationSeconds,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.red),
                        minHeight: 4,
                      ),
                    ),
                  if (_statusText.isNotEmpty)
                    Positioned(
                      top: 20, left: 20, right: 20,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(_statusText, style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                ],
              ),
            ),
            if (!_isSaving && !_isWatermarking)
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: GestureDetector(
                      onTap: _toggleRecording,
                      child: Container(
                        width: 80, height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                          color: _isRecording ? Colors.red : Colors.transparent,
                        ),
                        child: Center(
                          child: _isRecording
                              ? Container(width: 30, height: 30, color: Colors.white)
                              : Container(width: 70, height: 70, color: Colors.red),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _showPreviewDialog(String videoPath) async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _VideoPreviewDialog(
        videoPath: videoPath,
        onSave: () => Navigator.pop(context, true),
        onRetake: () {
          File(videoPath).delete().catchError((_) {});
          Navigator.pop(context, false);
        },
      ),
    );
  }
}

// ─── DIALOG PREVIEW VIDEO ──────────────────────────────────
class _VideoPreviewDialog extends StatefulWidget {
  final String videoPath;
  final VoidCallback onSave;
  final VoidCallback onRetake;
  const _VideoPreviewDialog({
    required this.videoPath,
    required this.onSave,
    required this.onRetake,
  });
  @override
  State<_VideoPreviewDialog> createState() => _VideoPreviewDialogState();
}

class _VideoPreviewDialogState extends State<_VideoPreviewDialog> {
  late VideoPlayerController _ctrl;
  bool _init = false;
  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) => setState(() => _init = true));
  }
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_init)
            AspectRatio(aspectRatio: _ctrl.value.aspectRatio, child: VideoPlayer(_ctrl))
          else
            const SizedBox(height: 200, child: Center(child: CircularProgressIndicator())),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              ElevatedButton.icon(onPressed: widget.onRetake, icon: const Icon(Icons.camera_alt), label: const Text('Ulang')),
              ElevatedButton.icon(onPressed: widget.onSave, icon: const Icon(Icons.check), label: const Text('Simpan')),
            ],
          ),
        ],
      ),
    );
  }
}
