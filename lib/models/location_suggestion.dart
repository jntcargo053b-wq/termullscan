// lib/models/location_suggestion.dart
// ============================================================
// LOCATION SUGGESTION — Suggestion untuk lokasi (POI, address, admin)
// ============================================================

class LocationSuggestion {
  final String label;
  final String source; // 'poi', 'address', 'admin'
  final double? distanceMeters;
  final String? type;
  final double? score;

  const LocationSuggestion({
    required this.label,
    required this.source,
    this.distanceMeters,
    this.type,
    this.score,
  });

  @override
  String toString() => 'LocationSuggestion(label: "$label", source: $source, score: $score)';
}
