import 'package:flutter/material.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Layanan OTA update (Shorebird Code Push).
///
/// PENTING — batasan yang WAJIB dipahami sebelum pakai ini:
/// 1. Shorebird hanya bisa nge-patch kode DART. Perubahan native (folder
///    android/, plugin baru di pubspec.yaml, permission baru di
///    AndroidManifest, ASSET baru/berubah) TIDAK bisa lewat patch — itu
///    tetap wajib rilis APK baru + install ulang seperti biasa.
/// 2. Patch baru baru aktif setelah aplikasi di-restart (bukan hot-swap
///    saat itu juga). Kita kasih notifikasi, user yang tutup-buka lagi.
/// 3. Kalau APK di-build dengan `flutter build apk` biasa (bukan lewat CLI
///    `shorebird`), updater ini otomatis `isAvailable == false`. Aman —
///    tidak ada error, tidak ada network call, tidak memengaruhi apa pun.
///    Jadi build CI yang sekarang (build.yml) tetap jalan seperti biasa.
class UpdateService {
  UpdateService._();

  static final ShorebirdUpdater _updater = ShorebirdUpdater();

  /// Dipasang di MaterialApp.scaffoldMessengerKey supaya banner update bisa
  /// dimunculkan dari mana saja (main.dart), tanpa BuildContext lokal.
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static bool _checkedThisSession = false;

  /// Panggil sekali saat startup, SETELAH frame pertama (jangan di-await
  /// di initState utama — ini melakukan network call yang bisa lambat/
  /// gagal kalau sinyal jelek, dan tidak boleh menahan splash screen).
  static Future<void> checkOnStartup() async {
    if (_checkedThisSession) return;
    _checkedThisSession = true;

    if (!_updater.isAvailable) {
      debugPrint(
        'ℹ️ [UpdateService] Shorebird updater tidak aktif di build ini '
        '(APK dibuild tanpa CLI shorebird — normal untuk build lokal/CI biasa).',
      );
      return;
    }

    try {
      final status = await _updater.checkForUpdate();
      debugPrint('🔄 [UpdateService] status: $status');

      switch (status) {
        case UpdateStatus.outdated:
          await _downloadAndNotify();
          break;
        case UpdateStatus.restartRequired:
          _notifyRestartRequired();
          break;
        case UpdateStatus.upToDate:
        case UpdateStatus.unavailable:
          break;
      }
    } catch (e) {
      debugPrint('⚠️ [UpdateService] Gagal cek update: $e');
    }
  }

  static Future<void> _downloadAndNotify() async {
    try {
      await _updater.update();
      _notifyRestartRequired();
    } catch (e) {
      debugPrint('⚠️ [UpdateService] Gagal download patch: $e');
    }
  }

  static void _notifyRestartRequired() {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          content: const Text(
            'Update tersedia. Tutup & buka lagi aplikasi untuk menerapkan '
            'perubahan terbaru.',
          ),
          actions: [
            TextButton(
              onPressed: () => messenger.hideCurrentMaterialBanner(),
              child: const Text('NANTI'),
            ),
          ],
        ),
      );
  }

  /// Untuk dipanggil dari tombol "Cek Update" manual (mis. di halaman
  /// pengaturan/settings), kalau ingin kasih feedback eksplisit ke user.
  static Future<String> checkManually() async {
    if (!_updater.isAvailable) {
      return 'Update OTA tidak tersedia di build ini.';
    }
    try {
      final status = await _updater.checkForUpdate();
      switch (status) {
        case UpdateStatus.upToDate:
          return 'Aplikasi sudah versi terbaru.';
        case UpdateStatus.outdated:
          await _downloadAndNotify();
          return 'Update ditemukan & sedang diunduh. Restart aplikasi setelah selesai.';
        case UpdateStatus.restartRequired:
          _notifyRestartRequired();
          return 'Update sudah terunduh. Restart aplikasi untuk menerapkan.';
        case UpdateStatus.unavailable:
          return 'Update OTA tidak tersedia saat ini.';
      }
    } catch (e) {
      return 'Gagal cek update: $e';
    }
  }

  /// Nomor patch yang sedang berjalan, buat ditampilkan di halaman
  /// "Tentang Aplikasi" (null kalau updater tidak aktif).
  static Future<int?> currentPatchNumber() async {
    if (!_updater.isAvailable) return null;
    try {
      final patch = await _updater.readCurrentPatch();
      return patch?.number;
    } catch (_) {
      return null;
    }
  }
}
