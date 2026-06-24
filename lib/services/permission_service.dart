// ============================================================
// lib/services/permission_service.dart (FINAL - tanpa mediaVisualUserSelected)
// ============================================================
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<bool> isAndroid13OrHigher() async {
    final info = await DeviceInfoPlugin().androidInfo;
    return info.version.sdkInt >= 33;
  }

  static Future<bool> requestGalleryPermission() async {
    if (await isAndroid13OrHigher()) {
      // Android 13+ butuh photos dan videos
      final photos = await Permission.photos.request();
      final videos = await Permission.videos.request();
      return photos.isGranted && videos.isGranted;
    }
    // Android 12 ke bawah pakai storage
    return (await Permission.storage.request()).isGranted;
  }

  static Future<void> requestAllPermissions() async {
    await Permission.camera.request();
    await requestGalleryPermission();
  }
}
