import 'package:flutter_test/flutter_test.dart';
import 'package:termulscan/models/scan_entry.dart';

void main() {
  test('ScanEntry dapat di-backup dan dibaca kembali', () {
    final timestamp = DateTime(2026, 7, 25, 10, 30);
    final entry = ScanEntry(
      id: 'entry-1',
      value: 'ABC-123',
      type: ScanType.barcode,
      imagePath: '/data/photos/a.jpg,/data/photos/b.jpg',
      videoPath: '/data/videos/a.mp4',
      timestamp: timestamp,
      operatorName: 'Operator',
      latitude: -6.2,
      longitude: 106.8,
    );

    final restored = ScanEntry.fromJson(entry.toJson());

    expect(restored.id, entry.id);
    expect(restored.value, entry.value);
    expect(restored.type, ScanType.barcode);
    expect(restored.timestamp, timestamp);
    expect(restored.photoPaths, hasLength(2));
    expect(restored.videoPath, entry.videoPath);
  });

  test('ScanEntry copyWith dapat membersihkan metadata lokasi lama', () {
    final entry = ScanEntry(
      id: 'entry-location',
      value: 'ABC-LOCATION',
      type: ScanType.barcode,
      timestamp: DateTime(2026, 7, 26),
      operatorName: 'Operator',
      latitude: -6.2,
      longitude: 106.8,
      locationName: 'Jakarta',
      address: 'Jalan Lama',
    );

    final withoutLocation = entry.copyWith(clearLocation: true);

    expect(withoutLocation.latitude, isNull);
    expect(withoutLocation.longitude, isNull);
    expect(withoutLocation.locationName, isNull);
    expect(withoutLocation.address, isNull);
  });
}
