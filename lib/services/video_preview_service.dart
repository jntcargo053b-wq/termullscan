// lib/services/video_preview_service.dart
// Layanan untuk kompresi dan preview video logistik.
// Menggunakan ffmpeg_kit_flutter_new dan video_player.

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;

/// Model tugas video (sesuaikan dengan model Anda).
/// Contoh implementasi minimal.
class VideoTask {
  final String barcode;
  final String? locationName;
  final double? latitude;
  final double? longitude;
  final int maxDurationSeconds;

  VideoTask({
    required this.barcode,
    this.locationName,
    this.latitude,
    this.longitude,
    required this.maxDurationSeconds,
  });
}

/// Service untuk menangani kompresi video dan preview dialog.
class VideoPreviewService {
  /// Kompres video untuk logistik dengan:
  /// - Resolusi maksimum: lebar 1280, tinggi 720 (tidak pernah upscale)
  /// - Dimensi genap (trunc/2*2) agar kompatibel dengan H.264
  /// - SAR=1, pixel format yuv420p
  /// - Preset veryfast (cepat untuk mobile) + profile high, level 4.1
  /// - Threads otomatis (0)
  /// - Audio dihilangkan secara default (keepAudio = false)
  /// - Mempertahankan metadata orientasi kamera, buang chapter
  /// - Hapus file asli hanya jika output berhasil dan ukuran > 1KB (dengan try-catch)
  /// - Logging lengkap (return code, state, logs, fail stack trace)
  static Future<String?> compressVideo(
    String inputPath, {
    int bitrateKbps = 2500,
    bool keepAudio = false,
  }) async {
    // --- 1. Buat nama file output yang robust ---
    final String outputPath = p.join(
      p.dirname(inputPath),
      '${p.basenameWithoutExtension(inputPath)}_compressed.mp4',
    );

    // --- 2. Filter video: dimensi genap, SAR=1 ---
    final String videoFilter =
        "scale=w='min(1280,trunc(iw/2)*2)':"
        "h='min(720,trunc(ih/2)*2)':"
        "force_original_aspect_ratio=decrease,"
        "setsar=1";

    // --- 3. Bangun argumen FFmpeg ---
    final List<String> arguments = [
      '-i', inputPath,
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-profile:v', 'high',
      '-level', '4.1',
      '-crf', '23',
      '-vf', videoFilter,
      '-pix_fmt', 'yuv420p',
      '-b:v', '${bitrateKbps}k',
      '-maxrate', '${bitrateKbps * 1.5}k',
      '-bufsize', '${bitrateKbps * 2}k',
      '-movflags', '+faststart',
    ];

    // --- 4. Opsi audio ---
    if (keepAudio) {
      arguments.addAll(['-c:a', 'aac', '-b:a', '128k']);
    } else {
      arguments.add('-an');
    }

    // --- 5. Pertahankan metadata input, buang chapter ---
    arguments.addAll([
      '-map_metadata', '0',
      '-map_chapters', '-1',
    ]);

    // --- 6. Gunakan semua core CPU ---
    arguments.addAll(['-threads', '0']);

    arguments.addAll(['-y', outputPath]);

    // --- 7. Eksekusi FFmpeg (dibungkus try-catch-finally) ---
    // File asli (inputPath) TIDAK PERNAH dihapus di sini kecuali output
    // sudah terverifikasi valid pada langkah 8 -> aman dari kehilangan data
    // kalau plugin FFmpeg melempar exception (native crash, OOM, dll).
    bool success = false;
    try {
      final session = await FFmpegKit.executeWithArguments(arguments);
      final rc = await session.getReturnCode();

      // --- 8. Cek hasil ---
      if (ReturnCode.isSuccess(rc)) {
        // Verifikasi file output
        final outputFile = File(outputPath);
        if (await outputFile.exists() && await outputFile.length() > 1024) {
          success = true;
          // Hapus file asli hanya jika output valid, dibungkus try-catch
          try {
            await File(inputPath).delete();
          } catch (e) {
            debugPrint('Unable to delete original file: $e');
          }
          return outputPath;
        } else {
          // Output rusak atau terlalu kecil
          debugPrint('Output file corrupt or empty: $outputPath');
          return null;
        }
      } else {
        // --- 9. Logging kegagalan ---
        final logs = await session.getAllLogsAsString();
        final state = await session.getState();
        final failStack = await session.getFailStackTrace();
        debugPrint('FFmpeg compression failed.');
        debugPrint('State: $state');
        debugPrint('Return code: ${rc?.toString() ?? 'null'}');
        debugPrint('Fail stack trace: ${failStack ?? 'none'}');
        debugPrint('Logs:\n$logs');
        return null;
      }
    } catch (e, stack) {
      // Exception dari FFmpegKit sendiri (bukan return code gagal biasa) --
      // sebelumnya tidak tertangkap sama sekali dan bisa merambat ke caller.
      debugPrint('❌ Exception saat kompresi video: $e\n$stack');
      return null;
    } finally {
      // Bersihkan output parsial/korup kapan pun proses tidak berhasil,
      // baik karena return code gagal maupun exception di atas.
      if (!success) {
        try {
          final outputFile = File(outputPath);
          if (await outputFile.exists()) {
            await outputFile.delete();
            debugPrint('🗑️ Output parsial dibersihkan: $outputPath');
          }
        } catch (_) {}
      }
    }
  }

  /// Tampilkan preview video di dialog.
  /// Controller hanya di-dispose satu kali setelah dialog ditutup.
  static Future<bool> showPreviewDialog(
    BuildContext context,
    String videoPath,
    VideoTask task,
  ) async {
    final controller = VideoPlayerController.file(File(videoPath));
    await controller.initialize();
    controller.play();

    final bool? result = await showDialog<bool>(
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
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Rekam Ulang', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.check_circle),
              label: const Text('Simpan'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            ),
          ],
        ),
      ),
    );

    // Dispose controller setelah dialog selesai (hanya satu kali)
    await controller.dispose();
    return result ?? false;
  }
}
