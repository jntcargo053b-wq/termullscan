// ============================================================
// lib/services/location_service.dart (FINAL - dengan nama class yang benar)
// ============================================================
import 'package:permission_handler/permission_handler.dart';
import '../config/app_config.dart';

/// Location service - saat ini GPS dinonaktifkan via AppConfig.enableGps = false
/// Semua method akan mengembalikan null / koordinat null.
/// Aktifkan GPS dengan mengubah AppConfig.enableGps = true.
class LocationService {
  static final LocationService _instance = LocationService._();
  factory LocationService() => _instance;
  LocationService._();

  /// Ambil koordinat hanya (tanpa reverse geocode)
  Future<({double? lat, double? lng})> getCoordinatesOnly() async {
    if (!AppConfig.enableGps) {
      return (lat: null, lng: null);
    }
    // TODO: Implementasi GPS sebenarnya di sini
    // Saat ini hanya stub
    return (lat: null, lng: null);
  }

  /// Ambil koordinat + alamat (jika withAddress true)
  Future<({double? lat, double? lng, String? address})> get({
    bool withAddress = true,
    bool forceRefresh = false,
  }) async {
    if (!AppConfig.enableGps) {
      return (lat: null, lng: null, address: null);
    }
    // TODO: Implementasi GPS sebenarnya di sini
    return (lat: null, lng: null, address: null);
  }

  /// Reverse geocode koordinat ke alamat
  Future<String?> reverseGeocode(
    double lat,
    double lng,
  ) async {
    if (!AppConfig.enableGps) {
      return null;
    }
    // TODO: Implementasi reverse geocode sebenarnya di sini
    return null;
  }

  /// Update entry dengan alamat dari koordinat
  Future<void> updateAddressForEntry({
    required String entryId,
    required double lat,
    required double lng,
    required Future<void> Function(
      String id,
      String address,
    ) onAddressReceived,
  }) async {
    if (!AppConfig.enableGps) {
      return;
    }
    final address = await reverseGeocode(lat, lng);
    if (address != null && address.isNotEmpty) {
      await onAddressReceived(entryId, address);
    }
  }
}
