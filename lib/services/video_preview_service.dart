import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';

class VideoPreviewService {
  /// Kompres video ke 720p, 2-3 Mbps
  static Future<String?> compressVideo(String inputPath, {int bitrateKbps = 2500}) async {
    final outputPath = inputPath.replaceAll('.mp4', '_compressed.mp4');
    final arguments = [
      '-i', inputPath,
      '-c:v', 'libx264',
      '-preset', 'medium',
      '-crf', '23',
      '-vf', 'scale=1280:720',
      '-b:v', '${bitrateKbps}k',
      '-maxrate', '${bitrateKbps * 1.5}k',
      '-bufsize', '${bitrateKbps * 2}k',
      '-c:a', 'aac',
      '-b:a', '128k',
      '-movflags', '+faststart',
      '-y',
      outputPath,
    ];
    final session = await FFmpegKit.executeWithArguments(arguments);
    final rc = await session.getReturnCode();
    if (rc?.isValueSuccess() == true) {
      await File(inputPath).delete();
      return outputPath;
    }
    return null;
  }

  /// Tampilkan preview video di dialog
  static Future<bool> showPreviewDialog(
    BuildContext context,
    String videoPath,
    VideoTask task,
  ) async {
    final controller = VideoPlayerController.file(File(videoPath));
    await controller.initialize();
    controller.play();

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.play_circle, color: Colors.green),
              const SizedBox(width: 8),
              Text('Preview Video: ${task.barcode}'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(
                      controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                    onPressed: () {
                      setState(() {
                        controller.value.isPlaying
                            ? controller.pause()
                            : controller.play();
                      });
                    },
                  ),
                  Text(
                    '${controller.value.position.inSeconds}s / ${controller.value.duration.inSeconds}s',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (task.locationName != null)
                Text('📍 ${task.locationName}'),
              if (task.latitude != null)
                Text('🌐 ${task.latitude!.toStringAsFixed(4)}, ${task.longitude!.toStringAsFixed(4)}'),
              const Divider(),
              Row(
                children: [
                  Icon(Icons.info_outline, size: 16),
                  const SizedBox(width: 4),
                  Text('Durasi: ${task.maxDurationSeconds}s'),
                  const Spacer(),
                  Icon(Icons.storage, size: 16),
                  const SizedBox(width: 4),
                  Text('${(File(videoPath).lengthSync() / (1024*1024)).toStringAsFixed(1)} MB'),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                controller.dispose();
                Navigator.pop(ctx, false);
              },
              child: const Text('Rekam Ulang', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton.icon(
              onPressed: () {
                controller.dispose();
                Navigator.pop(ctx, true);
              },
              icon: const Icon(Icons.check_circle),
              label: const Text('Simpan'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            ),
          ],
        ),
      ),
    );
    await controller.dispose();
    return result ?? false;
  }
}
