import 'package:flutter_test/flutter_test.dart';
import 'package:termulscan/services/pod_location_service.dart';

void main() {
  PodLocationState freshState() => PodLocationState(
        lat: -6.2,
        lon: 106.8,
        accuracy: 8,
        positionTimestamp: DateTime.now(),
        confidence: PodConfidence.good,
        address: 'Jakarta',
        addressLat: -6.2,
        addressLon: 106.8,
        mode: PodGpsMode.locked,
      );

  test('fresh live non-mock position is valid evidence', () {
    final state = freshState();

    expect(state.isEvidenceReady, isTrue);
    expect(state.hasMatchingAddress, isTrue);
    expect(state.evidenceAddress, 'Jakarta');
  });

  test('cached, stale, old, and mocked positions are rejected', () {
    final fresh = freshState();

    expect(fresh.copyWith(positionFromCache: true).isEvidenceReady, isFalse);
    expect(fresh.copyWith(mode: PodGpsMode.stale).isEvidenceReady, isFalse);
    expect(
      fresh
          .copyWith(
            positionTimestamp: DateTime.now().subtract(
              PodLocationState.evidenceMaxAge + const Duration(seconds: 1),
            ),
          )
          .isEvidenceReady,
      isFalse,
    );
    expect(fresh.copyWith(mockDetected: true).isEvidenceReady, isFalse);
  });

  test('address is only exposed when it matches the current coordinates', () {
    final state = freshState().copyWith(
      addressLat: -7.0,
      addressLon: 107.0,
    );

    expect(state.isEvidenceReady, isTrue);
    expect(state.hasMatchingAddress, isFalse);
    expect(state.evidenceAddress, isEmpty);
  });

  test('copyWith can explicitly clear nullable position and address fields', () {
    final state = freshState().copyWith(
      clearPosition: true,
      clearAddress: true,
      clearLockResult: true,
    );

    expect(state.hasPosition, isFalse);
    expect(state.positionTimestamp, isNull);
    expect(state.address, isEmpty);
    expect(state.addressLat, isNull);
    expect(state.addressLon, isNull);
    expect(state.isEvidenceReady, isFalse);
  });
}
