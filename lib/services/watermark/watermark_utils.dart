import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import '../../models/scan_entry.dart';
import '../../watermark/watermark_settings.dart';

// ─── ESCAPE ───────────────────────────────────────────────

String escapeFFmpegText(String text) {
  return text.replaceAll("'", r"'\''").replaceAll(':', r'\:');
}

String escapeFFmpegPath(String path) {
  return path.replaceAll("'", r"'\''").replaceAll(':', r'\:');
}

// ─── ADDRESS WRAP ────────────────────────────────────────

List<String> wrapAddress(String text, {required int maxLineLen}) {
  if (text.length <= maxLineLen) return [text];
  final words = text.split(' ');
  final line1 = StringBuffer();
  final line2 = StringBuffer();
  for (final w in words) {
    if ((line1.length + w.length + 1) <= maxLineLen) {
      if (line1.isNotEmpty) line1.write(' ');
      line1.write(w);
    } else {
      if (line2.isNotEmpty) line2.write(' ');
      line2.write(w);
    }
  }
  var second = line2.toString();
  if (second.length > maxLineLen) {
    second = '${second.substring(0, maxLineLen - 1)}…';
  }
  return second.isEmpty ? [line1.toString()] : [line1.toString(), second];
}

// ─── VERIFICATION CODE ────────────────────────────────────

String generateVerificationCode(ScanEntry entry, WatermarkSettings settings) {
  final seed = '${entry.timestamp.millisecondsSinceEpoch}'
      '${settings.operatorName}${entry.value}';
  final hash = seed.codeUnits.fold<int>(0, (p, c) => (p * 31 + c) & 0x7FFFFFFF);
  final code = hash.toRadixString(36).toUpperCase();
  return code.padLeft(10, 'X').substring(0, 10);
}

// ─── DATE/TIME FORMATTERS ─────────────────────────────────

String hhmmFF(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

String ddmmyyyyFF(DateTime dt) =>
    '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

const List<String> hariIndoFF = [
  'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu',
];
String dayNameFF(DateTime dt) => hariIndoFF[dt.weekday - 1];

String formatTimestamp(DateTime dt) {
  return '${dt.day.toString().padLeft(2, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.year} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';
}

// ─── VIDEO PROBE (DURASI & DIMENSI) ──────────────────────

class VideoDimensions {
  final int width;
  final int height;
  VideoDimensions(this.width, this.height);
}

Future<int> probeVideoDuration(String inputPath) async {
  try {
    final session = await FFprobeKit.getMediaInformation(inputPath);
    final mediaInfo = session.getMediaInformation();
    if (mediaInfo != null) {
      final durationStr = mediaInfo.getDuration();
      if (durationStr != null && durationStr.isNotEmpty) {
        final duration = double.tryParse(durationStr);
        if (duration != null) return duration.round();
      }
    }
    return 0;
  } catch (e) {
    return 0;
  }
}

Future<VideoDimensions> probeVideoDimensions(String inputPath) async {
  try {
    final session = await FFprobeKit.getMediaInformation(inputPath);
    final mediaInfo = session.getMediaInformation();
    if (mediaInfo != null) {
      final streams = mediaInfo.getStreams();
      for (final stream in streams) {
        final w = stream.getWidth();
        final h = stream.getHeight();
        if (w != null && h != null && w > 0 && h > 0) {
          return VideoDimensions(w, h);
        }
      }
    }
  } catch (_) {}
  return VideoDimensions(0, 0);
}
