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
import '../services/watermark_service.dart';
import '../theme/app_theme.dart';
import '../watermark/watermark_settings.dart';   // ✅ WatermarkSettings
import 'watermark_settings_sheet.dart';          // ✅ WatermarkSettingsSheet

class PhotoScanScreen extends StatefulWidget {
  const PhotoScanScreen({super.key});

  @override
  State<PhotoScanScreen> createState() => _PhotoScanScreenState();
}

class _PhotoScanScreenState extends State<PhotoScanScreen> {
  final ImagePicker _picker = ImagePicker();
  final StorageService _storage = StorageService();
  final Service _loc = Service();
  final WatermarkService _watermarkService = WatermarkService();
  final WatermarkSettings _wmSettings = WatermarkSettings();

  bool _isSaving = false;
  int _photoCount = 0;
  bool _locationGranted = false;
  bool _cameraGranted = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _wmSettings.load();
  }

  Future<void> _requestPermissions() async {
    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      final result = await Permission.camera.request();
      setState(() => _cameraGranted = result.isGranted);
      if (!result.isGranted && mounted) {
        _showError('Izin kamera diperlukan untuk mengambil foto');
      }
    } else {
      setState(() => _cameraGranted = true);
    }

    final locStatus = await Permission.location.status;
    if (!locStatus.isGranted) {
      final result = await Permission.location.request();
      setState(() => _locationGranted = result.isGranted);
      if (!result.isGranted && mounted) {
        _showError('Izin lokasi diperlukan untuk menandai foto');
      }
    } else {
      setState(() => _locationGranted = true);
    }
  }

  Future<bool> _ensureCameraPermission() async {
    if (_cameraGranted) return true;
    final status = await Permission.camera.status;
    if (status.isGranted) {
      setState(() => _cameraGranted = true);
      return true;
    }
    final result = await Permission.camera.request();
    final granted = result.isGranted;
    setState(() => _cameraGranted = granted);
    if (!granted) _showError('Izin kamera ditolak');
    return granted;
  }

  Future<bool> _ensurePermission() async {
    if (_locationGranted) return true;
    final status = await Permission.location.status;
    if (status.isGranted) {
      setState(() => _locationGranted = true);
      return true;
    }
    final result = await Permission.location.request();
    final granted = result.isGranted;
    setState(() => _locationGranted = granted);
    if (!granted) _showError('Izin lokasi ditolak, foto tetap tersimpan tanpa ');
    return granted;
  }

  void _openWatermarkSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const WatermarkSettingsSheet(),
    ).then((_) => setState(() {}));
  }

  Future<String> _applyWatermark(String imagePath, DateTime timestamp,
      double? lat, double? lng) async {
    final outputPath =
        '${File(imagePath).parent.path}/wm_${DateTime.now().millisecondsSinceEpoch}.png';

    final result = await _watermarkService.addWatermark(
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

    if (result != null && result != imagePath) {
      try {
        await File(imagePath).delete();
      } catch (_) {}
    }

    return result ?? imagePath;
  }

  Future<void> _takePhoto() async {
    if (!await _ensureCameraPermission()) return;
    await _ensurePermission();

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

    setState(() => _isSaving = true);

    try {
      HapticFeedback.mediumImpact();
      final timestamp = DateTime.now();

      ({double? lat, double? lng}) coords;
      try {
        coords =
            await _loc.getCoordinatesOnly().timeout(const Duration(seconds: 6));
      } catch (e) {
        debugPrint(' timeout: $e');
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

      setState(() => _photoCount++);

      if (coords.lat != null && coords.lng != null) {
        unawaited(_updateAddressLater(entry.id, coords.lat!, coords.lng!));
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️  tidak tersedia, foto tersimpan tanpa lokasi'),
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
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _pickFromGallery() async {
    await _ensurePermission();

    final XFile? xfile;
    try {
      xfile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        imageQuality: 65,
