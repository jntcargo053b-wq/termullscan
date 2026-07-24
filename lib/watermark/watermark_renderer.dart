import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../models/scan_entry.dart';
import 'models/watermark_data.dart';
import 'watermark_factory.dart';
import 'watermark_settings.dart';

class WatermarkRenderer {
  /// Diisi setiap render() dipanggil (null jika berhasil, terisi jika
  /// gagal). Dipakai pemanggil (photo_scan_screen.dart) untuk
  /// menampilkan alasan kegagalan ke user, alih-alih diam-diam
  /// menyimpan foto tanpa watermark seperti sebelumnya.
  static String? lastError;

  // ─── CACHE LOGO (SEKALI PER SESI, BUKAN PER RENDER) ────────
  // ✅ FIX: dulu setiap render() (baik foto maupun overlay video)
  // selalu baca ulang file logo dari disk + decode ulang, walau logo
  // yang dipakai SAMA PERSIS antar pemanggilan. Ini kerja berulang
  // yang paling terasa saat batch foto (beberapa foto per barcode) —
  // logo perusahaan yang sama di-decode ulang untuk tiap foto. Logo
  // hasil decode berukuran kecil (di-clamp 40–200px), jadi aman
  // disimpan resident di memory selama path & targetWidth-nya sama;
  // begitu logo diganti (path baru dari image_picker selalu unik) key
  // otomatis beda dan cache lama diganti.
  static ui.Image? _cachedLogoImage;
  static String? _cachedLogoKey;

  static Future<ui.Image?> _getLogoImage(
    String logoPath, {
    required int targetWidth,
  }) async {
    final key = '$logoPath|$targetWidth';
    if (_cachedLogoKey == key && _cachedLogoImage != null) {
      return _cachedLogoImage;
    }

    final codec = await _loadLogoCodec(logoPath, targetWidth: targetWidth);
    if (codec == null) return null;
    final frame = await codec.getNextFrame();
    codec.dispose();

    // Ganti cache: lepas gambar lama (kalau ada) sebelum simpan yang baru.
    _cachedLogoImage?.dispose();
    _cachedLogoImage = frame.image;
    _cachedLogoKey = key;
    return _cachedLogoImage;
  }

  /// Panggil kalau perlu paksa lepas cache logo (mis. saat memory
  /// warning atau app dimatikan). Tidak wajib dipanggil saat user
  /// ganti logo — path baru dari image picker selalu unik sehingga
  /// cache lama otomatis tidak terpakai lagi.
  static void clearLogoCache() {
    _cachedLogoImage?.dispose();
    _cachedLogoImage = null;
    _cachedLogoKey = null;
  }

  /// Render watermark ke file output (FOTO)
  static Future<String?> render({
    required String imagePath,
    required String outputPath,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    lastError = null;
    if (kDebugMode) {
      debugPrint('🎯 WATERMARK RENDER START');
      debugPrint('  Style: ${settings.style.name}');
    }

    ui.Image? srcImage;
    ui.Image? logoImage;
    ui.Codec? codec;
    ui.Image? outputImage;

    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        lastError = 'File foto sumber tidak ditemukan';
        debugPrint('❌ File tidak ditemukan: $imagePath');
        return null;
      }

      final imageBytes = await file.readAsBytes();

      codec = await ui.instantiateImageCodec(
        imageBytes,
        targetWidth: 1600,
      );
      final frame = await codec.getNextFrame();
      srcImage = frame.image;
      codec.dispose();
      codec = null;

      final photoWidth = srcImage.width.toDouble();
      final photoHeight = srcImage.height.toDouble();

      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoImage = await _getLogoImage(settings.logoPath!, targetWidth: 1600);
      }

      final data = WatermarkData(
        timestamp: entry.timestamp,
        operatorName: settings.operatorName,
        companyName: settings.companyName,
        barcodeValue: entry.value,
        barcodeFormat: entry.barcodeFormat,
        latitude: entry.latitude,
        longitude: entry.longitude,
        locationName: entry.locationName,
        logoPath: settings.logoPath,
        position: settings.position,
        fontSize: settings.fontSize,
        backgroundOpacity: settings.backgroundOpacity,
        fontFamily: settings.fontFamily,
      );

      final layout = WatermarkFactory.create(settings.style);
      final metrics = layout.computeMetrics(
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        data: data,
      );

      if (metrics.canvasWidth <= 0 || metrics.canvasHeight <= 0) {
        throw Exception('Canvas size invalid');
      }

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      layout.paintOnCanvas(
        canvas: canvas,
        metrics: metrics,
        srcImage: srcImage,
        photoWidth: photoWidth,
        photoHeight: photoHeight,
        logoImage: logoImage,
        data: data,
      );

      final picture = recorder.endRecording();
      outputImage = await picture.toImage(
        metrics.canvasWidth.round(),
        metrics.canvasHeight.round(),
      );

      // ✅ FIX PERFORMA: dulu di-encode PNG (lossless, besar) di sini,
      // padahal ImageCompressor sebelumnya sudah mengecilkan foto ke
      // target KB dalam bentuk JPEG — manfaat itu hilang lagi karena
      // hasil akhir yang benar-benar disimpan/di-export ke gallery
      // adalah PNG yang jauh lebih besar (bisa 3-10x lipat), sehingga
      // tulis-disk, pindah ke storage internal, dan terutama export ke
      // gallery (copy ke MediaStore) jadi lebih lambat tanpa menambah
      // kualitas visual yang benar-benar terlihat (ini foto natural +
      // teks, bukan grafis dengan area flat besar yang diuntungkan PNG).
      // Ambil raw RGBA dulu (masih di main isolate, murni memory copy,
      // cepat), lalu encode ke JPEG di ISOLATE TERPISAH via compute()
      // supaya proses encode (yang bisa berat utk foto besar) tidak
      // memblokir UI thread.
      final rawBytes = await outputImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      final outWidth = outputImage.width;
      final outHeight = outputImage.height;
      outputImage.dispose();
      outputImage = null;

      if (rawBytes == null) {
        lastError = 'Gagal membaca hasil watermark (raw RGBA)';
        debugPrint('❌ Gagal membaca raw RGBA hasil watermark');
        return null;
      }

      final jpegBytes = await compute(
        _encodeWatermarkJpeg,
        _JpegEncodeArgs(
          rgbaBytes: rawBytes.buffer.asUint8List(),
          width: outWidth,
          height: outHeight,
          quality: 92,
        ),
      );

      if (jpegBytes == null) {
        lastError = 'Gagal meng-encode JPEG hasil watermark';
        debugPrint('❌ Gagal encode JPEG');
        return null;
      }

      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(jpegBytes);

      if (kDebugMode) debugPrint('✅ Watermark saved (JPEG): $outputPath');
      return outputPath;
    } catch (e, stack) {
      lastError = e.toString();
      if (kDebugMode) debugPrint('❌ Error: $e\n$stack');
      return null;
    } finally {
      codec?.dispose();
      srcImage?.dispose();
      // ✅ logoImage TIDAK di-dispose di sini lagi — itu instance cache
      // yang dipakai ulang lintas pemanggilan render() (lihat
      // _getLogoImage). Dispose-nya ditangani _getLogoImage sendiri
      // saat cache diganti, atau lewat clearLogoCache() saat memory
      // warning/app dimatikan.
      outputImage?.dispose();
    }
  }

  // ─── RENDER OVERLAY PNG UNTUK VIDEO ────────────────────
  /// Generate overlay PNG (full-frame, transparan) untuk video.
  static Future<Uint8List?> renderOverlayPng({
    required int canvasWidth,
    required int canvasHeight,
    required WatermarkSettings settings,
    required ScanEntry entry,
  }) async {
    ui.Image? logoImage;
    ui.Image? outputImage;

    try {
      if (settings.hasLogo && settings.logoPath != null && settings.logoPath!.isNotEmpty) {
        logoImage = await _getLogoImage(settings.logoPath!, targetWidth: canvasWidth);
      }

      final data = WatermarkData(
        timestamp: entry.timestamp,
        operatorName: settings.operatorName,
        companyName: settings.companyName,
        barcodeValue: entry.value,
        barcodeFormat: entry.barcodeFormat,
        latitude: entry.latitude,
        longitude: entry.longitude,
        locationName: entry.locationName,
        logoPath: settings.logoPath,
        position: settings.position,
        fontSize: settings.fontSize,
        backgroundOpacity: settings.backgroundOpacity,
        fontFamily: settings.fontFamily,
      );

      final layout = WatermarkFactory.create(settings.style);

      // ✅ Guard eksplisit: sebagian gaya (mis. Polaroid) menambahkan
      // border/strip di sekeliling foto sehingga canvas-nya LEBIH BESAR
      // dari frame video — secara struktural tidak bisa dipakai sebagai
      // overlay video (overlay wajib berukuran identik dengan frame).
      // Daripada memanggil paintWatermarkOnly() dan menangkap
      // UnimplementedError (yang tetap membuang waktu decode logo di
      // atas), kita deteksi lebih awal supaya pemanggil langsung tahu
      // dan bisa fallback ke drawtext tanpa proses sia-sia.
      if (!layout.supportsVideoOverlay) {
        debugPrint(
          '⚠️ Gaya "${settings.style.name}" tidak kompatibel dengan overlay video '
          '(canvas lebih besar dari frame) — fallback ke drawtext.',
        );
        return null;
      }

      final metrics = layout.computeMetrics(
        photoWidth: canvasWidth.toDouble(),
        photoHeight: canvasHeight.toDouble(),
        data: data,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      // HANYA GAMBAR ELEMEN WATERMARK TANPA FOTO LATAR
      layout.paintWatermarkOnly(
        canvas: canvas,
        metrics: metrics,
        logoImage: logoImage,
        data: data,
      );

      final picture = recorder.endRecording();
      outputImage = await picture.toImage(
        metrics.canvasWidth.round(),
        metrics.canvasHeight.round(),
      );
      final byteData = await outputImage.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('❌ Gagal render overlay PNG: $e');
      return null;
    } finally {
      // ✅ logoImage TIDAK di-dispose di sini lagi — instance cache
      // bersama, lihat _getLogoImage/clearLogoCache di atas.
      outputImage?.dispose();
    }
  }

  // ─── LOAD LOGO ──────────────────────────────────────────
  static Future<ui.Codec?> _loadLogoCodec(
    String logoPath, {
    required int targetWidth,
  }) async {
    try {
      final logoFile = File(logoPath);
      if (!await logoFile.exists()) return null;

      final logoBytes = await logoFile.readAsBytes();
      final logoTargetWidth = (targetWidth * 0.15).round().clamp(40, 200);
      return await ui.instantiateImageCodec(
        logoBytes,
        targetWidth: logoTargetWidth,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error memuat logo: $e');
      return null;
    }
  }
}

// ─── ENCODE JPEG DI ISOLATE (untuk hasil watermark FOTO) ─────────
// Dipisah jadi top-level function (bukan method) supaya bisa dikirim
// ke isolate lewat compute() — sama pola dengan ImageCompressor.
class _JpegEncodeArgs {
  final Uint8List rgbaBytes;
  final int width;
  final int height;
  final int quality;

  _JpegEncodeArgs({
    required this.rgbaBytes,
    required this.width,
    required this.height,
    required this.quality,
  });
}

Uint8List? _encodeWatermarkJpeg(_JpegEncodeArgs args) {
  try {
    final image = img.Image.fromBytes(
      width: args.width,
      height: args.height,
      bytes: args.rgbaBytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodeJpg(image, quality: args.quality));
  } catch (e) {
    // Tidak pakai debugPrint di sini karena ini jalan di isolate
    // terpisah — kDebugMode/debugPrint bisa tidak konsisten di luar
    // isolate utama. Kegagalan cukup dikembalikan sebagai null;
    // pemanggil (render()) yang menangani sebagai error.
    return null;
  }
}
