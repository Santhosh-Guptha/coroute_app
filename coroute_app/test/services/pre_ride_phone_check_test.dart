import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/permissions/nearby_access.dart';
import 'package:coroute_app/data/models/device_diagnostic_report.dart';
import 'package:coroute_app/data/services/device_diagnostic_service.dart';
import 'package:coroute_app/data/services/sms_sender.dart';

/// A phone with fixed readings (no platform code).
class FakeProbe extends PhoneProbe {
  FakeProbe({
    this.nat = const {},
    this.gps,
    this.precise,
    this.mic,
    this.level,
    this.charging = false,
    this.compose = true,
    this.nearby = NearbyAccess.notNeeded,
  });

  final Map<String, dynamic> nat;
  final GpsReading? gps;
  final bool? precise;
  final bool? mic;
  final int? level;
  final bool charging;
  final bool compose;
  final NearbyAccess nearby;

  @override
  bool get isMobile => true;
  @override
  bool get isAndroid => true;
  @override
  bool get isIOS => false;
  @override
  Future<bool> locationServiceEnabled() async => true;
  @override
  Future<Map<String, dynamic>> nativeProbe() async => nat;
  @override
  Future<GpsReading?> gpsReading() async => gps;
  @override
  Future<bool?> preciseLocation() async => precise;
  @override
  Future<bool?> micCaptureWorks() async => mic;
  @override
  Future<({int? level, bool charging})> battery() async => (level: level, charging: charging);
  @override
  Future<bool> smsComposerAvailable() async => compose;
  @override
  Future<SmsCapability> smsCapability() async => SmsCapability(hasTelephony: compose, permission: compose, simReady: compose);
  @override
  Future<bool?> canDial() async => null;
  @override
  Future<bool?> compassAvailable() async => null;
  @override
  Future<NearbyAccess> nearbyAccess(int sdk) async => nearby;
}

const Map<String, dynamic> healthy = {
  'accelPresent': true,
  'accelHz': 49.6,
  'gyroPresent': true,
  'gyroHz': 50.1,
  'magPresent': true,
  'magHz': 50.0,
  'bgRestricted': false,
  'powerSave': false,
  'dndFilter': 1,
  'mediaVol': 10,
  'mediaVolMax': 15,
  'alarmVol': 5,
  'alarmVolMax': 7,
  'btOut': 'sco',
  'btMic': true,
  'wiredOut': false,
  'freeBytes': 5000000000,
  'canDial': true,
};

DiagnosticCheckItem item(DeviceDiagnosticReport r, String key) => r.allChecks.firstWhere((c) => c.key == key);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a healthy phone passes every safety item; nothing fails', () async {
    final service = DeviceDiagnosticService(
      probe: FakeProbe(
        nat: healthy,
        gps: const GpsReading(accuracyM: 6, speedKmh: 0),
        precise: true,
        mic: true,
        level: 82,
      ),
    );
    final r = await service.runFullDiagnostic();
    expect(r.allChecks.where((c) => c.verdict == CheckVerdict.fail), isEmpty);
    expect(r.readiness, isNot(RideReadiness.notReady));
    for (final key in ['accel_stream', 'gyro_stream', 'compass', 'gps_fix', 'precise_location', 'headset', 'media_volume',
      'do_not_disturb', 'mic_capture', 'battery_level', 'bg_restricted', 'storage_free', 'crash_ready']) {
      expect(item(r, key).verdict, CheckVerdict.pass, reason: key);
    }
    expect(item(r, 'accel_stream').metadata?['hz'], 50);
    expect(DeviceDiagnosticReport.validatePrivacySafety(r.toJson()), isTrue);
  });

  test('3.57 emergency texts: allowed with a SIM passes; not allowed warns with the disclosure fix', () async {
    final ok = await DeviceDiagnosticService(probe: FakeProbe(nat: healthy, level: 80)).runFullDiagnostic();
    expect(item(ok, 'sos_sms_capability').verdict, CheckVerdict.pass);
    const denied = SmsCapability(hasTelephony: true, permission: false, simReady: true);
    expect(DeviceDiagnosticService.emergencyTextsReady(denied, canCompose: true, android: true), isFalse);
    expect(DeviceDiagnosticService.emergencyTextsDetail(denied, canCompose: true, android: true), contains('messages app'));
    const noSim = SmsCapability(hasTelephony: true, permission: true, simReady: false);
    expect(DeviceDiagnosticService.emergencyTextsDetail(noSim, canCompose: true, android: true), contains('no SIM'));
    const ready = SmsCapability(hasTelephony: true, permission: true, simReady: true);
    expect(DeviceDiagnosticService.emergencyTextsDetail(ready, canCompose: true, android: true), contains('by itself'));
  });

  test('a phone with safety problems is "not ready", each with a one-tap fix, and stays rideable', () async {
    final service = DeviceDiagnosticService(
      probe: FakeProbe(
        nat: {
          ...healthy,
          'accelHz': 0.0,
          'bgRestricted': true,
          'dndFilter': 3,
          'mediaVol': 0,
          'alarmVol': 0,
          'btOut': 'none',
        },
        gps: const GpsReading(accuracyM: 120, speedKmh: 0),
        precise: false,
        mic: false,
        level: 9,
      ),
    );
    final r = await service.runFullDiagnostic();
    expect(r.readiness, RideReadiness.notReady);
    expect(r.overallResult, DiagnosticOverallResult.criticalIssueDetected);
    expect(item(r, 'accel_stream').verdict, CheckVerdict.fail);
    expect(item(r, 'crash_ready').verdict, CheckVerdict.fail);
    expect(item(r, 'bg_restricted').fix, PhoneCheckFix.backgroundUse, reason: 'opens the battery page, not the app settings root');
    expect(item(r, 'battery_level').verdict, CheckVerdict.fail);
    expect(item(r, 'do_not_disturb').fix, PhoneCheckFix.sound);
    expect(item(r, 'media_volume').fix, PhoneCheckFix.sound);
    expect(item(r, 'alarm_volume').verdict, CheckVerdict.warn);
    expect(item(r, 'precise_location').fix, PhoneCheckFix.preciseLocation);
    expect(item(r, 'gps_fix').fix, PhoneCheckFix.retry);
    expect(item(r, 'headset').verdict, CheckVerdict.warn);
    expect(item(r, 'mic_capture').verdict, CheckVerdict.warn);
    // Failures are listed before warnings.
    final problems = r.problems;
    final firstWarn = problems.indexWhere((c) => c.verdict == CheckVerdict.warn);
    expect(problems.take(firstWarn).every((c) => c.verdict == CheckVerdict.fail), isTrue);
    expect(r.overallSummary, contains('Motion data'));
    expect(DeviceDiagnosticReport.validatePrivacySafety(r.toJson()), isTrue);
  });

  test('crash detection switched off is a warning with a fix; no microphone test while riding', () async {
    SharedPreferences.setMockInitialValues({'coroute_crash_detection': false});
    final service = DeviceDiagnosticService(
      probe: FakeProbe(nat: healthy, gps: const GpsReading(accuracyM: 6, speedKmh: 0), precise: true, mic: true, level: 90),
    );
    final r = await service.runFullDiagnostic(micTest: false);
    expect(item(r, 'crash_setting').fix, PhoneCheckFix.crashDetection);
    expect(item(r, 'crash_setting').verdict, CheckVerdict.warn);
    expect(r.allChecks.any((c) => c.key == 'mic_capture'), isFalse);
  });

  test('Nearby devices: hidden when not needed, a warning (never a blocker) when missing, after background', () async {
    final none = await DeviceDiagnosticService(probe: FakeProbe(nat: healthy, level: 80)).runFullDiagnostic();
    expect(none.allChecks.any((c) => c.key == NearbyDevicesCheck.key), isFalse);

    final ok = await DeviceDiagnosticService(probe: FakeProbe(nat: healthy, level: 80, nearby: NearbyAccess.granted))
        .runFullDiagnostic();
    expect(item(ok, NearbyDevicesCheck.key).verdict, CheckVerdict.pass);

    final missing = await DeviceDiagnosticService(
      probe: FakeProbe(
        nat: healthy,
        gps: const GpsReading(accuracyM: 6, speedKmh: 0),
        precise: true,
        mic: true,
        level: 80,
        nearby: NearbyAccess.denied,
      ),
    ).runFullDiagnostic();
    final n = item(missing, NearbyDevicesCheck.key);
    expect(n.verdict, CheckVerdict.warn);
    expect(n.isCritical, isFalse);
    expect(n.fix, PhoneCheckFix.nearbyDevices);
    expect(n.detail, NearbyDevicesCheck.warnText);
    expect(missing.readiness, isNot(RideReadiness.notReady));
    final keys = missing.categories.keys.toList();
    expect(keys.indexOf('nearby_devices'), greaterThan(keys.indexOf('gps')));
    expect(keys.indexOf('nearby_devices'), greaterThan(keys.indexOf('background_execution')));

    final blocked = await DeviceDiagnosticService(
      probe: FakeProbe(nat: healthy, level: 80, nearby: NearbyAccess.permanentlyDenied),
    ).runFullDiagnostic();
    expect(item(blocked, NearbyDevicesCheck.key).fix, PhoneCheckFix.appSettings);
    expect(DeviceDiagnosticReport.validatePrivacySafety(blocked.toJson()), isTrue);
  });

  test('verdict mapping: critical problems fail, other problems warn', () {
    const crit = DiagnosticCheckItem(key: 'a', name: 'A', status: DiagnosticStatus.permissionRequired, detail: '', isCritical: true);
    const soft = DiagnosticCheckItem(key: 'b', name: 'B', status: DiagnosticStatus.failed, detail: '');
    const ok = DiagnosticCheckItem(key: 'c', name: 'C', status: DiagnosticStatus.supported, detail: '');
    const untested = DiagnosticCheckItem(key: 'd', name: 'D', status: DiagnosticStatus.notTested, detail: '');
    expect(crit.verdict, CheckVerdict.fail);
    expect(soft.verdict, CheckVerdict.warn);
    expect(ok.verdict, CheckVerdict.pass);
    expect(untested.verdict, CheckVerdict.warn);
  });
}
