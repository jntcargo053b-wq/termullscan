// lib/services/thumbnail_cache_service.dart
//
// Menyelesaikan 3 concern yang diminta untuk daftar video:
//
// 1. Lazy loading
//    Thumbnail hanya diminta ("getThumbnail") dari dalam FutureBuilder
//    milik setiap item ListView.builder. Karena ListView.builder sendiri
//    lazy (hanya membangun item yang terlihat), thumbnail otomatis hanya
//    diproses untuk video yang benar-benar tampil di layar, bukan seluruh
//    daftar sekaligus.
//
// 2. Background isolate
//    Pembacaan file (File.readAsBytes) dan pemanggilan
//    VideoThumbnail.thumbnailData keduanya asynchronous dan dieksekusi
//    lewat platform channel di sisi native — tidak memblok UI thread Dart.
//    Catatan jujur: kita TIDAK membungkusnya dengan `compute()` murni,
//    karena compute() menjalankan isolate baru yang oleh default tidak
//    punya akses platform channel (butuh
//    BackgroundIsolateBinaryMessenger.ensureInitialized yang menambah
//    kompleksitas tanpa manfaat nyata di sini, sebab pekerjaan berat
//    (decode video) sudah dilakukan di sisi native/off-main-thread oleh
//    plugin video_thumbnail itu sendiri). Jika di masa depan ditambahkan
//    pemrosesan berat murni-Dart (mis. filter piksel manual), barulah
//    compute()/isolate terpisah benar-benar diperlukan.
//
// 3. Cache frame
//    Hasil thumbnail (bytes) disimpan di in-memory LRU cache agar scroll
//    bolak-balik tidak membaca ulang file atau generate ulang. Request
//    yang tumpang tindih (scroll cepat) di-dedupe lewat `_inFlight`.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:video_thumbnail/video_thumbnail.dart';

class ThumbnailCacheService {
  ThumbnailCacheService._();
  static final ThumbnailCacheService instance = ThumbnailCacheService._();

  static const int _maxMemoryEntries = 80;

  final LinkedHashMap<String, Uint8List> _memoryCache =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<Uint8List?>> _inFlight = {};

  /// Ambil bytes thumbnail untuk satu entry video.
  /// - [existingThumbnailPath]: path thumbnail yang sudah pernah dibuat
  ///   (mis. saat rekam video, lihat video_scan_screen.dart).
  /// - [videoPath]: dipakai sebagai fallback jika thumbnail belum ada
  ///   (mis. gagal dibuat saat rekam) atau sebagai cache key kalau
  ///   thumbnail path null.
  Future<Uint8List?> getThumbnail({
    required String? existingThumbnailPath,
    required String? videoPath,
  }) async {
    final cacheKey = existingThumbnailPath ?? videoPath;
    if (cacheKey == null) return null;

    // 1. Cache hit → langsung balikin, sekalian refresh posisi LRU.
    final cached = _memoryCache.remove(cacheKey);
    if (cached != null) {
      _memoryCache[cacheKey] = cached;
      return cached;
    }

    // 2. Kalau sedang diproses (mis. scroll cepat memicu build 2x),
    //    ikut Future yang sama, jangan generate dobel.
    final inFlight = _inFlight[cacheKey];
    if (inFlight != null) return inFlight;

    final future = _load(existingThumbnailPath, videoPath);
    _inFlight[cacheKey] = future;
    try {
      final bytes = await future;
      if (bytes != null) _store(cacheKey, bytes);
      return bytes;
    } finally {
      _inFlight.remove(cacheKey);
    }
  }

  Future<Uint8List?> _load(String? thumbPath, String? videoPath) async {
    try {
      // Sudah ada file thumbnail hasil generate saat rekam → baca saja.
      if (thumbPath != null) {
        final f = File(thumbPath);
        if (await f.exists()) {
          return await f.readAsBytes();
        }
      }
      // Fallback: thumbnail belum pernah dibuat (mis. gagal saat proses
      // rekam) → generate on-demand, hanya untuk item yang sedang tampil.
      if (videoPath != null && await File(videoPath).exists()) {
        return await VideoThumbnail.thumbnailData(
          video: videoPath,
          imageFormat: ImageFormat.JPEG,
          maxHeight: 200,
          quality: 70,
        );
      }
    } catch (_) {
      // Diamkan — UI akan fallback ke ikon default, jangan sampai
      // satu thumbnail rusak menjatuhkan seluruh list.
    }
    return null;
  }

  void _store(String key, Uint8List bytes) {
    if (_memoryCache.length >= _maxMemoryEntries) {
      _memoryCache.remove(_memoryCache.keys.first); // buang yang paling lama
    }
    _memoryCache[key] = bytes;
  }

  /// Panggil kalau perlu bebaskan memory (mis. saat logout / reset data).
  void clear() {
    _memoryCache.clear();
  }
}
