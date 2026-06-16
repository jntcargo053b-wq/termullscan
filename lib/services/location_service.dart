import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class LocationService {
  static final _instance = LocationService._();
  factory LocationService() => _instance;
  LocationService._();

  // Cache
  static ({double? lat, double? lng, String? address})? _cachedLocation;
  static DateTime? _cacheTime;
  static const _cacheDuration = Duration(seconds: 30);

  /// Cek izin lokasi
  Future<bool> _checkPermission() async {
    final status = await Geolocator.checkPermission();
    if (status == LocationPermission.denied || status == LocationPermission.deniedForever) {
      final request = await Geolocator.requestPermission();
      return request == LocationPermission.always || request == LocationPermission.whileInUse;
    }
    return status == LocationPermission.always || status == LocationPermission.whileInUse;
  }

  /// Mendapatkan koordinat dengan fallback ke last known
  Future<({double? lat, double? lng})> getCoordinatesOnly() async {
    try {
      // Cek izin
      final hasPermission = await _checkPermission();
      if (!hasPermission) {
        debugPrint('Location permission denied');
        return (lat: null, lng: null);
      }

      // Setting: akurasi tinggi, timeout 6 detik
      const settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 6),
      );

      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: settings,
        ).timeout(const Duration(seconds: 6));
      } on TimeoutException catch (_) {
        // Fallback ke last known position
        position = await Geolocator.getLastKnownPosition();
        if (position == null) rethrow;
      }

      if (position == null) {
        // Coba sekali lagi dengan akurasi rendah
        final lowSettings = const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 4),
        );
        position = await Geolocator.getCurrentPosition(
          locationSettings: lowSettings,
        ).timeout(const Duration(seconds: 4));
      }

      if (position != null) {
        return (lat: position.latitude, lng: position.longitude);
      }
      return (lat: null, lng: null);
    } catch (e) {
      debugPrint('Location error: $e');
      // Coba last known sekali lagi di luar try
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return (lat: last.latitude, lng: last.longitude);
      } catch (_) {}
      return (lat: null, lng: null);
    }
  }

  /// Dapatkan lokasi lengkap (dengan address opsional)
  Future<({double? lat, double? lng, String? address})> getLocation({
    bool withAddress = true,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _cachedLocation != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < _cacheDuration) {
      final cached = _cachedLocation!;
      if (!withAddress || cached.address != null) {
        return cached;
      }
    }

    final coords = await getCoordinatesOnly();
    if (coords.lat == null || coords.lng == null) {
      return (lat: null, lng: null, address: null);
    }

    String? address;
    if (withAddress) {
      address = await _reverseGeocode(coords.lat!, coords.lng!);
    }

    final result = (lat: coords.lat, lng: coords.lng, address: address);
    _cachedLocation = result;
    _cacheTime = DateTime.now();
    return result;
  }

  /// Reverse geocoding (sama seperti sebelumnya, hanya pakai geolocator tidak mengubah)
  Future<String?> reverseGeocode(double lat, double lng, {double? accuracy}) async {
    return await _reverseGeocode(lat, lng, accuracy: accuracy);
  }

  /// Update address untuk entry (sama)
  Future<void> updateAddressForEntry({
    required String entryId,
    required double lat,
    required double lng,
    required Future<void> Function(String entryId, String address) onAddressReceived,
    double? accuracy,
  }) async {
    try {
      final address = await _reverseGeocode(lat, lng, accuracy: accuracy);
      if (address != null) {
        await onAddressReceived(entryId, address);
        if (_cachedLocation != null &&
            _cachedLocation!.lat == lat &&
            _cachedLocation!.lng == lng) {
          _cachedLocation = (lat: lat, lng: lng, address: address);
          _cacheTime = DateTime.now();
        }
      }
    } catch (e) {
      // ignore
    }
  }

  /// Reverse geocode via Nominatim (sama)
  Future<String?> _reverseGeocode(double lat, double lng, {double? accuracy}) async {
    try {
      final isCoarse = accuracy != null && accuracy >= 20;
      final zoom = isCoarse ? 14 : 18;
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=$lat&lon=$lng&format=json&addressdetails=1&zoom=$zoom',
      );
      final response = await http.get(uri, headers: {
        'User-Agent': 'WHScanner/1.0',
        'Accept-Language': 'id',
      }).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body);
      final addr = data['address'];
      if (addr == null) return null;
      final parts = <String>[];
      final city = addr['city'] ?? addr['town'] ?? addr['regency'] ?? addr['county'];
      final state = addr['state'];
      if (isCoarse) {
        final district = addr['suburb'] ??
            addr['city_district'] ??
            addr['district'] ??
            addr['subdistrict'] ??
            addr['village'] ??
            addr['neighbourhood'];
        if (district != null) parts.add(district);
        if (city != null) parts.add(city);
        if (state != null) parts.add(state);
      } else {
        final road = addr['road'] ?? addr['pedestrian'] ?? addr['path'];
        final village = addr['village'] ?? addr['suburb'] ?? addr['neighbourhood'];
        if (road != null) parts.add(road);
        if (village != null) parts.add(village);
        if (city != null) parts.add(city);
        if (state != null) parts.add(state);
      }
      return parts.isNotEmpty ? parts.join(', ') : data['display_name'];
    } catch (e) {
      return null;
    }
  }
}
