import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/background_service.dart';

void main() {
  test('without the microphone the service is location only (Android 14+ would refuse a microphone type)', () {
    expect(BackgroundService.serviceTypesFor(micGranted: false), [ForegroundServiceTypes.location]);
  });

  test('with the microphone the intercom also works with the screen off', () {
    expect(BackgroundService.serviceTypesFor(micGranted: true), [ForegroundServiceTypes.location, ForegroundServiceTypes.microphone]);
  });

  test('dataSync is never requested (Android 15 limits it to 6 hours a day)', () {
    for (final mic in [true, false]) {
      expect(BackgroundService.serviceTypesFor(micGranted: mic), isNot(contains(ForegroundServiceTypes.dataSync)));
    }
  });
}
