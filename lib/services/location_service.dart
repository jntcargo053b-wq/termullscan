class Service {
  static final _instance = Service._();
  factory Service() => _instance;
  Service._();

  Future<({double? lat, double? lng})> getCoordinatesOnly() async =>
      (lat: null, lng: null);

  Future<({double? lat, double? lng, String? address})> get({
    bool withAddress = true,
    bool forceRefresh = false,
  }) async =>
      (lat: null, lng: null, address: null);

  Future<String?> reverseGeocode(
    double lat,
    double lng,
  ) async {
    return null;
  }

  Future<void> updateAddressForEntry({
    required String entryId,
    required double lat,
    required double lng,
    required Future<void> Function(
      String id,
      String address,
    ) onAddressReceived,
  }) async {
    final address = await reverseGeocode(lat, lng);
    if (address != null && address.isNotEmpty) {
      await onAddressReceived(entryId, address);
    }
  }
}
