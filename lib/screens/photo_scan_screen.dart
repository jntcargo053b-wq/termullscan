import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gap/gap.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/scan_entry.dart';
import '../services/location_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../watermark/watermark_renderer.dart';
import '../watermark/watermark_settings.dart';
import 'watermark_settings_sheet.dart';
import 'package:device_info_plus/device_info_plus.dart';

class PhotoScanScreen extends StatefulWidget {
  const PhotoScanScreen({super.key});

  @override
  State<PhotoScanScreen> createState() => _PhotoScanScreenState();
}

class _PhotoScanScreenState extends State<PhotoScanScreen> {
  final ImagePicker _picker = ImagePicker();
  final StorageService _storage = StorageService();
  final Service _loc = Service();
  final WatermarkSettings _wmSettings = WatermarkSettings();

  bool _isSaving = false;
  int _photoCount = 0;
  bool _locationGranted = false;
  bool _cameraGranted = false;
  bool _settingsLoaded = false; // ✅ Tambahan

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initializeSettings(); // ✅ FIX: Panggil method async
  }

  // ✅ FIX: Inisialisasi settings dengan await
  Future<void> _initializeSettings() async {
    await _wmSettings.load();
    if (mounted) {
      setState(() {
        _settingsLoaded = true;
      });
    }
  }

  // ✅ FIX: Permission dengan photos untuk Android 13+
  Future<void> _requestPermissions() async {
    // Camera permission
    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      final result = await Permission.camera.request();
      if (mounted) {
        setState(() => _cameraGranted = result.isGranted);
      }
      if (!result.isGranted && mounted) {
        _showError('Izin kamera diperlukan untuk mengambil foto');
      }
    } else {
      if (mounted) {
        setState(() => _cameraGranted = true);
      }
    }

    // Location permission
    final locStatus = await Permission.location.status;
    if (!locStatus.isGranted) {
      final result = await Permission.location.request();
      if (mounted) {
        setState(() => _locationGranted = result.isGranted);
      }
      if (!result.isGranted && mounted) {
        _showError('Izin lokasi diperlukan untuk menandai foto');
      }
    } else {
      if (mounted) {
        setState(() => _locationGranted = true);
      }
    }

    // ✅ Photos permission untuk Android 13+
    if (await _isAndroid13OrHigher()) {
      final photosStatus = await Permission.photos.status;
      if (!photosStatus.isGranted) {
        await Permission.photos.request();
      }
    }
  }

  // ✅ Helper untuk deteksi Android 13+
  Future<bool> _isAndroid13OrHigher() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt >= 33;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ensureCameraPermission() async {
    if (_cameraGranted) return true;
    final status = await Permission.camera.status;
    if (status.isGranted) {
      if (mounted) {
        setState(() => _cameraGranted = true);
      }
      return true;
    }
    final result = await Permission.camera.request();
    final granted = result.isGranted;
    if (mounted) {
      setState(() => _cameraGranted = granted);
    }
    if (!granted) _showError('Izin kamera ditolak');
    return granted;
  }

  Future<bool> _ensureLocationPermission() async {
    if (_locationGranted) return true;
    final status = await Permission.location.status;
    if (status.isGranted) {
      if (mounted) {
        setState(() => _locationGranted = true);
      }
      return true;
    }
    final result = await Permission.location.request();
    final granted = result.isGranted;
    if (mounted) {
      setState(() => _locationGranted = granted);
    }
    if (!granted) _showError('Izin lokasi ditolak, foto tetap tersimpan tanpa lokasi');
    return granted;
  }

  // ✅ FIX: BottomSheet dengan mounted check
  void _openWatermarkSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const WatermarkSettingsSheet(),
    ).then((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  // ✅ FIX: Safe file deletion dengan cache check
  Future<String> _applyWatermark(String imagePath, DateTime timestamp,
      double? lat, double? lng) async {
    final outputPath =
        '${File(imagePath).parent.path}/wm_${DateTime.now().millisecondsSinceEpoch}.png';

    final result = await WatermarkRenderer.render(
      imagePath: imagePath,
      outputPath: outputPath,
      operatorName: _wmSettings.operatorName,
      style: _wmSettings.style,
      barcodeValue: null,
      barcodeFormat: null,
      timestamp: timestamp,
      latitude: lat,
      longitude: lng,
      locationName: null,
      logoPath: _wmSettings.hasLogo ? _wmSettings.logoPath : null,
    );

    // ✅ Hanya hapus jika file adalah cache internal
    if (result != null && result != imagePath) {
      final file = File(imagePath);
      try {
        final parentPath = file.parent.path.toLowerCase();
        if (parentPath.contains('cache') || 
            parentPath.contains('tmp') ||
            parentPath.contains('.cache')) {
          await file.delete();
          debugPrint('✅ Cache file deleted: $imagePath');
        } else {
          debugPrint('⏭️ Skipped deleting non-cache file: $imagePath');
        }
      } catch (e) {
        debugPrint('⚠️ Error deleting file: $e');
      }
    }

    return result ?? imagePath;
  }

  Future<void> _takePhoto() async {
    if (!await _ensureCameraPermission()) return;
    await _ensureLocationPermission();

    final XFile? xfile;
    try {
      xfile = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        imageQuality: 65,
        preferredCameraDevice: CameraDevice.rear,
      );
    } catch (e) {
      _showError('Gagal membuka kamera');
      return;
    }

    if (xfile == null) return;

    if (mounted) {
      setState(() => _isSaving = true);
    }

    try {
      HapticFeedback.mediumImpact();
      final timestamp = DateTime.now();

      ({double? lat, double? lng}) coords;
      try {
        coords =
            await _loc.getCoordinatesOnly().timeout(const Duration(seconds: 6));
      } catch (e) {
        debugPrint('Location timeout: $e');
        coords = (lat: null, lng: null);
      }

      final String watermarkedPath =
          await _applyWatermark(xfile.path, timestamp, coords.lat, coords.lng);

      final String savedPath = await _storage.savePhoto(watermarkedPath);
      if (savedPath.isEmpty) {
        throw Exception('Gagal menyimpan file foto');
      }

      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: savedPath,
        timestamp: timestamp,
        latitude: coords.lat,
        longitude: coords.lng,
        locationName: null,
      );
      await _storage.add(entry);

      if (mounted) {
        setState(() => _photoCount++);
      }

      if (coords.lat != null && coords.lng != null) {
        unawaited(_updateAddressLater(entry.id, coords.lat!, coords.lng!));
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Lokasi tidak tersedia, foto tersimpan tanpa lokasi'),
              duration: Duration(seconds: 2),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }

      if (mounted) _showSuccess(entry);
    } catch (e, stack) {
      debugPrint('Error in _takePhoto: $e\n$stack');
      _showError('Gagal memproses foto: ${e.toString().split(':').last}');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _pickFromGallery() async {
    await _ensureLocationPermission();

    final XFile? xfile;
    try {
      xfile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        imageQuality: 65,
      );
    } catch (e) {
      _showError('Gagal membuka galeri');
      return;
    }

    if (xfile == null) return;

    if (mounted) {
      setState(() => _isSaving = true);
    }

    try {
      final timestamp = DateTime.now();

      ({double? lat, double? lng}) coords;
      try {
        coords =
            await _loc.getCoordinatesOnly().timeout(const Duration(seconds: 6));
      } catch (e) {
        coords = (lat: null, lng: null);
      }

      final String watermarkedPath =
          await _applyWatermark(xfile.path, timestamp, coords.lat, coords.lng);

      final String savedPath = await _storage.savePhoto(watermarkedPath);
      final entry = ScanEntry(
        id: _storage.generateId(),
        type: ScanType.photo,
        value: savedPath,
        timestamp: timestamp,
        latitude: coords.lat,
        longitude: coords.lng,
        locationName: null,
      );
      await _storage.add(entry);

      if (mounted) {
        setState(() => _photoCount++);
      }

      if (coords.lat != null && coords.lng != null) {
        unawaited(_updateAddressLater(entry.id, coords.lat!, coords.lng!));
      }

      if (mounted) _showSuccess(entry);
    } catch (e, stack) {
      debugPrint('Error in _pickFromGallery: $e\n$stack');
      _showError('Gagal memproses foto dari galeri');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _updateAddressLater(
      String entryId, double lat, double lng) async {
    try {
      final address = await _loc.reverseGeocode(lat, lng).timeout(
            const Duration(seconds: 5),
          );
      if (address != null && mounted) {
        final entry = await _storage.getEntry(entryId);
        if (entry != null) {
          final updated = entry.copyWith(locationName: address);
          await _storage.update(updated);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('📍 Lokasi terdeteksi: $address'),
                duration: const Duration(seconds: 2),
                backgroundColor: Colors.green.shade700,
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('Reverse geocoding failed for $entryId: $e');
    }
  }

  void _showSuccess(ScanEntry entry) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 2),
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 18),
            const Gap(8),
            Expanded(
              child: Text(
                'Foto tersimpan  •  ${entry.locationName ?? entry.coordinatesString}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppTheme.error,
        content: Text(msg),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('Ambil Foto'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context, _photoCount),
        ),
        actions: [
          IconButton(
            onPressed: _openWatermarkSettings,
            icon: Stack(
              children: [
                const Icon(Icons.tune, color: Colors.white),
                if (_settingsLoaded && (_wmSettings.operatorName.isNotEmpty ||
                    _wmSettings.hasLogo))
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.amber,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            tooltip: 'Pengaturan Watermark',
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: AppTheme.accentOrange.withOpacity(0.1),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppTheme.accentOrange.withOpacity(0.4),
                    width: 2,
                  ),
                ),
                child: const Icon(Icons.camera_alt,
                    size: 52, color: AppTheme.accentOrange),
              ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),
              const Gap(24),
              Text(
                _photoCount == 0
                    ? 'Siap Ambil Foto'
                    : '$_photoCount foto tersimpan',
                style: Theme.of(context).textTheme.titleLarge,
              ).animate().fadeIn(delay: 100.ms),
              const Gap(8),
              Text(
                'Foto otomatis disertai timestamp, lokasi, & watermark',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ).animate().fadeIn(delay: 200.ms),
              const Gap(48),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isSaving ? null : _takePhoto,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2))
                      : const Icon(Icons.camera_alt, size: 22),
                  label:
                      Text(_isSaving ? 'Menyimpan...' : 'Ambil Foto Kamera'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentOrange,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    textStyle: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
              ).animate().fadeIn(delay: 250.ms),
              const Gap(14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _isSaving ? null : _pickFromGallery,
                  icon: const Icon(Icons.photo_library_outlined, size: 20),
                  label: const Text('Pilih dari Galeri'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.accentOrange,
                    side: BorderSide(
                        color: AppTheme.accentOrange.withOpacity(0.6)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ).animate().fadeIn(delay: 300.ms),
              const Gap(32),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: AppTheme.accentBlue),
                    Gap(10),
                    Expanded(
                      child: Text(
                        'Setiap foto otomatis dicatat: waktu, koordinat, nama lokasi, & watermark',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn(delay: 350.ms),
            ],
          ),
        ),
      ),
    );
  }
}
