/// Kumpulan data yang dibutuhkan semua renderer watermark.
///
/// Dibuat agar setiap [WatermarkRenderer] menerima satu objek data yang
/// sama, bukan daftar parameter panjang yang berbeda-beda. Field ini
/// mencerminkan semua informasi yang sebelumnya dikirim langsung sebagai
/// argumen ke fungsi render watermark.
class WatermarkData {
  /// Nilai barcode/QR (null untuk foto biasa tanpa scan).
  final String? barcodeValue;

  /// Format barcode, atau 'MANUAL' jika diinput manual oleh operator.
  final String? barcodeFormat;

  /// Waktu pengambilan foto.
  final DateTime timestamp;

  final double? latitude;
  final double? longitude;

  /// Nama lokasi hasil reverse geocoding, jika tersedia.
  final String? locationName;

  /// Nama operator yang mengambil foto.
  final String operatorName;

  /// Path lokal ke file logo perusahaan, jika ada.
  final String? logoPath;

  const WatermarkData({
    required this.timestamp,
    required this.operatorName,
    this.barcodeValue,
    this.barcodeFormat,
    this.latitude,
    this.longitude,
    this.locationName,
    this.logoPath,
  });

  /// True jika barcode diinput manual (bukan hasil scan kamera).
  bool get isManual => barcodeFormat == 'MANUAL';

  bool get hasBarcode => barcodeValue != null && barcodeValue!.isNotEmpty;

  bool get hasOperator => operatorName.isNotEmpty;

  bool get hasCoordinates => latitude != null && longitude != null;

  bool get hasLogoPath => logoPath != null && logoPath!.isNotEmpty;

  /// Teks lokasi siap-tampil: prioritaskan nama lokasi hasil geocoding,
  /// fallback ke koordinat mentah, lalu fallback ke pesan default.
  String get displayLocation {
    if (locationName != null && locationName!.isNotEmpty) {
      return locationName!;
    }
    if (hasCoordinates) {
      final latDir = latitude! >= 0 ? 'N' : 'S';
      final lonDir = longitude! >= 0 ? 'E' : 'W';
      return '${latitude!.abs().toStringAsFixed(4)}° $latDir, '
          '${longitude!.abs().toStringAsFixed(4)}° $lonDir';
    }
    return 'No location data';
  }
}
