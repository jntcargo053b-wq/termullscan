// lib/services/pod_address_resolver.dart
// ============================================================
// POD ADDRESS RESOLVER — Proof of Delivery Edition
// ============================================================
// Strategi:
//   1. Nominatim (OSM) — primary, level jalan + RT/RW/kel/kec/kota
//      + namedetails untuk POI di titik tersebut
//   2. Overpass (OSM)  — POI radius 30m jika Nominatim tanpa nama POI
//   3. Photon (Komoot) — fallback 1
//   4. Android Geocoder — fallback 2
//   5. Koordinat DMS    — last resort (tidak pernah kosong)
//
// Fitur khusus POD:
//   - Multi-query Nominatim dengan zoom berurutan (18→16→14) agar
//     alamat selalu ada walaupun di area rural/terpencil.
//   - Normalisasi: hapus plus-code, deduplikasi, urutkan dari
//     spesifik ke umum (jalan → kelurahan → kecamatan → kota).
//   - Cache LRU 100 entri + nearby-cache radius 8m (10 menit).
//   - Retry otomatis sekali jika HTTP timeout.
//   - Cross-session persistence via SharedPreferences (20 entri).
//   - Grid cache tambahan untuk efisiensi (10m x 10m).
//   - User-Agent compliance untuk semua HTTP requests.
//
// resolveDetailed() mengembalikan ResolvedLocation dengan:
//   - primaryLabel : nama POI (jika ditemukan via Nominatim name
//                    atau Overpass radius 30m)
//   - addressLine  : alamat jalan + admin area
//   - suggestions  : kandidat label lain (POI lain, admin area)
// ============================================================

import 'dart:collection';
import 'dart:convert';


import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;

import '../models/resolved_location.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Cache Entry dengan TTL ───────────────────────────────────
class _CacheEntry {
  final String address;
  final DateTime timestamp;
  _CacheEntry(this.address, this.timestamp);
  
  bool isExpired({Duration ttl = const Duration(hours: 24)}) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}

class _NearbyEntry {
  final double lat, lon;
  final String address;
  final DateTime savedAt;
  _NearbyEntry(this.lat, this.lon, this.address, this.savedAt);
}

class PodAddressResolver {
  // ── HTTP Client dengan User-Agent ──────────────────────────
  static http.Client _client = http.Client();
  static bool _closed = false;
  
  // User-Agent untuk compliance OSM
  static const String _userAgent = 'TermulLog-POD/3.0 (Android; +https://termullog.example.com)';
  
  // ── Exact-coordinate cache (LRU, 5 desimal = ~1.1m) ─────
  static final LinkedHashMap<String, _CacheEntry> _exactCache = LinkedHashMap();
  static const int _exactCacheMax = 100;
  static const Duration _exactCacheTtl = Duration(hours: 24);
  
  // ── Grid cache (10m x 10m untuk efisiensi lebih tinggi) ───
  static final Map<String, String> _gridCache = {};
  static const int _gridResolution = 10000;  // ~10m precision
  static const int _gridCacheMax = 200;
  
  // ── Nearby cache (radius 8m, TTL 10 menit) ───────────────
  static final List<_NearbyEntry> _nearbyCache = [];
  static const double _nearbyCacheRadius = 20.0;  // meter (komplek/gudang)
  static const Duration _nearbyTtl = Duration(minutes: 10);
  static const int _nearbyCacheMax = 50;
  
  // ── Rate limiting Nominatim (1 req/detik sesuai ToS) ─────
  static DateTime _lastNominatim = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _nominatimInterval = Duration(seconds: 1);
  
  // ── Rate limiting Photon ─────────────────────────────────
  static DateTime _lastPhoton = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _photonInterval = Duration(milliseconds: 500);

  // ── Rate limiting Overpass ───────────────────────────────
  static DateTime _lastOverpass = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _overpassInterval = Duration(milliseconds: 800);
  static const double _overpassRadiusMeters = 30.0;

  // ── ResolvedLocation cache (in-memory, per-session) ──────
  static final LinkedHashMap<String, ResolvedLocation> _resolvedCache =
      LinkedHashMap();
  static const int _resolvedCacheMax = 100;
  
  // ── Cross-session persistence ─────────────────────────────
  static const String _prefKey = 'pod_address_cache_v3';
  static bool _persistLoaded = false;
  
  // ── Regex plus-code ───────────────────────────────────────
  static final RegExp _plusCodeRe = RegExp(
    r'(?:^|[\s,])([23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3})(?:[\s,]|$)',
    caseSensitive: false,
  );
  
  // ── Helper untuk akses HTTP Client (thread-safe di Dart) ───
  static Future<T> _withClient<T>(Future<T> Function(http.Client client) operation) async {
    if (_closed) throw StateError('PodAddressResolver is closed');
    return await operation(_client);
  }
  
  static bool _isPlusCode(String? s) {
    if (s == null) return false;
    final trimmed = s.trim();
    // Plus code is typically 8-11 characters with '+'
    if (trimmed.length < 8 || trimmed.length > 15) return false;
    return _plusCodeRe.hasMatch(trimmed);
  }
  
  // ── PUBLIC ENTRY POINT ────────────────────────────────────
  /// Resolves centroid coordinates to a clean Indonesian address.
  /// Always returns non-empty string (DMS fallback if all fail).
  static Future<String> resolve(double lat, double lon) async {
    // Validasi koordinat
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      if (kDebugMode) debugPrint('PodAddressResolver: Invalid coordinates');
      return _toDMS(lat, lon);
    }
    
    // Load persistent cache pertama kali
    await _loadPersistentCache();
    
    // 1. Grid cache (paling cepat, 10m precision)
    final gridKey = _gridKey(lat, lon);
    final gridCached = _gridCache[gridKey];
    if (gridCached != null) {
      if (kDebugMode) debugPrint('PodAddressResolver: grid cache hit → $gridCached');
      return gridCached;
    }
    
    // 2. Exact cache
    final exactKey = _cacheKey(lat, lon);
    final exactEntry = _exactCache[exactKey];
    if (exactEntry != null && !exactEntry.isExpired(ttl: _exactCacheTtl)) {
      _exactCache.remove(exactKey);
      _exactCache[exactKey] = exactEntry; // LRU: move to end
      if (kDebugMode) debugPrint('PodAddressResolver: exact cache hit → ${exactEntry.address}');
      return exactEntry.address;
    } else if (exactEntry != null) {
      // Expired, remove from cache
      _exactCache.remove(exactKey);
    }
    
    // 3. Nearby cache
    final nearby = _nearbyLookup(lat, lon);
    if (nearby != null) {
      if (kDebugMode) debugPrint('PodAddressResolver: nearby cache hit → $nearby');
      return nearby;
    }
    
    // 4. Fetch from providers
    final address = await _fetchWithFallback(lat, lon);
    
    if (address.isNotEmpty && !address.contains('GPS:')) {
      _putExact(exactKey, address);
      _putNearby(lat, lon, address);
      _putGridCache(gridKey, address);
      await _persistCache();
    }
    
    return address.isNotEmpty ? address : _toDMS(lat, lon);
  }
  
  // ── Grid Cache Helpers ────────────────────────────────────
  static String _gridKey(double lat, double lon) {
    final gridLat = (lat * _gridResolution).round();
    final gridLon = (lon * _gridResolution).round();
    return '$gridLat,$gridLon';
  }
  
  static void _putGridCache(String key, String value) {
    _gridCache[key] = value;
    if (_gridCache.length > _gridCacheMax) {
      final keysToRemove = _gridCache.keys.take(50).toList();
      for (var k in keysToRemove) {
        _gridCache.remove(k);
      }
      if (kDebugMode) debugPrint('PodAddressResolver: trimmed grid cache to ${_gridCache.length}');
    }
  }
  
  // ── Fetch dengan fallback chain ───────────────────────────
  static Future<String> _fetchWithFallback(double lat, double lon) async {
    final latS = lat.toStringAsFixed(7);
    final lonS = lon.toStringAsFixed(7);
    
    // Nominatim: coba zoom 18 → 16 → 14
    for (final zoom in [18, 16, 14, 12]) {
      try {
        final r = await _nominatim(latS, lonS, zoom: zoom);
        if (r.isNotEmpty) {
          if (kDebugMode) debugPrint('PodAddressResolver: Nominatim z$zoom → $r');
          return r;
        }
      } catch (e) {
        if (kDebugMode) debugPrint('PodAddressResolver: Nominatim z$zoom error → $e');
      }
    }
    
    // Photon fallback
    try {
      final r = await _photon(latS, lonS);
      if (r.isNotEmpty) {
        if (kDebugMode) debugPrint('PodAddressResolver: Photon → $r');
        return r;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PodAddressResolver: Photon error → $e');
    }
    
    // Android Geocoder
    try {
      final r = await _androidGeocoder(lat, lon);
      if (r.isNotEmpty && !r.contains('Unnamed Road')) {
        if (kDebugMode) debugPrint('PodAddressResolver: Android → $r');
        return r;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PodAddressResolver: Android error → $e');
    }
    
    return '';
  }
  
  // ── Nominatim ─────────────────────────────────────────────
  static Future<String> _nominatim(String lat, String lon, {int zoom = 18}) async {
    return await _withClient((client) async {
      // Rate limit
      final now = DateTime.now();
      final elapsed = now.difference(_lastNominatim);
      if (elapsed < _nominatimInterval) {
        final delay = _nominatimInterval - elapsed;
        if (delay > const Duration(seconds: 5)) {
          // Something wrong with system clock, reset
          _lastNominatim = now;
          if (kDebugMode) debugPrint('PodAddressResolver: Nominatim rate limit reset (clock anomaly)');
        } else {
          await Future.delayed(delay);
        }
      }
      _lastNominatim = DateTime.now();
      
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          final uri = Uri.parse(
            'https://nominatim.openstreetmap.org/reverse'
            '?format=jsonv2&lat=$lat&lon=$lon'
            '&zoom=$zoom&addressdetails=1&accept-language=id',
          );
          final res = await client.get(
            uri,
            headers: {
              'User-Agent': _userAgent,
              'Accept-Language': 'id,en;q=0.8',
            },
          ).timeout(const Duration(seconds: 7));
          
          if (res.statusCode == 429) {
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          if (res.statusCode != 200) return '';
          
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          return _parseNominatimAddress(data);
        } catch (_) {
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 600));
            continue;
          }
          return '';
        }
      }
      return '';
    });
  }
  
  static String _parseNominatimAddress(Map<String, dynamic> data) {
    final addr = data['address'] as Map<String, dynamic>?;
    if (addr == null) {
      // Fallback ke display_name
      final display = data['display_name'] as String?;
      if (display != null && display.isNotEmpty) {
        return _cleanDisplayName(display);
      }
      return '';
    }
    
    String? _s(dynamic v) {
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }
    
    // Jalan (prioritas: road > residential > pedestrian > service)
    final road = _s(addr['road'])
        ?? _s(addr['residential'])
        ?? _s(addr['pedestrian'])
        ?? _s(addr['footway'])
        ?? _s(addr['path'])
        ?? _s(addr['service'])
        ?? _s(addr['track'])
        ?? _s(addr['cycleway']);
    final houseNum = _s(addr['house_number']);
    
    // Sub-area (RT/RW level)
    final suburb = _s(addr['suburb'])
        ?? _s(addr['neighbourhood'])
        ?? _s(addr['quarter'])
        ?? _s(addr['allotments']);
    
    // Kelurahan/desa
    final village = _s(addr['village'])
        ?? _s(addr['hamlet'])
        ?? _s(addr['isolated_dwelling'])
        ?? _s(addr['locality']);
    
    // Kecamatan
    final subdistrict = _s(addr['subdistrict'])
        ?? _s(addr['city_district'])
        ?? _s(addr['district']);
    
    // Kota/kabupaten
    final city = _s(addr['city'])
        ?? _s(addr['town'])
        ?? _s(addr['municipality'])
        ?? _s(addr['county']);
    
    // Provinsi (opsional, hanya jika tidak ada kota)
    final state = city == null ? (_s(addr['state'])) : null;
    
    final parts = <String>[];
    
    // Jalan + nomor
    if (road != null) {
      parts.add(houseNum != null ? '$road No.$houseNum' : road);
    }
    
    // Tambah sub-area
    if (suburb != null && suburb != road) parts.add(suburb);
    
    // Kelurahan/desa (jika beda dari suburb)
    if (village != null && village != suburb) parts.add(village);
    
    // Kecamatan (deduplikasi)
    if (subdistrict != null &&
        subdistrict != suburb &&
        subdistrict != village) {
      parts.add(subdistrict);
    }
    
    // Kota
    if (city != null) parts.add(city);
    if (state != null) parts.add(state);
    
    if (parts.isEmpty) {
      // Gunakan display_name sebagai last resort
      final display = data['display_name'] as String?;
      if (display != null && display.isNotEmpty) {
        return _cleanDisplayName(display);
      }
      return '';
    }
    
    return _dedup(parts).join(', ');
  }
  
  static String _cleanDisplayName(String display) {
    // Ambil max 5 bagian, hapus plus code, strip whitespace
    final parts = display
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty && !_isPlusCode(p))
        .take(5)
        .toList();
    return parts.isEmpty ? '' : parts.join(', ');
  }

  // ════════════════════════════════════════════════════════
  // DETAILED RESOLUTION — ResolvedLocation (primaryLabel + suggestions)
  // ════════════════════════════════════════════════════════
  //
  //   GPS Lock
  //     ↓
  //   Nominatim (zoom 18, namedetails=1)
  //     ↓
  //   name tersedia & bukan admin-area?
  //     ├─ Ya  → primaryLabel = name
  //     └─ Tidak → Overpass radius 30m → POI terdekat
  //                 ├─ ada → primaryLabel = POI.name
  //                 └─ tidak ada → primaryLabel = null
  //     ↓
  //   addressLine = hasil _fetchWithFallback (chain lama, sudah teruji)
  //   suggestions = [POI overpass lainnya..., addressLine sbg 'address']
  //
  /// Resolves with full detail: primary POI label + address + suggestions.
  /// Falls back to plain address (via [resolve]) if POI lookups fail —
  /// never throws, never returns an empty addressLine.
  static Future<ResolvedLocation> resolveDetailed(double lat, double lon) async {
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      return ResolvedLocation.dms(_toDMS(lat, lon));
    }

    // Cache check (in-memory, session-only — POI data changes rarely
    // but we don't want to persist it across sessions like address cache)
    final cacheKey = _gridKey(lat, lon);
    final cached = _resolvedCache[cacheKey];
    if (cached != null) {
      if (kDebugMode) debugPrint('PodAddressResolver: resolvedCache hit → ${cached.display}');
      return cached;
    }

    // 1. Alamat jalan (reuse existing battle-tested chain)
    final addressLine = await resolve(lat, lon);

    // 2. Coba dapatkan nama POI dari Nominatim namedetails
    final latS = lat.toStringAsFixed(7);
    final lonS = lon.toStringAsFixed(7);
    String? poiName;
    try {
      poiName = await _nominatimPoiName(latS, lonS);
    } catch (e) {
      if (kDebugMode) debugPrint('PodAddressResolver: nominatimPoiName error → $e');
    }

    // 3. Jika Nominatim tidak punya nama POI yang relevan, coba Overpass
    final suggestions = <LocationSuggestion>[];
    if (poiName == null) {
      try {
        final pois = await _overpassNearbyPois(lat, lon);
        if (pois.isNotEmpty) {
          poiName = pois.first.label;
          suggestions.addAll(pois);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('PodAddressResolver: overpass error → $e');
      }
    } else {
      suggestions.add(LocationSuggestion(label: poiName, source: 'poi'));
    }

    // 4. Tambahkan addressLine sebagai suggestion 'address'
    if (addressLine.isNotEmpty && !addressLine.contains('GPS:')) {
      suggestions.add(LocationSuggestion(label: addressLine, source: 'address'));
    }

    final result = ResolvedLocation(
      primaryLabel: poiName,
      addressLine: addressLine.isNotEmpty ? addressLine : _toDMS(lat, lon),
      suggestions: _dedupSuggestions(suggestions),
    );

    if (!result.isDmsFallback) {
      _resolvedCache[cacheKey] = result;
      if (_resolvedCache.length > _resolvedCacheMax) {
        final keysToRemove = _resolvedCache.keys.take(20).toList();
        for (final k in keysToRemove) {
          _resolvedCache.remove(k);
        }
      }
    }

    return result;
  }

  static List<LocationSuggestion> _dedupSuggestions(List<LocationSuggestion> input) {
    final seen = <String>{};
    final out = <LocationSuggestion>[];
    for (final s in input) {
      final key = s.label.trim().toLowerCase();
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      out.add(s);
    }
    return out;
  }

  // ── Nominatim: ambil nama POI (namedetails) di titik ini ────
  // Mengembalikan null jika tidak ada nama, atau nama tersebut
  // adalah area administratif (kelurahan/kecamatan/kota/dll) —
  // karena itu sudah tercakup di addressLine.
  static Future<String?> _nominatimPoiName(String lat, String lon) async {
    return await _withClient((client) async {
      // Rate limit (shared dengan _nominatim)
      final now = DateTime.now();
      final elapsed = now.difference(_lastNominatim);
      if (elapsed < _nominatimInterval) {
        final delay = _nominatimInterval - elapsed;
        if (delay <= const Duration(seconds: 5)) {
          await Future.delayed(delay);
        } else {
          _lastNominatim = now;
        }
      }
      _lastNominatim = DateTime.now();

      try {
        final uri = Uri.parse(
          'https://nominatim.openstreetmap.org/reverse'
          '?format=jsonv2&lat=$lat&lon=$lon'
          '&zoom=18&addressdetails=1&namedetails=1&accept-language=id',
        );
        final res = await client.get(
          uri,
          headers: {
            'User-Agent': _userAgent,
            'Accept-Language': 'id,en;q=0.8',
          },
        ).timeout(const Duration(seconds: 7));

        if (res.statusCode != 200) return null;

        final data = jsonDecode(res.body) as Map<String, dynamic>;

        // 'class' di Nominatim menandakan tipe entitas. Jika class
        // adalah boundary/place administratif, 'name' adalah nama
        // wilayah (kelurahan/kecamatan/kota) — sudah ada di
        // addressLine, jadi bukan kandidat primaryLabel yang baru.
        final cls = data['class'] as String?;
        const adminClasses = {'boundary', 'place'};
        if (cls != null && adminClasses.contains(cls)) return null;

        // Nama dari namedetails (lebih lengkap) atau top-level 'name'
        final namedetails = data['namedetails'] as Map<String, dynamic>?;
        String? name = (namedetails?['name'] as String?)?.trim();
        name ??= (data['name'] as String?)?.trim();

        if (name == null || name.isEmpty) return null;
        if (_isPlusCode(name)) return null;

        return name;
      } catch (_) {
        return null;
      }
    });
  }

  // ── Overpass: cari POI bernama dalam radius 30m ──────────────
  // Mengembalikan list LocationSuggestion sudah sort by distance.
  static Future<List<LocationSuggestion>> _overpassNearbyPois(
      double lat, double lon) async {
    return await _withClient((client) async {
      // Rate limit
      final now = DateTime.now();
      final elapsed = now.difference(_lastOverpass);
      if (elapsed < _overpassInterval) {
        await Future.delayed(_overpassInterval - elapsed);
      }
      _lastOverpass = DateTime.now();

      final query = '[out:json][timeout:5];'
          '('
          'node(around:${_overpassRadiusMeters.toInt()},$lat,$lon)[name]'
          '[~"^(amenity|shop|office|tourism|leisure|healthcare)\$"~"."];'
          ');'
          'out body 6;';

      try {
        final uri = Uri.parse('https://overpass-api.de/api/interpreter');
        final res = await client
            .post(
              uri,
              headers: {
                'User-Agent': _userAgent,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: 'data=${Uri.encodeComponent(query)}',
            )
            .timeout(const Duration(seconds: 6));

        if (res.statusCode != 200) return [];

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final elements = data['elements'] as List?;
        if (elements == null || elements.isEmpty) return [];

        final results = <LocationSuggestion>[];
        for (final el in elements) {
          final map = el as Map<String, dynamic>;
          final tags = map['tags'] as Map<String, dynamic>?;
          final name = (tags?['name'] as String?)?.trim();
          if (name == null || name.isEmpty || _isPlusCode(name)) continue;

          final elLat = (map['lat'] as num?)?.toDouble();
          final elLon = (map['lon'] as num?)?.toDouble();
          double? dist;
          if (elLat != null && elLon != null) {
            dist = Geolocator.distanceBetween(lat, lon, elLat, elLon);
            // Skip jika ternyata > radius (defensive — query sudah filter,
            // tapi double-check untuk akurasi suggestions)
            if (dist > _overpassRadiusMeters + 5) continue;
          }

          results.add(LocationSuggestion(
            label: name,
            source: 'poi',
            distanceMeters: dist,
          ));
        }

        // Sort by distance (terdekat dulu); null distance taruh akhir
        results.sort((a, b) {
          if (a.distanceMeters == null && b.distanceMeters == null) return 0;
          if (a.distanceMeters == null) return 1;
          if (b.distanceMeters == null) return -1;
          return a.distanceMeters!.compareTo(b.distanceMeters!);
        });

        return results;
      } catch (_) {
        return [];
      }
    });
  }
  
  // ── Photon ────────────────────────────────────────────────
  static Future<String> _photon(String lat, String lon) async {
    return await _withClient((client) async {
      // Rate limit Photon
      final now = DateTime.now();
      final elapsed = now.difference(_lastPhoton);
      if (elapsed < _photonInterval) {
        await Future.delayed(_photonInterval - elapsed);
      }
      _lastPhoton = DateTime.now();
      
      try {
        final uri = Uri.parse(
            'https://photon.komoot.io/reverse?lat=$lat&lon=$lon&lang=id');
        final res = await client.get(
          uri,
          headers: {'User-Agent': _userAgent},
        ).timeout(const Duration(seconds: 6));
        
        if (res.statusCode != 200) return '';
        
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final features = data['features'] as List?;
        if (features == null || features.isEmpty) return '';
        
        final props = features[0]['properties'] as Map<String, dynamic>? ?? {};
        
        String? _s(String k) {
          final v = props[k];
          if (v == null) return null;
          final s = v.toString().trim();
          return s.isEmpty ? null : s;
        }
        
        final name     = _s('name');
        final street   = _s('street');
        final housenum = _s('housenumber');
        final district = _s('district');
        final city     = _s('city');
        final state    = _s('state');
        
        final parts = <String>[];
        if (name != null && name != street) parts.add(name);
        if (street != null) {
          parts.add(housenum != null ? '$street No.$housenum' : street);
        }
        if (district != null) parts.add(district);
        if (city != null) parts.add(city);
        if (state != null && state != city) parts.add(state);
        
        return parts.isEmpty ? '' : _dedup(parts).join(', ');
      } catch (_) {
        return '';
      }
    });
  }
  
  // ── Android Geocoder ──────────────────────────────────────
  static Future<String> _androidGeocoder(double lat, double lon) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        lat, lon,
        localeIdentifier: 'id_ID',
      ).timeout(const Duration(seconds: 6));
      
      if (placemarks.isEmpty) return '';
      final p = placemarks.first;
      
      final parts = <String>[];
      final road = p.thoroughfare ?? p.street ?? '';
      if (road.isNotEmpty && !_isPlusCode(road)) parts.add(road);
      if ((p.subLocality ?? '').isNotEmpty && !_isPlusCode(p.subLocality)) {
        parts.add(p.subLocality!);
      }
      if ((p.locality ?? '').isNotEmpty && !_isPlusCode(p.locality)) {
        parts.add(p.locality!);
      }
      if ((p.administrativeArea ?? '').isNotEmpty &&
          !_isPlusCode(p.administrativeArea)) {
        parts.add(p.administrativeArea!);
      }
      return parts.isEmpty ? '' : _dedup(parts).join(', ');
    } catch (_) {
      return '';
    }
  }
  
  // ── Cache helpers ─────────────────────────────────────────
  static String _cacheKey(double lat, double lon) =>
      '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
  
  static void _putExact(String key, String value) {
    if (_exactCache.length >= _exactCacheMax) {
      _exactCache.remove(_exactCache.keys.first);
    }
    _exactCache[key] = _CacheEntry(value, DateTime.now());
  }
  
  static void _putNearby(double lat, double lon, String address) {
    _nearbyCache.removeWhere(
        (e) => DateTime.now().difference(e.savedAt) > _nearbyTtl);
    if (_nearbyCache.length >= _nearbyCacheMax) _nearbyCache.removeAt(0);
    _nearbyCache.add(_NearbyEntry(lat, lon, address, DateTime.now()));
  }
  
  static String? _nearbyLookup(double lat, double lon) {
    final now = DateTime.now();
    _NearbyEntry? best;
    double bestDist = double.infinity;
    for (final e in _nearbyCache) {
      if (now.difference(e.savedAt) > _nearbyTtl) continue;
      final d = Geolocator.distanceBetween(lat, lon, e.lat, e.lon);
      if (d <= _nearbyCacheRadius && d < bestDist) {
        bestDist = d;
        best = e;
      }
    }
    return best?.address;
  }
  
  // ── Persistent Cache ──────────────────────────────────────
  static Future<void> _loadPersistentCache() async {
    if (_persistLoaded) return;
    _persistLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.isEmpty) return;
      
      final Map<String, dynamic> rawMap = jsonDecode(raw) as Map<String, dynamic>;
      final now = DateTime.now();
      
      for (final entry in rawMap.entries) {
        // Format: "address|timestamp"
        final parts = entry.value.toString().split('|');
        if (parts.length >= 2) {
          final timestamp = DateTime.tryParse(parts[1]);
          if (timestamp != null && now.difference(timestamp) < _exactCacheTtl) {
            _exactCache[entry.key] = _CacheEntry(parts[0], timestamp);
          }
        }
      }
      
      if (kDebugMode) debugPrint('PodAddressResolver: loaded ${_exactCache.length} persisted entries');
    } catch (e) {
      if (kDebugMode) debugPrint('PodAddressResolver: load persistent error - $e');
    }
  }
  
  static Future<void> _persistCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Simpan max 20 entri terbaru dengan timestamp
      final entries = _exactCache.entries.toList();
      final now = DateTime.now();
      
      // Filter fresh entries
      final freshEntries = entries.where((entry) {
        return now.difference(entry.value.timestamp) < _exactCacheTtl;
      }).toList();
      
      final slice = freshEntries.length > 20
          ? freshEntries.sublist(freshEntries.length - 20)
          : freshEntries;
      
      final map = <String, String>{};
      for (final e in slice) {
        map[e.key] = '${e.value.address}|${e.value.timestamp.toIso8601String()}';
      }
      
      await prefs.setString(_prefKey, jsonEncode(map));
      if (kDebugMode) debugPrint('PodAddressResolver: persisted ${map.length} entries');
    } catch (e) {
      if (kDebugMode) debugPrint('PodAddressResolver: persist error - $e');
    }
  }
  
  // ── Helpers ───────────────────────────────────────────────
  static List<String> _dedup(List<String> parts) =>
      LinkedHashSet<String>.from(parts).toList();
  
  static String _toDMS(double lat, double lon) {
    final latDms = _dms(lat, true);
    final lonDms = _dms(lon, false);
    return 'GPS: $latDms, $lonDms';
  }
  
  static String _dms(double coord, bool isLat) {
    final abs = coord.abs();
    final deg = abs.floor();
    final min = ((abs - deg) * 60).floor();
    final sec = ((abs - deg - min / 60) * 3600).toStringAsFixed(1);
    final dir = isLat ? (coord >= 0 ? 'N' : 'S') : (coord >= 0 ? 'E' : 'W');
    return "$deg°$min'$sec\" $dir";
  }
  
  // ── Public Methods for Service Management ─────────────────
  static void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
  
  static void reopen() {
    if (!_closed) return;
    _client = http.Client();
    _closed = false;
  }
  
  /// Clear all caches (for testing or force refresh)
  static void clearCaches() {
    _exactCache.clear();
    _gridCache.clear();
    _nearbyCache.clear();
    _resolvedCache.clear();
    _persistLoaded = false;
    if (kDebugMode) debugPrint('PodAddressResolver: all caches cleared');
  }
  
  /// Get cache statistics
  static Map<String, int> getCacheStats() {
    return {
      'exactCache': _exactCache.length,
      'gridCache': _gridCache.length,
      'nearbyCache': _nearbyCache.length,
    };
  }
}
