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
  final double? distanceMeters; // null jika dari Nominatim (tanpa jarak eksplisit)
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
  /// Null jika tidak ada POI yang cukup dekat/relevan.
  final String? primaryLabel;

  /// Alamat jalan + area administratif, mis.
  /// "Jl. Raya Pondok Aren No.12, Pondok Aren, Kota Tangerang Selatan".
  /// Selalu non-empty (fallback DMS jika semua gagal).
  final String addressLine;

  /// Daftar kandidat label tambahan untuk dipilih user,
  /// sudah dedup & sort by distance (POI dulu, lalu address/admin).
  final List<LocationSuggestion> suggestions;

  const ResolvedLocation({
    required this.addressLine,
    this.primaryLabel,
    this.suggestions = const [],
  });

  /// Empty location (fallback)
  factory ResolvedLocation.empty() => const ResolvedLocation(
    addressLine: 'Lokasi tidak tersedia',
  );

  /// DMS fallback
  factory ResolvedLocation.dms(String dms) => ResolvedLocation(
    addressLine: dms,
  );

  /// String tampilan utama — backward-compatible dengan field
  /// `address` (String) yang dipakai watermark & UI lama.
  /// Format: "Primary, AddressLine" jika primaryLabel ada,
  /// selain itu cuma addressLine.
  String get display {
    if (primaryLabel != null &&
        primaryLabel!.isNotEmpty &&
        !addressLine.startsWith(primaryLabel!)) {
      return '$primaryLabel, $addressLine';
    }
    return addressLine;
  }

  /// Short display untuk preview (max 40 karakter)
  String get shortDisplay {
    final full = display;
    if (full.length > 40) {
      return '${full.substring(0, 40)}…';
    }
    return full;
  }

  bool get isDmsFallback => addressLine.startsWith('GPS:');
  bool get isEmpty => addressLine == 'Lokasi tidak tersedia';
  bool get hasPrimaryLabel => primaryLabel != null && primaryLabel!.isNotEmpty;

  ResolvedLocation copyWith({
    String? primaryLabel,
    String? addressLine,
    List<LocationSuggestion>? suggestions,
  }) => ResolvedLocation(
    primaryLabel: primaryLabel ?? this.primaryLabel,
    addressLine: addressLine ?? this.addressLine,
    suggestions: suggestions ?? this.suggestions,
  );

  Map<String, dynamic> toJson() => {
        'primaryLabel': primaryLabel,
        'addressLine': addressLine,
        'suggestions': suggestions.map((s) => s.toJson()).toList(),
      };

  factory ResolvedLocation.fromJson(Map<String, dynamic> json) =>
      ResolvedLocation(
        primaryLabel: json['primaryLabel'] as String?,
        addressLine: json['addressLine'] as String? ?? '',
        suggestions: (json['suggestions'] as List<dynamic>? ?? [])
            .map((e) => LocationSuggestion.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

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
