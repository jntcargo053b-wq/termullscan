// ============================================================
// lib/screens/video_scan_screen.dart (FINAL – DOUBLE-STOP GUARD)
// ============================================================
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
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
  bool _isStopping = false; // ✅ proteksi double-stop
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
    if (_isRecording) {
      _cameraController?.stopVideoRecording().catchError((_) {});
    }
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
      if (_cameraController == null) {
        _initCamera();
      }
    }
  }

  Future<void> _initCamera() async {
    final camStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();

    if (!camStatus.isGranted || !micStatus.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Izin kamera dan mikrofon diperlukan untuk merekam video'),
          ),
        );
        Navigator.pop(context);
      }
      return;
    }

    _cameras = await availableCameras();
    if (_cameras == null || _cameras!.isEmpty) {
      if (mounted) Navigator.pop(context);
      return;
    }

    _cameraController = CameraController(
      _cameras!.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      ),
      ResolutionPreset.medium,
      enableAudio: true,
    );

    try {
      await _cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Camera init error: $e');
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _toggleRecording() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (_isStopping) return; // abaikan saat sedang berhenti

    if (_isRecording) {
      if (_recordedSeconds < _minDurationSeconds) {
        final sisa = _minDurationSeconds - _recordedSeconds;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Rekam minimal $_minDurationSeconds detik. Tunggu $sisa detik lagi.'),
            duration: const Duration(seconds: 2),
          ),
        );
        return;
      }
      await _stopRecordingAndSave(showPreviewAfter: true);
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    try {
      await _cameraController!.startVideoRecording();
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
        setState(() => _recordedSeconds++);

        if (_recordedSeconds >= _maxDurationSeconds) {
          timer.cancel(); // ✅ hentikan timer segera
          if (_isRecording && !_isStopping) {
            unawaited(_stopRecordingAndSave(showPreviewAfter: true));
          }
        }
      });
    } catch (e) {
      debugPrint('Start recording error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal merekam: $e')),
        );
      }
    }
  }

  Future<void> _stopRecordingAndSave({required bool showPreviewAfter}) async {
    // ✅ cegah double-stop
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

      // ✅ periksa mounted sebelum setState
      if (!mounted) return;

      setState(() {
        _isRecording = false;
        _recordedFile = videoFile;
        _statusText = 'Memproses video...';
      });

      if (showPreviewAfter && mounted) {
        final shouldSave = await _showPreviewDialog(videoFile.path);
        if (!mounted) return;
        if (shouldSave != true) {
          await File(videoFile.path).delete();
          setState(() {
            _recordedFile = null;
            _statusText = '';
          });
          return;
        }
      }

      await _saveVideo(videoFile);
    } catch (e) {
      debugPrint('Stop recording error: $e');
      if (mounted) {
        setState(() => _statusText = 'Gagal: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      _isStopping = false;
    }
  }

  Future<void> _saveVideo(XFile videoFile) async {
    setState(() {
      _isSaving = true;
      _statusText = 'Menyimpan video...';
    });

    try {
      final fileSize = await File(videoFile.path).length();
      if (fileSize > _maxVideoSizeBytes) {
        await File(videoFile.path).delete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Video terlalu besar (${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB). Maksimal 50 MB.',
              ),
              backgroundColor: Colors.red,
            ),
          );
          setState(() {
            _isSaving = false;
            _statusText = '';
            _recordedFile = null;
          });
        }
        return;
      }

      final savedPath = await _storage.saveVideo(videoFile.path, name: widget.barcode);
      if (savedPath.isEmpty) throw Exception('Gagal menyimpan video');

      final thumbnailPath = await _generateThumbnail(savedPath);

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.video,
        value: widget.barcode ?? 'video_${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        videoPath: savedPath,
        videoDuration: _recordedSeconds,
        videoThumbnail: thumbnailPath,
      );
      await _storage.add(entry);

      if (mounted) {
        setState(() {
          _isSaving = false;
          _isWatermarking = true;
          _statusText = 'Menambahkan watermark...';
        });
      }

      final wmOutputPath = '$savedPath.wm.mp4';
      final wmResult = await VideoWatermarkService.addWatermark(
        inputPath: savedPath,
        outputPath: wmOutputPath,
        entry: entry,
        settings: WatermarkSettings(),
      );

      if (wmResult != null) {
        await File(savedPath).delete();
        final updatedEntry = entry.copyWith(
          videoPath: wmResult,
          videoThumbnail: thumbnailPath,
        );
        await _storage.update(updatedEntry);

        if (mounted) {
          setState(() {
            _isWatermarking = false;
            _statusText = 'Video tersimpan';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video berhasil disimpan dengan watermark')),
          );
          Navigator.pop(context, {'entry': updatedEntry});
        }
      } else {
        if (mounted) {
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
    } catch (e) {
      debugPrint('Save video error: $e');
      if (mounted) {
        setState(() {
          _isSaving = false;
          _isWatermarking = false;
          _statusText = 'Gagal menyimpan';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan video: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _recordedFile = null);
    }
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

  Future<String?> _generateThumbnail(String videoPath) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final thumbnail = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: dir.path,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 200,
        quality: 75,
      );
      return thumbnail;
    } catch (e) {
      debugPrint('Thumbnail error: $e');
      return null;
    }
  }

  String _formatDuration(int seconds) {
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  String _formatMaxDuration() {
    final min = _maxDurationSeconds ~/ 60;
    final sec = _maxDurationSeconds % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isRecording,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isRecording) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Hentikan rekaman terlebih dahulu sebelum keluar'),
              duration: Duration(seconds: 2),
            ),
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.fiber_manual_record, size: 16, color: Colors.white),
                    const Gap(4),
                    Text(
                      '${_formatDuration(_recordedSeconds)} / ${_formatMaxDuration()}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ],
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
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(
                        value: _recordedSeconds / _maxDurationSeconds,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.red),
                        minHeight: 4,
                      ),
                    ),
                  if (_statusText.isNotEmpty)
                    Positioned(
                      top: 20,
                      left: 20,
                      right: 20,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _statusText,
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
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
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                          color: _isRecording ? Colors.red : Colors.transparent,
                        ),
                        child: Center(
                          child: _isRecording
                              ? Container(
                                  width: 30,
                                  height: 30,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                )
                              : Container(
                                  width: 70,
                                  height: 70,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.red,
                                  ),
                                ),
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
}

// ─── DIALOG PREVIEW VIDEO ────────────────────────────────────
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
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
        _controller.play();
      });
    _controller.addListener(() {
      if (mounted && _controller.value.isCompleted) {
        _controller.seekTo(Duration.zero);
        _controller.pause();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            child: const Text(
              'Pratinjau Video',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
          if (_initialized)
            AspectRatio(
              aspectRatio: _controller.value.aspectRatio,
              child: VideoPlayer(_controller),
            )
          else
            const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            ),
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ElevatedButton.icon(
                  onPressed: widget.onRetake,
                  icon: const Icon(Icons.camera_alt, color: Colors.red),
                  label: const Text('Ulang'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[800],
                    foregroundColor: Colors.white,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: widget.onSave,
                  icon: const Icon(Icons.check, color: Colors.green),
                  label: const Text('Simpan'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green[700],
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
