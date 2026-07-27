import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:termulscan/services/pod_gps_engine.dart';

Position position({bool isMocked = false}) => Position(
      longitude: 106.8,
      latitude: -6.2,
      timestamp: DateTime.now(),
      accuracy: 8,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
      isMocked: isMocked,
    );

void main() {
  test('service deadline can force-lock accepted live samples', () {
    final engine = PodGpsEngine();
    addTearDown(engine.dispose);

    engine.processSample(position());

    expect(engine.forceLockIfPossible(), isTrue);
    expect(engine.isLocked, isTrue);
    expect(engine.isFallbackLock, isTrue);
    expect(engine.confidence, PodConfidence.good);
    expect(engine.lockResult, isNotNull);
  });

  test('mock sample cannot be force-locked', () {
    final engine = PodGpsEngine();
    addTearDown(engine.dispose);

    engine.processSample(position(isMocked: true));

    expect(engine.forceLockIfPossible(), isFalse);
    expect(engine.isLocked, isFalse);
    expect(engine.lockResult, isNull);
  });
}
