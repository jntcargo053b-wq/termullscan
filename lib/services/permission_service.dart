import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<bool> isAndroid13OrHigher() async {
    final info = await DeviceInfoPlugin().androidInfo;
    return info.version.sdkInt >= 33;
  }

  static Future<bool> requestGalleryPermission() async {
    if (await isAndroid13OrHigher()) {
      return (await Permission.photos.request()).isGranted;
    }

    return (await Permission.storage.request()).isGranted;
  }
}
