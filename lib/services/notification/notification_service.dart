// lib/services/notification/notification_service.dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const AndroidInitializationSettings initSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: initSettings));
  }

  static Future<void> showCompletion(String title, String body) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'video_channel',
      'Video Processing',
      importance: Importance.high,
      priority: Priority.high,
    );
    await _plugin.show(0, title, body, const NotificationDetails(android: androidDetails));
  }
}
