
class Service {
  static final _instance = Service._();
  factory Service() => _instance;
  Service._();
  Future<({double? lat, double? lng})> getCoordinatesOnly() async => (lat:null,lng:null);
  Future<({double? lat, double? lng, String? address})> get({bool withAddress=true,bool forceRefresh=false}) async => (lat:null,lng:null,address:null);
}
