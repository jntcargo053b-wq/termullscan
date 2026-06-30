import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
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
  bool _isSaving = false;
  bool _isWatermarking = false;
  int _recordedSeconds = 0;
  Timer? _timer;
  final StorageService _storage = StorageService();

  static const int _maxDurationSeconds = 120;
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
      _cameraController = null;
      if (_isRecording) {
        _timer?.cancel();
        if (mounted) {
          setState(() {
            _isRecording = false;
            _recordedSeconds = 0;
          });
        }
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

    if (_isRecording) {
      await _stopRecording();
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
      });

      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() {
            _recordedSeconds++;
          });
          if (_recordedSeconds >= _maxDurationSeconds) {
            _stopRecording();
          }
        }
      });
    } catch (e) {
      debugPrint('Start recording error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal merekam: $e')),
      );
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    try {
      _timer?.cancel();
      final XFile videoFile = await _cameraController!.stopVideoRecording();
      setState(() {
        _isRecording = false;
        _isSaving = true;
      });

      final fileSize = await File(videoFile.path).length();
      if (fileSize > _maxVideoSizeBytes) {
        try { await File(videoFile.path).delete(); } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Video terlalu besar (${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB). Maksimal 50 MB.',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
        setState(() => _isSaving = false);
        return;
      }

      final savedPath = await _storage.saveVideo(videoFile.path, name: widget.barcode);
      if (savedPath.isNotEmpty) {
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

        ScanEntry finalEntry = entry;

        if (mounted) {
          setState(() {
            _isSaving = false;
            _isWatermarking = true;
          });

          final wmOutputPath = '$savedPath.wm.mp4';
          try {
            final wmResult = await VideoWatermarkService.addWatermark(
              inputPath: savedPath,
              outputPath: wmOutputPath,
              entry: entry,
              settings: WatermarkSettings(),
            );

            if (wmResult != null) {
              finalEntry = entry.copyWith(
                videoPath: wmResult,
                videoThumbnail: thumbnailPath,
              );
              await _storage.update(finalEntry);
            }
          } catch (e) {
            debugPrint('Watermark error: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Gagal menambahkan watermark: $e')),
              );
            }
          }

          if (mounted) {
            setState(() => _isWatermarking = false);
          }
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video tersimpan')),
          );
          Navigator.pop(context, {'entry': finalEntry});
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Gagal menyimpan video')),
          );
        }
      }
    } catch (e) {
      debugPrint('Stop recording error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<String?> _generateThumbnail(String videoPath) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final thumbnail = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: docsDir.path,
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
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('Rekam Video')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('Rekam Video ${widget.barcode ?? ""}'),
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
                CameraPreview(_cameraController!),
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
                if (_isWatermarking)
                  const Center(
                    child: CircularProgressIndicator(),
                  ),
              ],
            ),
          ),
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            )
          else if (!_isWatermarking)
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
            ),
        ],
      ),
    );
  }
}
