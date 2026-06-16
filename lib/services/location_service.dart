
class LocationService {
  static final _instance = LocationService._();
  factory LocationService() => _instance;
  LocationService._();

  Future<({double? lat, double? lng})> getCoordinatesOnly() async {
    return (lat: null, lng: null);
  }

  Future<({double? lat, double? lng, String? address})> getLocation({
    bool withAddress = true,
    bool forceRefresh = false,
  }) async {
    return (lat: null, lng: null, address: null);
  }

  Future<String?> reverseGeocode(double lat, double lng, {double? accuracy}) async {
    return null;
  }

  Future<void> updateAddressForEntry({
    required String entryId,
    required double lat,
    required double lng,
    required Future<void> Function(String entryId, String address) onAddressReceived,
    double? accuracy,
  }) async {}
}
