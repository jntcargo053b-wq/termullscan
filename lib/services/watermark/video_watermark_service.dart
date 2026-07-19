 case WatermarkPosition.bottomLeft:
          x = '$padding';
          y = '(h-th)-$padding';
          break;
        case WatermarkPosition.topRight:
          x = '(w-tw)-$padding';
          y = '$padding';
          break;
        case WatermarkPosition.topLeft:
          x = '$padding';
          y = '$padding';
          break;
      }

      final fontSize = settings.fontSize;
      final opacity = settings.backgroundOpacity;

      String drawText =
          "drawtext=text='$text':"
          "fontcolor=white:"
          "fontsize=$fontSize:"
          "box=1:"
          "boxcolor=black@$opacity:"
          "boxborderw=5:"
          "x=$x:y=$y";

      final useHw = _shouldUseHardwareEncoder();
      final encoder = useHw ? 'h264_mediacodec' : 'libx264';
      final bitrateK = (videoInfo.bitrate / 1000).round();

      final commandArgs = <String>[
        '-i', inputPath,
        '-vf', 'format=${videoInfo.pixelFormat},setsar=1,$drawText',
        '-c:a', 'copy',
        '-c:v', encoder,
        '-b:v', '${bitrateK}k',
      ];

      if (!useHw) {
        final maxrateK = (videoInfo.bitrate * 1.5 / 1000).round();
        final bufsizeK = (videoInfo.bitrate * 2 / 1000).round();
        commandArgs.addAll(['-maxrate', '${maxrateK}k', '-bufsize', '${bufsizeK}k']);
      }

      commandArgs.addAll([
        '-pix_fmt', 'yuv420p',
        '-map_metadata', '0',
        '-movflags', '+faststart',
        '-y', outputPath,
      ]);

      debugPrint('🎬 Fallback: ${commandArgs.join(' ')}');

      final completer = Completer<String?>();
      Timer? timeoutTimer;

      FFmpegSession? session;
      try {
        session = await FFmpegKit.executeWithArguments(commandArgs);
        await _sessionLock.synchronized(() async {
          _currentSession = session;
        });

        timeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
          if (!completer.isCompleted) {
            debugPrint('⏱️ TIMEOUT: Fallback drawtext');
            if (_currentSession != null) {
              FFmpegKit.cancel(_currentSession!);
            }
            completer.complete(null);
          }
        });

        final returnCode = await session!.getReturnCode();
        timeoutTimer.cancel();

        await _sessionLock.synchronized(() async {
          _currentSession = null;
        });

        if (_isCancelled || completer.isCompleted) {
          completer.complete(null);
          return await completer.future;
        }

        if (ReturnCode.isSuccess(returnCode)) {
          debugPrint('✅ Fallback drawtext berhasil');
          completer.complete(outputPath);
        } else {
          final logs = await session!.getOutput();
          debugPrint('❌ Fallback drawtext error: $logs');
          lastError = logs;
          completer.complete(null);
        }
      } catch (e) {
        timeoutTimer?.cancel();
        _currentSession = null;
        debugPrint('❌ Fallback exception: $e');
        completer.complete(null);
      }

      return await completer.future;
    } catch (e) {
      debugPrint('❌ Fallback exception: $e');
      return null;
    } finally {
      _currentProgressCallback = null;
    }
  }

  static String _escapeDrawText(String text) {
    return text
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "'\\\\''")
        .replaceAll(':', '\\:')
        .replaceAll(',', '\\,')
        .replaceAll('[', '\\[')
        .replaceAll(']', '\\]')
        .replaceAll('%', '\\%');
  }

  // ─── RENDER OVERLAY ──────────────────────────────────────────
  static Future<(String?, int, int)?> _renderOverlay({
    required int outW,
    required int outH,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    final key = _getStableCacheKey(outW, outH, settings, entry);

    if (_overlayFileCache.containsKey(key)) {
      final cachedPath = _overlayFileCache[key]!;
      if (await File(cachedPath).exists()) {
        debugPrint('🔄 Menggunakan overlay dari cache (${outW}x${outH})');
        _overlayFileCache.remove(key);
        _overlayFileCache[key] = cachedPath;
        return (cachedPath, 0, 0);
      } else {
        _overlayFileCache.remove(key);
      }
    }

    debugPrint('🎨 Membuat overlay PNG ${outW}x${outH}...');
    final Uint8List? overlayBytes = await WatermarkRenderer.renderOverlayPng(
      canvasWidth: outW,
      canvasHeight: outH,
      settings: settings,
      entry: entry,
    );
    if (overlayBytes == null || overlayBytes.isEmpty) {
      debugPrint('❌ renderOverlayPng null');
      return null;
    }
    debugPrint('✅ Overlay PNG berhasil (${overlayBytes.length} bytes)');

    final cacheDir = await _getCacheDirectory();
    final fileName = 'overlay_$key.png';
    final filePath = '${cacheDir.path}/$fileName';
    await File(filePath).writeAsBytes(overlayBytes);

    _overlayFileCache[key] = filePath;
    if (_overlayFileCache.length > _maxCacheSize) _trimCache();

    return (filePath, 0, 0);
  }

  static String _getStableCacheKey(int outW, int outH, WatermarkSettings settings, ScanEntry entry) {
    final parts = [
      outW, outH,
      settings.style.name,
      settings.companyName,
      settings.operatorName,
      settings.position.name,
      settings.fontSize,
      settings.backgroundOpacity,
      settings.fontFamily,
      settings.logoPath ?? '',
      settings.hasLogo,
      entry.timestamp.toIso8601String(),
      entry.value,
      entry.barcodeFormat ?? '',
      entry.locationName ?? '',
      entry.latitude ?? '',
      entry.longitude ?? '',
    ].join('|');

    final bytes = utf8.encode(parts);
    final digest = sha1.convert(bytes);
    return digest.toString().substring(0, 16);
  }

  static Future<Directory> _getCacheDirectory() async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/watermark_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return cacheDir;
  }

  static void _trimCache() {
    if (_overlayFileCache.length <= _maxCacheSize) return;
    final entries = _overlayFileCache.entries.toList();
    final toRemove = entries.take(_overlayFileCache.length - _maxCacheSize);
    for (final entry in toRemove) {
      try { File(entry.value).deleteSync(); } catch (_) {}
      _overlayFileCache.remove(entry.key);
    }
  }

  // ─── PEMBERSIHAN CACHE OVERLAY ──────────────────────────────
  static Future<void> _cleanOrphanOverlayFiles() async {
    try {
      final cacheDir = await _getCacheDirectory();
      final files = cacheDir.listSync();
      final activeFiles = _overlayFileCache.values.toSet();

      int deleted = 0;
      for (final entity in files) {
        if (entity is File) {
          final path = entity.path;
          if (!activeFiles.contains(path)) {
            try {
              await entity.delete();
              deleted++;
            } catch (_) {}
          }
        }
      }
      if (deleted > 0) {
        debugPrint('🧹 Menghapus $deleted file overlay orphan dari disk');
      }
    } catch (e) {
      debugPrint('⚠️ Gagal membersihkan cache overlay: $e');
    }
  }

  // ─── DIAGNOSE ─────────────────────────────────────────────────
  static String diagnoseFailure(String logs) {
    final l = logs.toLowerCase();
    if (l.contains('overlay.png') && (l.contains('no such file') || l.contains('invalid data found'))) {
      return 'Overlay PNG watermark gagal dibuat/dibaca.';
    }
    if (l.contains('unknown encoder') || l.contains('encoder not found')) {
      return 'Encoder tidak tersedia. Coba gunakan software encoder.';
    }
    if (l.contains('invalid argument') && l.contains('overlay')) {
      return 'Argumen filter overlay tidak valid. Periksa ukuran watermark.';
    }
    if (l.contains('permission denied')) {
      return 'Tidak ada izin baca/tulis.';
    }
    if (l.contains('moov atom not found') || l.contains('invalid data found')) {
      return 'File video input korup.';
    }
    if (l.contains('cannot allocate memory')) {
      return 'Memori tidak cukup. Turunkan resolusi atau bitrate.';
    }
    if (l.contains('broken pipe')) {
      return 'Proses encoding terputus.';
    }
    if (l.contains('too many packets buffered')) {
      return 'Buffer FFmpeg penuh. Kurangi thread atau pakai preset lebih lambat.';
    }
    if (l.contains('cannot init encoder')) {
      return 'Encoder gagal diinisialisasi. Coba software encoder.';
    }
    if (l.contains('error while opening encoder')) {
      return 'Gagal membuka encoder. Periksa parameter.';
    }
    if (l.contains('no space left on device')) {
      return 'Ruang penyimpanan tidak cukup.';
    }
    if (l.contains('timeout')) {
      return 'Encoding timeout. Coba gunakan preset lebih cepat.';
    }
    if (l.contains('cancelled') || l.contains('canceled')) {
      return 'Proses encoding dibatalkan.';
    }
    return 'Penyebab tidak dikenal. Cek log lengkap.';
  }
}

// ─── ASYNC LOCK ──────────────────────────────────────────────
class _AsyncLock {
  Future<void>? _lockFuture;

  Future<T> synchronized<T>(Future<T> Function() action) {
    final previousLock = _lockFuture;
    final completer = Completer<T>();

    
