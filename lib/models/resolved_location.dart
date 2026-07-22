// lib/models/resolved_location.dart
// ============================================================
// RESOLVED LOCATION — Hasil resolusi lokasi gabungan
// ============================================================
// primaryLabel : nama POI/tempat paling spesifik (jika ada)
// addressLine  : alamat jalan + admin area (Nominatim)
// suggestions  : daftar kandidat label, diurutkan dari paling
//                spesifik ke paling umum, untuk dipilih user
// ============================================================

class LocationSuggestion {
  final String label;
  final double? distanceMeters;
  final String source; // 'poi' | 'address' | 'admin'

  const LocationSuggestion({
    required this.label,
    required this.source,
    this.distanceMeters,
  });

  LocationSuggestion copyWith({
    String? label,
    double? distanceMeters,
    String? source,
  }) => LocationSuggestion(
    label: label ?? this.label,
    distanceMeters: distanceMeters ?? this.distanceMeters,
    source: source ?? this.source,
  );

  Map<String, dynamic> toJson() => {
        'label': label,
        'distanceMeters': distanceMeters,
        'source': source,
      };

  factory LocationSuggestion.fromJson(Map<String, dynamic> json) =>
      LocationSuggestion(
        label: json['label'] as String,
        distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
        source: json['source'] as String? ?? 'address',
      );

  @override
  String toString() => 'LocationSuggestion(label: "$label", source: $source, distance: ${distanceMeters?.toStringAsFixed(1) ?? "N/A"}m)';
}

class ResolvedLocation {
  /// Nama tempat/POI paling spesifik, mis. "Alfamart Pondok Aren".
  final String? primaryLabel;

  /// Alamat jalan + area administratif.
  final String addressLine;

  /// Daftar kandidat label tambahan.
  final List<LocationSuggestion> suggestions;

  // ─── TAMBAHKAN FIELD UNTUK KOMPATIBILITAS ────────────────────
  final double? latitude;
  final double? longitude;
  final String? city;
  final String? province;
  final String? country;
  final String? postalCode;
  final String? street;

  const ResolvedLocation({
    required this.addressLine,
    this.primaryLabel,
    this.suggestions = const [],
    this.latitude,
    this.longitude,
    this.city,
    this.province,
    this.country,
    this.postalCode,
    this.street,
  });

  // ─── FACTORY ──────────────────────────────────────────────────

  factory ResolvedLocation.empty() => const ResolvedLocation(
    addressLine: 'Lokasi tidak tersedia',
  );

  factory ResolvedLocation.dms(String dms) => ResolvedLocation(
    addressLine: dms,
  );

  // ─── GETTERS ──────────────────────────────────────────────────

  String get display {
    if (primaryLabel != null &&
        primaryLabel!.isNotEmpty &&
        !addressLine.startsWith(primaryLabel!)) {
      return '$primaryLabel, $addressLine';
    }
    return addressLine;
  }

  String get shortDisplay {
    final full = display;
    if (full.length > 40) {
      return '${full.substring(0, 40)}…';
    }
    return full;
  }

  String get fullAddress {
    final parts = <String>[];
    if (street != null && street!.isNotEmpty) parts.add(street!);
    if (city != null && city!.isNotEmpty) parts.add(city!);
    if (province != null && province!.isNotEmpty) parts.add(province!);
    if (country != null && country!.isNotEmpty) parts.add(country!);
    return parts.join(', ');
  }

  bool get isDmsFallback => addressLine.startsWith('GPS:');
  bool get isEmpty => addressLine == 'Lokasi tidak tersedia';
  bool get hasPrimaryLabel => primaryLabel != null && primaryLabel!.isNotEmpty;

  // ─── COPYWITH ──────────────────────────────────────────────────

  ResolvedLocation copyWith({
    String? primaryLabel,
    String? addressLine,
    List<LocationSuggestion>? suggestions,
    double? latitude,
    double? longitude,
    String? city,
    String? province,
    String? country,
    String? postalCode,
    String? street,
  }) => ResolvedLocation(
    primaryLabel: primaryLabel ?? this.primaryLabel,
    addressLine: addressLine ?? this.addressLine,
    suggestions: suggestions ?? this.suggestions,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    city: city ?? this.city,
    province: province ?? this.province,
    country: country ?? this.country,
    postalCode: postalCode ?? this.postalCode,
    street: street ?? this.street,
  );

  // ─── JSON ─────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'primaryLabel': primaryLabel,
        'addressLine': addressLine,
        'suggestions': suggestions.map((s) => s.toJson()).toList(),
        'latitude': latitude,
        'longitude': longitude,
        'city': city,
        'province': province,
        'country': country,
        'postalCode': postalCode,
        'street': street,
      };

  factory ResolvedLocation.fromJson(Map<String, dynamic> json) =>
      ResolvedLocation(
        primaryLabel: json['primaryLabel'] as String?,
        addressLine: json['addressLine'] as String? ?? '',
        suggestions: (json['suggestions'] as List<dynamic>? ?? [])
            .map((e) => LocationSuggestion.fromJson(e as Map<String, dynamic>))
            .toList(),
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        city: json['city'] as String?,
        province: json['province'] as String?,
        country: json['country'] as String?,
        postalCode: json['postalCode'] as String?,
        street: json['street'] as String?,
      );

  // ─── EQUALITY ─────────────────────────────────────────────────

  @override
  String toString() {
    return 'ResolvedLocation(display: "$display", isFallback: $isDmsFallback, suggestions: ${suggestions.length})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ResolvedLocation &&
        other.addressLine == addressLine &&
        other.primaryLabel == primaryLabel;
  }

  @override
  int get hashCode => Object.hash(addressLine, primaryLabel);
}
