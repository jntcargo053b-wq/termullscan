import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<bool> isAndroid13OrHigher() async {
    if (!Platform.isAndroid) return false;
    final info = await DeviceInfoPlugin().androidInfo;
    return info.version.sdkInt >= 33;
  }
}
