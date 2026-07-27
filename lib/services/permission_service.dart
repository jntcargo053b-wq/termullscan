// ============================================================
// lib/services/permission_service.dart (FINAL - tanpa mediaVisualUserSelected)
// ============================================================
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<bool> isAndroid13OrHigher() async {
    if (!Platform.isAndroid) return false;
    final info = await DeviceInfoPlugin().androidInfo;
    return info.version.sdkInt >= 33;
  }

  static Future<bool> requestGalleryPermission({
    bool skipIfExists = false,
  }) async {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      final sdkInt = info.version.sdkInt;
      // Menulis file baru lewat MediaStore tidak membutuhkan permission pada
      // Android 10+. Read permission hanya diperlukan untuk cek duplikat.
      if (sdkInt >= 29 && !skipIfExists) return true;
      if (sdkInt >= 33) {
        final photos = await Permission.photos.request();
        final videos = await Permission.videos.request();
        return photos.isGranted && videos.isGranted;
      }
      return (await Permission.storage.request()).isGranted;
    }
    if (Platform.isIOS) {
      final permission =
          skipIfExists ? Permission.photos : Permission.photosAddOnly;
      return (await permission.request()).isGranted;
    }
    return false;
  }

  static Future<void> requestAllPermissions() async {
    await Permission.camera.request();
    await requestGalleryPermission();
  }
}
