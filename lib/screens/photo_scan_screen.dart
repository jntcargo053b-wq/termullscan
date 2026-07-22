// ============================================================
// lib/screens/photo_scan_screen.dart (FIXED)
// ============================================================

// ─── Cari dan ubah bagian _applyWatermark ────────────────────

Future<String> _applyWatermark(String imagePath, DateTime timestamp, int photoIndex) async {
  final fileName = _resolveFileName(photoIndex);
  final outputPath =
      '${File(imagePath).parent.path}/wm_${DateTime.now().millisecondsSinceEpoch}.png';

  final locState = _wmSettings.gpsWatermarkEnabled
      ? PodLocationService.instance.currentState
      : null;
      
  // 🔥 FIXED
  final tempEntry = ScanEntry(
    id: _storage.generateId(),
    type: ScanType.image, // ← BUKAN ScanType.photo!
    value: fileName,
    // barcodeFormat: null, // ← HAPUS!
    timestamp: timestamp,
    operatorName: _wmSettings.operatorName.isNotEmpty 
        ? _wmSettings.operatorName 
        : 'Operator',
    companyName: _wmSettings.companyName,
    latitude: locState?.lat,
    longitude: locState?.lon,
    locationName: (locState != null && locState.address.isNotEmpty) ? locState.address : null,
    isManual: false,
  );

  final result = await WatermarkRenderer.render(
    imagePath: imagePath,
    outputPath: outputPath,
    settings: _wmSettings,
    entry: tempEntry,
  );

  if (result == null) {
    final diagnosis = WatermarkRenderer.lastError;
    throw Exception(
      diagnosis != null ? 'Watermark foto gagal: $diagnosis' : 'Watermark foto gagal',
    );
  }

  if (result != imagePath) {
    final file = File(imagePath);
    try {
      if (await FileHelper.isTemporaryFile(imagePath)) {
        await file.delete();
        debugPrint('✅ Cache file deleted: $imagePath');
      }
    } catch (e) {
      debugPrint('⚠️ Error deleting file: $e');
    }
  }

  return result;
}

// ─── Cari dan ubah bagian _finalizePhoto ─────────────────────

Future<String> _finalizePhoto(
  String watermarkedPath,
  String pendingPath,
  int photoIndex,
) async {
  try {
    // ─── 1. Verifikasi file watermark ──────────────────────────
    final watermarkedFile = File(watermarkedPath);
    if (!await watermarkedFile.exists()) {
      throw Exception('File watermark tidak ditemukan: $watermarkedPath');
    }
    final watermarkSize = await watermarkedFile.length();
    if (watermarkSize == 0) {
      throw Exception('File watermark kosong: $watermarkedPath');
    }

    // ─── 2. Simpan ke internal ────────────────────────────────
    final name = _resolveFileName(photoIndex);
    final savedPath = await _storage.savePhoto(watermarkedPath, name: name);
    if (savedPath.isEmpty) {
      throw Exception('Gagal menyimpan file foto internal');
    }
    final savedFile = File(savedPath);
    if (!await savedFile.exists()) {
      throw Exception('File internal tidak ditemukan setelah save: $savedPath');
    }
    debugPrint('✅ Internal save OK: $savedPath');

    // ─── 3. Hapus file watermark temp & pending asli ──────────
    if (watermarkedPath != savedPath && await File(watermarkedPath).exists()) {
      try { await File(watermarkedPath).delete(); } catch (_) {}
    }
    if (pendingPath != savedPath && await File(pendingPath).exists()) {
      try { await File(pendingPath).delete(); } catch (_) {}
    }

    // ─── 4. Update database jika ada entryId ──────────────────
    if (widget.entryId != null) {
      final barcodeEntry = await _storage.getEntry(widget.entryId!);
      if (barcodeEntry != null) {
        // 🔥 FIXED: photoPaths adalah getter, bukan field
        // Simpan photoPaths sebagai CSV di imagePath
        final allPaths = [..._photoPaths, savedPath];
        final updated = barcodeEntry.copyWith(
          imagePath: allPaths.join(','), // Simpan sebagai CSV
        );
        await _storage.update(updated);
      }
    }

    // ─── 5. Simpan ke gallery ──────────────────────────────────
    final galleryOk = await _saveToGallery(savedPath);
    if (!galleryOk) {
      debugPrint('⚠️ Gagal ekspor ke gallery, file tetap tersimpan di internal');
    }

    // ─── 6. Notifikasi batch ──────────────────────────────────
    if (widget.batchMode && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📸 Foto $photoIndex berhasil (${widget.barcode ?? 'tanpa barcode'})'),
          duration: const Duration(seconds: 1),
          backgroundColor: AppTheme.success,
        ),
      );
    }

    return savedPath;
  } catch (e, stack) {
    debugPrint('❌ Error finalisasi foto #$photoIndex ($watermarkedPath): $e\n$stack');
    rethrow;
  }
}

// ─── Cari dan ubah bagian _finishBatch ──────────────────────

Future<void> _finishBatch() async {
  if (widget.entryId != null && _photoPaths.isNotEmpty) {
    if (!mounted) return;
    final barcodeEntry = await _storage.getEntry(widget.entryId!);
    if (barcodeEntry != null && mounted) {
      // 🔥 FIXED: photoPaths adalah getter, bukan field
      final updated = barcodeEntry.copyWith(
        imagePath: _photoPaths.join(','), // Simpan sebagai CSV
      );
      await _storage.update(updated);
    }
  }

  if (_photoPaths.isNotEmpty) {
    await _showBatchSummaryAndPop();
  } else {
    if (mounted) Navigator.pop(context, {'count': _photoCount, 'paths': _photoPaths});
  }
}

// ─── Cari dan ubah bagian _applyWatermark ────────────────────

// Pastikan juga di bagian lain yang menggunakan ScanType.photo
// diubah menjadi ScanType.image

// 🔥 PERIKSA: ScanEntry yang dibuat di tempat lain
// pastikan semua menggunakan:
// - type: ScanType.image (bukan ScanType.photo)
// - tidak ada parameter barcodeFormat
// - ada operatorName (WAJIB)
