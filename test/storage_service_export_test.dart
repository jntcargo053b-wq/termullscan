import 'package:flutter_test/flutter_test.dart';
import 'package:termulscan/models/scan_entry.dart';
import 'package:termulscan/services/storage_service.dart';

void main() {
  test('buildTxtExport includes audit metadata and hides absolute media paths', () {
    final entry = ScanEntry(
      id: 'scan-1',
      value: 'ABC\n123',
      type: ScanType.barcode,
      imagePath: r'C:\captures\proof-1.jpg,C:\captures\proof-2.jpg',
      videoPath: r'C:\captures\delivery.mp4',
      timestamp: DateTime(2026, 7, 26, 14, 30),
      operatorName: 'Operator A',
      companyName: 'PT Contoh',
      latitude: -6.2,
      longitude: 106.8,
      locationName: 'Gudang Utama',
      address: 'Jalan Contoh 1',
      videoDuration: 65,
      isManual: true,
    );

    final result = StorageService().buildTxtExport(
      [entry],
      generatedAt: DateTime.utc(2026, 7, 26),
    );

    expect(result, contains('Jumlah data: 1'));
    expect(result, contains('Kode: ABC 123'));
    expect(result, contains('Operator: Operator A'));
    expect(result, contains('Lokasi: Gudang Utama'));
    expect(result, contains('Koordinat: -6.2, 106.8'));
    expect(result, contains('Foto (2): proof-1.jpg, proof-2.jpg'));
    expect(result, contains('Video: delivery.mp4'));
    expect(result, contains('Durasi: 01:05'));
    expect(result, isNot(contains(r'C:\captures')));
  });
}
