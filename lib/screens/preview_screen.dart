import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gap/gap.dart';
import '../theme/app_theme.dart';

enum MediaType { photo, video }

/// Layar preview untuk foto atau video sebelum disimpan.
/// Pengguna bisa melihat hasil, memutar video, melihat ukuran & durasi,
/// lalu memilih Simpan atau Retake.
class PreviewScreen extends StatefulWidget {
  final XFile file;
  final MediaType mediaType;
  final VoidCallback onSave;
  final VoidCallback onRetake;

  const PreviewScreen({
    super.key,
    required this.file,
    required this.mediaType,
    required this.onSave,
    required this.onRetake,
  });

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isVideoLoading = true;
  String? _videoError;

  @override
  void initState() {
    super.initState();
    if (widget.mediaType == MediaType.video) {
      _initVideo();
    } else {
      _isVideoLoading = false;
    }
  }

  Future<void> _initVideo() async {
    if (!mounted) return;
    setState(() {
      _isVideoLoading = true;
      _videoError = null;
    });

    try {
      final file = File(widget.file.path);
      if (!await file.exists()) {
        throw Exception('File video tidak ditemukan');
      }

      _videoController = VideoPlayerController.file(file);
      await _videoController!.initialize();

      if (!mounted) return;

      setState(() {
        _isVideoInitialized = true;
        _isVideoLoading = false;
      });

      _videoController!.play();
    } catch (e) {
      debugPrint('❌ Gagal init video preview: $e');
      if (!mounted) return;
      setState(() {
        _videoError = 'Gagal memuat video: $e';
        _isVideoLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_videoController == null || !_isVideoInitialized) return;
    setState(() {
      _videoController!.value.isPlaying
          ? _videoController!.pause()
          : _videoController!.play();
    });
  }

  String _formatDuration(Duration duration) {
    final seconds = duration.inSeconds;
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final file = File(widget.file.path);
    final fileSize = file.existsSync() ? file.lengthSync() : 0;
    final sizeInMB = (fileSize / (1024 * 1024)).toStringAsFixed(1);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: widget.onRetake,
          tooltip: 'Retake / Batal',
        ),
        actions: [
          TextButton(
            onPressed: widget.onSave,
            child: const Text(
              'Simpan',
              style: TextStyle(
                color: AppTheme.accentOrange,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ── Media Preview ──
            Expanded(
              child: Center(
                child: _buildMediaPreview(file),
              ),
            ),
            // ── Info & Tombol ──
            Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1A1A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Ukuran: $sizeInMB MB',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 14,
                            ),
                          ),
                          if (widget.mediaType == MediaType.video &&
                              _isVideoInitialized)
                            Text(
                              'Durasi: ${_formatDuration(_videoController!.value.duration)}',
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 14,
                              ),
                            ),
                          if (_videoError != null)
                            Text(
                              '⚠️ $_videoError',
                              style: const TextStyle(
                                color: AppTheme.error,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                      if (widget.mediaType == MediaType.video &&
                          _isVideoInitialized)
                        IconButton(
                          icon: Icon(
                            _videoController!.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: Colors.white,
                            size: 32,
                          ),
                          onPressed: _togglePlayPause,
                        ),
                    ],
                  ),
                  const Gap(16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: widget.onRetake,
                          icon: const Icon(Icons.refresh, color: AppTheme.error),
                          label: const Text(
                            'Retake',
                            style: TextStyle(color: AppTheme.error),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppTheme.error),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            textStyle: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      const Gap(16),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: widget.onSave,
                          icon: const Icon(Icons.save, color: Colors.black),
                          label: const Text(
                            'Simpan',
                            style: TextStyle(color: Colors.black),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.accentOrange,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaPreview(File file) {
    if (widget.mediaType == MediaType.photo) {
      return Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Icon(
          Icons.broken_image,
          color: Colors.grey,
          size: 64,
        ),
      );
    } else {
      // Video
      if (_isVideoLoading) {
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            Gap(16),
            Text(
              'Memuat video...',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        );
      }

      if (_videoError != null) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const Gap(16),
            Text(
              'Gagal memuat video',
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const Gap(8),
            Text(
              _videoError!,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const Gap(16),
            ElevatedButton(
              onPressed: _initVideo,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentOrange,
                foregroundColor: Colors.black,
              ),
              child: const Text('Coba Lagi'),
            ),
          ],
        );
      }

      if (_isVideoInitialized) {
        return AspectRatio(
          aspectRatio: _videoController!.value.aspectRatio,
          child: VideoPlayer(_videoController!),
        );
      }

      return const SizedBox.shrink();
    }
  }
}
