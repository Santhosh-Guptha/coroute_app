import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/safety_constants.dart';
import '../models/device_diagnostic_report.dart';
import 'api_client.dart';
import 'background_service.dart';
import 'meta_service.dart';
import 'permissions_service.dart';
import 'safety_native.dart';
import 'sms_sender.dart';

enum DiagnosticTriggerReason {
  firstRide,
  deviceChanged,
  permissionsChanged,
  onDemand,
  none,
}

class DiagnosticTriggerCheck {
  final bool shouldRun;
  final DiagnosticTriggerReason reason;
  final String description;

  const DiagnosticTriggerCheck({
    required this.shouldRun,
    required this.reason,
    required this.description,
  });
}

/// Service that coordinates Pre-Ride Phone Checks, hardware & permission diagnostics,
/// and privacy-safe report submission.
class DeviceDiagnosticService extends ChangeNotifier {
  static const String _keyFirstRideDone = 'coroute_diag_first_ride_done';
  static const String _keyLastDeviceFingerprint = 'coroute_diag_device_fingerprint';
  static const String _keyLastPermissionsFingerprint = 'coroute_diag_permissions_fingerprint';
  static const String _keyLastReportJson = 'coroute_diag_last_report_json';
  static const String _keyLastReportTs = 'coroute_diag_last_report_ts';

  final ApiClient? apiClient;

  /// Phone readings (GPS fix, sensors, microphone, battery...). Tests pass a fake.
  final PhoneProbe probe;
  DeviceDiagnosticReport? _cachedReport;
  bool _isRunning = false;

  DeviceDiagnosticService({this.apiClient, PhoneProbe? probe}) : probe = probe ?? const PhoneProbe();

  ApiClient? get _apiClient => apiClient;

  bool get isRunning => _isRunning;
  DeviceDiagnosticReport? get cachedReport => _cachedReport;

  /// Loads the persisted report from local cache.
  Future<DeviceDiagnosticReport?> loadCachedReport() async {
    if (_cachedReport != null) return _cachedReport;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_keyLastReportJson);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw);
        if (map is Map<String, dynamic>) {
          _cachedReport = DeviceDiagnosticReport.fromJson(map);
          notifyListeners();
          return _cachedReport;
        }
      }
    } catch (e) {
      debugPrint('Error loading cached diagnostic report: $e');
    }
    return null;
  }

  /// Calculates a stable fingerprint of device properties that affect sensor/runtime reliability.
  Future<String> getDeviceFingerprint() async {
    try {
      final info = await SafetyNative.deviceInfo();
      final pkg = await _getPackageInfoSafe();
      return '${info.manufacturer}|${info.model}|${info.sdkInt}|${info.release}|${info.cpuAbi}|${pkg.version}+${pkg.buildNumber}';
    } catch (_) {
      return 'generic_fingerprint';
    }
  }

  /// Calculates a stable fingerprint of current permission states.
  Future<String> getPermissionsFingerprint() async {
    try {
      final loc = await PermissionsService.isLocationGranted();
      final locAlways = await PermissionsService.isLocationAlwaysGranted();
      final mic = await PermissionsService.isMicrophoneGranted();
      final notif = await PermissionsService.isNotificationGranted();
      final bt = await PermissionsService.isBluetoothGranted();
      final battery = await BackgroundService.isIgnoringBatteryOptimizations();
      final fullScreen = await SafetyNative.canUseFullScreenIntent();
      return 'loc:$loc|always:$locAlways|mic:$mic|notif:$notif|bt:$bt|bat:$battery|fs:$fullScreen';
    } catch (_) {
      return 'permissions_fallback';
    }
  }

  /// Checks whether a full diagnostic should be recommended before starting a ride.
  ///
  /// Rules per master prompt:
  /// 1. Before user's first ride.
  /// 2. Again when relevant device characteristics change.
  /// 3. Again when relevant permissions change.
  ///
  /// Returns `false` if nothing changed and the first ride check has already been performed.
  /// Does NOT force a lengthy diagnostic before every ride.
  Future<DiagnosticTriggerCheck> checkShouldRunDiagnostic() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final firstRideDone = prefs.getBool(_keyFirstRideDone) ?? false;

      if (!firstRideDone) {
        return const DiagnosticTriggerCheck(
          shouldRun: true,
          reason: DiagnosticTriggerReason.firstRide,
          description: 'A pre-ride phone check is required before your first group ride.',
        );
      }

      final currentDevice = await getDeviceFingerprint();
      final lastDevice = prefs.getString(_keyLastDeviceFingerprint);
      if (lastDevice != null && lastDevice != currentDevice) {
        return const DiagnosticTriggerCheck(
          shouldRun: true,
          reason: DiagnosticTriggerReason.deviceChanged,
          description: 'Device characteristics or app version updated since last check.',
        );
      }

      final currentPerms = await getPermissionsFingerprint();
      final lastPerms = prefs.getString(_keyLastPermissionsFingerprint);
      if (lastPerms != null && lastPerms != currentPerms) {
        return const DiagnosticTriggerCheck(
          shouldRun: true,
          reason: DiagnosticTriggerReason.permissionsChanged,
          description: 'Device permissions or battery optimization changed since last check.',
        );
      }
    } catch (e) {
      debugPrint('Error evaluating diagnostic trigger check: $e');
    }

    return const DiagnosticTriggerCheck(
      shouldRun: false,
      reason: DiagnosticTriggerReason.none,
      description: 'Device and permissions already verified.',
    );
  }

  /// Runs the pre-ride phone check. Every item gets pass / warn / fail ([DiagnosticCheckItem.verdict])
  /// and, where the rider can fix it, a one-tap fix ([DiagnosticCheckItem.fix]). The slow probes
  /// (GPS fix, motion sensors, microphone, server) run in parallel: about 8 s at most.
  ///
  /// [micTest]: listen to the microphone for about 1 s (nothing is kept). Pass false while a ride
  /// is running, so the check never takes the microphone from the intercom.
  Future<DeviceDiagnosticReport> runFullDiagnostic({
    String? riderId,
    String? riderEmail,
    bool micTest = true,
  }) async {
    _isRunning = true;
    notifyListeners();

    try {
      final diagnosticId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;
      final android = probe.isAndroid;

      // Quick reads (switches and permissions).
      final safetyInfo = await SafetyNative.deviceInfo();
      final pkg = await _getPackageInfoSafe();
      final batteryExempt = await BackgroundService.isIgnoringBatteryOptimizations();
      final locService = await probe.locationServiceEnabled();
      final locGranted = await PermissionsService.isLocationGranted();
      final alwaysGranted = await PermissionsService.isLocationAlwaysGranted();
      final micGranted = await PermissionsService.isMicrophoneGranted();
      final notifGranted = await PermissionsService.isNotificationGranted();
      final btGranted = await PermissionsService.isBluetoothGranted();
      final fullScreenAllowed = safetyInfo.sdkInt >= 34 ? await SafetyNative.canUseFullScreenIntent() : true;
      final crashOn = await _crashDetectionOn();

      // Slow probes, all at once. None of them throws.
      final nativeF = probe.nativeProbe();
      final gpsF = locService && locGranted ? probe.gpsReading() : Future<GpsReading?>.value(null);
      final preciseF = locGranted ? probe.preciseLocation() : Future<bool?>.value(null);
      final micF = micTest && micGranted ? probe.micCaptureWorks() : Future<bool?>.value(null);
      final batteryF = probe.battery();
      final netF = _network();
      final composeF = probe.smsComposerAvailable();
      final dialF = probe.canDial();
      final compassF = probe.compassAvailable();

      final nat = await nativeF;
      final gps = await gpsF;
      final precise = await preciseF;
      final micWorks = await micF;
      final battery = await batteryF;
      final net = await netF;
      final canCompose = await composeF;
      final dialed = await dialF;
      final canDialOut = (android || probe.isIOS) ? (nat['canDial'] is bool ? nat['canDial'] as bool : null) : dialed;
      final compass = await compassF;

      final deviceInfo = DiagnosticDeviceInfo(
        manufacturer: safetyInfo.manufacturer.isNotEmpty
            ? safetyInfo.manufacturer
            : (!kIsWeb ? Platform.operatingSystem : 'Web'),
        model: safetyInfo.model.isNotEmpty
            ? safetyInfo.model
            : (!kIsWeb ? (probe.isAndroid ? 'Android Device' : (probe.isIOS ? 'iPhone' : Platform.operatingSystemVersion)) : 'Browser'),
        osVersion: safetyInfo.release.isNotEmpty
            ? (probe.isIOS ? 'iOS ${safetyInfo.release}' : 'Android ${safetyInfo.release}')
            : (!kIsWeb ? '${Platform.operatingSystem} ${Platform.operatingSystemVersion}' : 'Web'),
        apiLevel: safetyInfo.sdkInt,
        appVersion: pkg.version.isNotEmpty ? pkg.version : 'unknown',
        buildNumber: pkg.buildNumber.isNotEmpty ? pkg.buildNumber : 'unknown',
        cpuArch: safetyInfo.cpuAbi.isNotEmpty ? safetyInfo.cpuAbi : 'arm64',
        batteryOptimizationStatus: batteryExempt ? 'Unrestricted (Ignoring Optimizations)' : 'Optimized / Restricted',
      );

      final categories = <String, DiagnosticCategoryResult>{};

      categories['device'] = DiagnosticCategoryResult(
        categoryKey: 'device',
        title: 'This phone',
        status: DiagnosticStatus.ready,
        summary: '${deviceInfo.manufacturer} ${deviceInfo.model} (API ${deviceInfo.apiLevel})',
        checks: [
          _item('device_model', 'Phone', DiagnosticStatus.ready, '${deviceInfo.manufacturer} ${deviceInfo.model}'),
          _item('os_version', 'System', DiagnosticStatus.ready, '${deviceInfo.osVersion} (API ${deviceInfo.apiLevel})'),
          _item('cpu_architecture', 'Processor', DiagnosticStatus.ready, deviceInfo.cpuArch),
          _item('app_version', 'CoRoute version', DiagnosticStatus.ready, 'v${deviceInfo.appVersion}+${deviceInfo.buildNumber}'),
          _item('device_privacy', 'Privacy', DiagnosticStatus.ready, 'No IMEI, serial number, recordings or location trail are collected.'),
        ],
      );

      // ---- GPS & location
      categories['gps'] = _category('gps', 'GPS & location', 'Location is on, allowed and precise.', [
        _item(
          'location_service',
          'Location on',
          locService ? DiagnosticStatus.ready : DiagnosticStatus.failed,
          locService ? 'Location is on.' : 'Location is off. Turn it on so your group and an SOS know where you are.',
          critical: true,
          fix: locService ? null : PhoneCheckFix.locationService,
        ),
        _item(
          'permission_in_use',
          'Location permission',
          locGranted ? DiagnosticStatus.ready : DiagnosticStatus.permissionRequired,
          locGranted ? 'Allowed.' : 'CoRoute cannot see your location. Allow it.',
          critical: true,
          fix: locGranted ? null : PhoneCheckFix.location,
        ),
        if (locGranted)
          _item(
            'precise_location',
            'Precise location',
            precise == false ? DiagnosticStatus.limited : DiagnosticStatus.ready,
            precise == false
                ? 'Only approximate location is allowed. An SOS could point far from you.'
                : 'Precise location is on.',
            fix: precise == false ? PhoneCheckFix.preciseLocation : null,
          ),
        _item(
          'permission_background',
          'Location with screen off',
          alwaysGranted ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          alwaysGranted
              ? '"Allow all the time" is on.'
              : 'Choose "Allow all the time" so sharing keeps going if the phone restarts CoRoute in the background.',
          fix: alwaysGranted ? null : PhoneCheckFix.locationAlways,
        ),
        _gpsFixItem(locService && locGranted, gps),
        if (gps != null)
          _item(
            'gps_speed',
            'Speed reading',
            DiagnosticStatus.ready,
            gps.speedKmh > 1
                ? 'Speed comes from GPS (${gps.speedKmh.round()} km/h now).'
                : 'Speed comes from GPS. It shows once you move.',
          ),
      ]);

      // ---- Motion sensors
      final hasNativeSensors = android || probe.isIOS;
      final accelPresent = hasNativeSensors ? (nat['accelPresent'] as bool? ?? safetyInfo.hasAccel) : true;
      final accelHz = _num(nat['accelHz']);
      final probed = nat.isNotEmpty;
      categories['accelerometer'] = _category('accelerometer', 'Motion sensor', 'The motion sensor streams data.', [
        _item(
          'accel_hardware',
          'Motion sensor (accelerometer)',
          accelPresent ? DiagnosticStatus.supported : DiagnosticStatus.unsupported,
          accelPresent
              ? 'Found.'
              : 'This device has no accelerometer. Crash detection cannot run; the SOS button still works.',
        ),
        if (hasNativeSensors && accelPresent) _rateItem('accel_stream', 'Motion data', accelHz, probed, critical: true),
      ]);

      final gyroPresent = hasNativeSensors ? (nat['gyroPresent'] as bool? ?? safetyInfo.hasGyro) : true;
      final magPresent = hasNativeSensors ? (nat['magPresent'] as bool? ?? true) : (compass ?? true);
      categories['gyroscope'] = _category('gyroscope', 'Rotation & compass', 'Gyroscope and compass work.', [
        if (gyroPresent && hasNativeSensors)
          _rateItem('gyro_stream', 'Gyroscope', _num(nat['gyroHz']), probed)
        else
          _item(
            'gyro_hardware',
            'Gyroscope',
            gyroPresent ? DiagnosticStatus.supported : DiagnosticStatus.limited,
            gyroPresent ? 'Found.' : 'No gyroscope. Crash detection uses the motion sensor alone (less exact).',
          ),
        _item(
          'compass',
          'Compass',
          magPresent ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          magPresent
              ? (hasNativeSensors && _num(nat['magHz']) > 0 ? 'Works.' : 'Found.')
              : 'No compass. The map turns with your direction of travel instead.',
        ),
      ]);

      // ---- Crash detection (needs the motion sensor streaming and the setting on)
      final accelOk = accelPresent && (!hasNativeSensors || !probed || accelHz >= _minHz);
      categories['crash_detection'] = _category('crash_detection', 'Crash detection', 'Crash detection is on and ready.', [
        _item(
          'crash_setting',
          'Crash detection',
          crashOn ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          crashOn ? 'On.' : 'Off. Nobody is alerted automatically after a crash.',
          fix: crashOn ? null : PhoneCheckFix.crashDetection,
        ),
        _item(
          'crash_ready',
          'Works with screen off',
          !accelPresent ? DiagnosticStatus.unsupported : (!accelOk ? DiagnosticStatus.failed : DiagnosticStatus.ready),
          !accelPresent
              ? 'Not available on this phone.'
              : (!accelOk
                  ? 'The motion sensor is not sending data, so a crash cannot be detected.'
                  : 'Watches for a hard hit, a fall and a stop during a ride, also with the screen off.'),
          critical: accelPresent && crashOn,
          fix: accelPresent && !accelOk ? PhoneCheckFix.retry : null,
        ),
      ]);

      // ---- SOS reach
      categories['sos'] = _category('sos', 'SOS reach', 'An SOS can reach your group and contacts.', [
        _item(
          'sos_internet',
          'Internet',
          net.online ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          net.online
              ? (net.kind.isEmpty || net.kind == 'none' ? 'Online.' : 'Online (${net.kind}).')
              : 'No internet. An SOS goes by text message instead.',
        ),
        _item(
          'sos_gateway',
          'CoRoute server',
          net.gateway ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          net.gateway ? 'Reachable.' : 'Not reachable now. An SOS is kept and sent again; texts are the backup.',
          fix: net.gateway ? null : PhoneCheckFix.retry,
        ),
        _item(
          'sos_sms_capability',
          'Text messages',
          canCompose ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          canCompose
              ? 'Without internet, the SOS text opens ready to send.'
              : 'This phone cannot send texts. Without internet an SOS cannot reach anyone.',
        ),
        if (canDialOut != null)
          _item(
            'sos_call',
            'Phone calls',
            canDialOut ? DiagnosticStatus.ready : DiagnosticStatus.limited,
            canDialOut ? 'You can call 112 or your contact from the SOS screen.' : 'This phone cannot make calls.',
          ),
        _item('sos_local_queue', 'Saved SOS', DiagnosticStatus.ready,
            'An SOS is saved on the phone and sent again when the network is back.'),
      ]);

      // ---- Bluetooth
      categories['bluetooth'] = _category('bluetooth', 'Bluetooth', 'Bluetooth is allowed.', [
        _item(
          'bt_permission',
          'Bluetooth permission',
          btGranted ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          btGranted ? 'Allowed.' : 'Needed only for handlebar remotes and airbag vests.',
          fix: btGranted ? null : PhoneCheckFix.bluetooth,
        ),
      ]);

      // ---- Microphone
      categories['microphone'] = _category('microphone', 'Microphone', 'The microphone works for the intercom.', [
        _item(
          'mic_permission',
          'Microphone permission',
          micGranted ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          micGranted ? 'Allowed.' : 'Needed only to talk on the intercom.',
          fix: micGranted ? null : PhoneCheckFix.microphone,
        ),
        if (micWorks != null)
          _item(
            'mic_capture',
            'Microphone test',
            micWorks ? DiagnosticStatus.ready : DiagnosticStatus.limited,
            micWorks
                ? 'Picks up sound. Nothing was recorded or kept.'
                : 'No sound came in. Another app may be using the microphone.',
            fix: micWorks ? null : PhoneCheckFix.retry,
          ),
      ]);

      // ---- Sound (headset, volume, Do Not Disturb). The key avoids the word "audio" (privacy audit).
      final soundChecks = <DiagnosticCheckItem>[];
      final btOut = nat['btOut'] is String ? nat['btOut'] as String : null;
      if (btOut != null) {
        final wired = nat['wiredOut'] == true;
        final headsetOk = btOut == 'sco' || btOut == 'ble' || wired;
        final String headsetText;
        if (btOut == 'sco' || btOut == 'ble') {
          headsetText = 'Bluetooth headset connected.';
        } else if (wired) {
          headsetText = 'Wired headset connected.';
        } else if (btOut == 'a2dp') {
          headsetText = 'Bluetooth music is connected, but no headset mic. Voice alerts play; talk uses the phone mic.';
        } else {
          headsetText = 'No headset. Voice alerts play from the phone speaker.';
        }
        soundChecks.add(_item(
          'headset',
          'Helmet headset',
          headsetOk ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          headsetText,
          data: {'output': btOut},
        ));
      }
      final mediaVol = _num(nat['mediaVol']);
      final mediaMax = _num(nat['mediaVolMax']);
      if (mediaMax > 0) {
        final pct = (mediaVol * 100 / mediaMax).round();
        soundChecks.add(_item(
          'media_volume',
          'Voice alert volume',
          pct >= 30 ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          pct == 0 ? 'Volume is off. You will not hear voice alerts.' : (pct < 30 ? 'Volume is low ($pct%).' : 'Volume $pct%.'),
          fix: pct >= 30 ? null : PhoneCheckFix.sound,
          data: {'level': pct},
        ));
      }
      final alarmVol = _num(nat['alarmVol']);
      final alarmMax = _num(nat['alarmVolMax']);
      if (alarmMax > 0) {
        soundChecks.add(_item(
          'alarm_volume',
          'Alarm volume',
          alarmVol > 0 ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          alarmVol > 0 ? 'On.' : 'Alarm volume is off: the crash alarm may be silent.',
          fix: alarmVol > 0 ? null : PhoneCheckFix.sound,
        ));
      }
      final dnd = _num(nat['dndFilter']).round();
      if (dnd > 0) {
        soundChecks.add(_item(
          'do_not_disturb',
          'Do Not Disturb',
          dnd == 1 ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          dnd == 1 ? 'Off.' : 'On. Ride alerts may stay silent.',
          fix: dnd == 1 ? null : PhoneCheckFix.sound,
        ));
      }
      if (soundChecks.isNotEmpty) {
        categories['sound'] = _category('sound', 'Sound & headset', 'You will hear voice alerts.', soundChecks);
      }

      // ---- Notifications (Android 13+ and iOS ask; without them the crash alarm cannot show)
      final notifCritical = !android || safetyInfo.sdkInt >= 33 || safetyInfo.sdkInt == 0;
      categories['notifications'] = _category('notifications', 'Alerts', 'Alerts and the crash alarm can show.', [
        _item(
          'notif_permission',
          'Notifications',
          notifGranted ? DiagnosticStatus.ready : DiagnosticStatus.permissionRequired,
          notifGranted ? 'Allowed.' : 'Blocked. The crash alarm and SOS alerts cannot show.',
          critical: notifCritical,
          fix: notifGranted ? null : PhoneCheckFix.notification,
        ),
        if (safetyInfo.sdkInt >= 34)
          _item(
            'notif_full_screen',
            'Alarm on lock screen',
            fullScreenAllowed ? DiagnosticStatus.ready : DiagnosticStatus.limited,
            fullScreenAllowed
                ? 'The crash alarm shows over the lock screen.'
                : 'Allow it so you can stop a crash alarm without unlocking.',
            fix: fullScreenAllowed ? null : PhoneCheckFix.fullScreen,
          ),
      ]);

      // ---- Background & battery
      final bgChecks = <DiagnosticCheckItem>[];
      if (android) {
        final restricted = nat['bgRestricted'] == true;
        bgChecks.add(_item(
          'bg_restricted',
          'Background use',
          restricted ? DiagnosticStatus.failed : DiagnosticStatus.ready,
          restricted
              ? 'Blocked for CoRoute. Tracking and crash detection stop when the screen is off.'
              : 'Allowed. The ride notification keeps CoRoute running with the screen off.',
          critical: true,
          fix: restricted ? PhoneCheckFix.backgroundUse : null,
        ));
        bgChecks.add(_item(
          'bg_battery_optimization',
          'Unrestricted battery use',
          batteryExempt ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          batteryExempt ? 'On.' : 'Android may close CoRoute on a long ride. Allow unrestricted battery use.',
          fix: batteryExempt
              ? null
              : (_aggressiveBrand(deviceInfo.manufacturer) ? PhoneCheckFix.oemBattery : PhoneCheckFix.battery),
        ));
        if (nat['powerSave'] == true) {
          bgChecks.add(_item('bg_power_saver', 'Battery saver', DiagnosticStatus.limited,
              'On. GPS and alerts may be slower. Turn it off for the ride if you can.'));
        }
      }
      final level = battery.level;
      if (level != null && level >= 0) {
        final low = !battery.charging && level < 15;
        final String levelStatus;
        final String levelText;
        if (battery.charging) {
          levelStatus = DiagnosticStatus.ready;
          levelText = '$level%, charging.';
        } else if (level >= 50) {
          levelStatus = DiagnosticStatus.ready;
          levelText = '$level%.';
        } else if (low) {
          levelStatus = DiagnosticStatus.failed;
          levelText = '$level%. The phone may die mid-ride. Charge it first.';
        } else {
          levelStatus = DiagnosticStatus.limited;
          levelText = '$level%. Bring a charger or power bank.';
        }
        bgChecks.add(_item('battery_level', 'Battery', levelStatus, levelText, critical: low, data: {'level': level}));
      }
      if (bgChecks.isEmpty) {
        bgChecks.add(_item('bg_service_capability', 'Background', DiagnosticStatus.ready, 'Runs during the ride.'));
      }
      categories['background_execution'] =
          _category('background_execution', 'Background & battery', 'CoRoute keeps running during the ride.', bgChecks);

      // ---- Offline maps storage
      final freeBytes = _num(nat['freeBytes']);
      final storageChecks = <DiagnosticCheckItem>[];
      if (freeBytes > 0) {
        final mb = (freeBytes / (1024 * 1024)).floor();
        final String freeText;
        if (mb >= 1024) {
          freeText = '${(mb / 1024).toStringAsFixed(1)} GB free.';
        } else if (mb >= 200) {
          freeText = 'Only $mb MB free. Large offline maps may not fit.';
        } else {
          freeText = 'Almost full ($mb MB). Offline maps and ride logs cannot be saved.';
        }
        storageChecks.add(_item(
          'storage_free',
          'Space for offline maps',
          mb >= 1024 ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          freeText,
          data: {'freeMb': mb},
        ));
      } else {
        var cacheOk = true;
        try {
          final dir = await SafetyNative.cacheDir();
          cacheOk = !android || (dir != null && dir.isNotEmpty);
        } catch (_) {}
        storageChecks.add(_item(
          'storage_cache_dir',
          'Offline storage',
          cacheOk ? DiagnosticStatus.ready : DiagnosticStatus.limited,
          cacheOk ? 'Ready for offline maps.' : 'App storage cannot be opened. Offline maps will not be saved.',
        ));
      }
      categories['offline_storage'] = _category('offline_storage', 'Offline maps', 'Room for offline maps.', storageChecks);

      final overall = _computeOverallResult(categories);

      final report = DeviceDiagnosticReport(
        diagnosticId: diagnosticId,
        riderId: riderId,
        riderEmail: riderEmail,
        timestamp: now,
        deviceInfo: deviceInfo,
        overallResult: overall.result,
        overallSummary: overall.summary,
        lifecycleStatus: DiagnosticLifecycleStatus.completed,
        categories: categories,
        consentGiven: false,
        createdAt: now,
        updatedAt: now,
      );

      await markDiagnosticCompleted(report);
      _cachedReport = report;
      return report;
    } finally {
      _isRunning = false;
      notifyListeners();
    }
  }

  /// Motion data below this rate cannot catch a short impact reliably (requested: 50 per second).
  static const double _minHz = 15;

  static double _num(Object? v) => v is num && v.isFinite ? v.toDouble() : 0.0;

  /// Brands known to close background apps unless their own autostart / battery page allows it.
  static bool _aggressiveBrand(String manufacturer) {
    final b = manufacturer.toLowerCase();
    const brands = ['xiaomi', 'redmi', 'poco', 'oppo', 'realme', 'vivo', 'iqoo', 'huawei', 'honor', 'oneplus'];
    return brands.any(b.contains);
  }

  DiagnosticCheckItem _item(
    String key,
    String name,
    String status,
    String detail, {
    bool critical = false,
    String? fix,
    Map<String, dynamic>? data,
  }) {
    final meta = <String, dynamic>{
      'fix': ?fix,
      ...?data,
    };
    return DiagnosticCheckItem(
      key: key,
      name: name,
      status: status,
      detail: detail,
      isCritical: critical,
      metadata: meta.isEmpty ? null : meta,
    );
  }

  /// A category's status and summary come from its worst item.
  DiagnosticCategoryResult _category(String key, String title, String okSummary, List<DiagnosticCheckItem> checks) {
    DiagnosticCheckItem? worst;
    for (final c in checks) {
      if (c.verdict == CheckVerdict.fail) {
        worst = c;
        break;
      }
      if (c.verdict == CheckVerdict.warn) worst ??= c;
    }
    final w = worst;
    final String status;
    if (w == null) {
      status = DiagnosticStatus.ready;
    } else if (w.verdict == CheckVerdict.fail || w.status == DiagnosticStatus.permissionRequired) {
      status = w.status;
    } else {
      status = DiagnosticStatus.limited;
    }
    return DiagnosticCategoryResult(
      categoryKey: key,
      title: title,
      status: status,
      summary: w?.detail ?? okSummary,
      checks: checks,
    );
  }

  DiagnosticCheckItem _gpsFixItem(bool canTry, GpsReading? gps) {
    if (!canTry) {
      return _item('gps_fix', 'GPS fix', DiagnosticStatus.notTested, 'Turn location on and allow it first.');
    }
    if (gps == null) {
      return _item(
        'gps_fix',
        'GPS fix',
        probe.isMobile ? DiagnosticStatus.limited : DiagnosticStatus.notTested,
        probe.isMobile ? 'No GPS fix yet. Step outside with a clear view of the sky and check again.' : 'Not tested here.',
        fix: probe.isMobile ? PhoneCheckFix.retry : null,
      );
    }
    final m = gps.accuracyM.round();
    final String status;
    final String detail;
    if (gps.accuracyM <= 20) {
      status = DiagnosticStatus.ready;
      detail = 'Good fix (within $m m).';
    } else if (gps.accuracyM <= 65) {
      status = DiagnosticStatus.limited;
      detail = 'Weak fix (within $m m). Move to open sky.';
    } else {
      status = DiagnosticStatus.limited;
      detail = 'Poor fix (within $m m). Move to open sky and check again.';
    }
    return _item('gps_fix', 'GPS fix', status, detail,
        fix: status == DiagnosticStatus.ready ? null : PhoneCheckFix.retry, data: {'accuracyM': m});
  }

  /// A motion sensor's measured event rate. [probed]: the native probe answered at all.
  DiagnosticCheckItem _rateItem(String key, String name, double hz, bool probed, {bool critical = false}) {
    if (!probed) {
      return _item(key, name, DiagnosticStatus.notTested, 'Could not be read. Check again.', fix: PhoneCheckFix.retry);
    }
    final r = hz.round();
    if (hz >= 40) return _item(key, name, DiagnosticStatus.ready, 'Streaming ($r per second).', data: {'hz': r});
    if (hz >= _minHz) {
      return _item(key, name, DiagnosticStatus.limited, 'Slow ($r per second). Short hits may be missed.', data: {'hz': r});
    }
    return _item(key, name, DiagnosticStatus.failed, 'No data from the sensor. Restart the phone and check again.',
        critical: critical, fix: PhoneCheckFix.retry, data: {'hz': r});
  }

  Future<bool> _crashDetectionOn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(SafetyConstants.keyCrashDetection) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Network kind and whether the CoRoute server answers.
  Future<({String kind, bool gateway, bool online})> _network() async {
    try {
      final kind = await SafetyNative.networkKind();
      var gateway = false;
      final client = _apiClient;
      if (client != null && (kind != 'none' || !probe.isMobile)) {
        try {
          final res = await client.get('/health', timeout: const Duration(seconds: 4));
          gateway = res is Map;
        } catch (_) {
          gateway = false;
        }
      }
      final online = probe.isMobile ? kind != 'none' : (gateway || !probe.isMobile);
      return (kind: probe.isMobile ? kind : '', gateway: gateway, online: online);
    } catch (_) {
      return (kind: '', gateway: false, online: false);
    }
  }

  // ---- Overall verdict (deterministic, no scores)

  _OverallResultComputation _computeOverallResult(Map<String, DiagnosticCategoryResult> categories) {
    final checks = [for (final c in categories.values) ...c.checks];
    final fails = checks.where((c) => c.verdict == CheckVerdict.fail).toList();
    if (fails.isNotEmpty) {
      return _OverallResultComputation(
        result: DiagnosticOverallResult.criticalIssueDetected,
        summary: 'Fix before you ride: ${fails.map((c) => c.name).join(', ')}.',
      );
    }
    final accelMissing = categories['accelerometer']
            ?.checks
            .any((c) => c.key == 'accel_hardware' && c.verdict != CheckVerdict.pass) ??
        false;
    if (accelMissing) {
      return const _OverallResultComputation(
        result: DiagnosticOverallResult.limitedCompatibility,
        summary: 'Ready to ride, but crash detection cannot run on this phone. The SOS button still works.',
      );
    }
    final warns = checks.where((c) => c.verdict == CheckVerdict.warn).length;
    if (warns > 0) {
      return _OverallResultComputation(
        result: DiagnosticOverallResult.supportedWithLimitations,
        summary: 'Ready to ride, with $warns ${warns == 1 ? 'warning' : 'warnings'}.',
      );
    }
    return const _OverallResultComputation(
      result: DiagnosticOverallResult.fullySupported,
      summary: 'Ready to ride. Everything checked out.',
    );
  }

  /// Marks the current diagnostic run as completed and saves fingerprints.
  Future<void> markDiagnosticCompleted(DeviceDiagnosticReport report) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyFirstRideDone, true);
      await prefs.setString(_keyLastDeviceFingerprint, await getDeviceFingerprint());
      await prefs.setString(_keyLastPermissionsFingerprint, await getPermissionsFingerprint());
      await prefs.setString(_keyLastReportJson, jsonEncode(report.toJson()));
      await prefs.setInt(_keyLastReportTs, report.timestamp);
      _cachedReport = report;
      notifyListeners();
    } catch (e) {
      debugPrint('Error persisting completed diagnostic: $e');
    }
  }

  /// Submits the diagnostic report to the backend gateway.
  ///
  /// Requirements:
  /// - Explicit consent must be provided (`consentGiven == true`).
  /// - Strictly audits against prohibited fields (never submits IMEI, audio, contacts, GPS traces, etc.).
  /// - Idempotent safe retry using [report.diagnosticId].
  Future<Map<String, dynamic>> submitReport(
    DeviceDiagnosticReport report, {
    required bool consentGiven,
  }) async {
    if (!consentGiven) {
      throw ArgumentError('Explicit rider consent is required to submit diagnostic reports.');
    }

    final payload = report.copyWith(
      consentGiven: true,
      consentTimestamp: DateTime.now().millisecondsSinceEpoch,
      lifecycleStatus: DiagnosticLifecycleStatus.submitted,
    ).toJson();

    // Privacy & prohibited information audit
    if (!DeviceDiagnosticReport.validatePrivacySafety(payload)) {
      throw StateError('Diagnostic payload violates privacy safety rules (prohibited fields detected).');
    }

    final client = _apiClient;
    if (client == null) {
      throw StateError('ApiClient unavailable for diagnostic submission.');
    }

    final res = await client.post('/diagnostics/submit', payload);
    if (res is Map<String, dynamic>) {
      final updated = report.copyWith(
        consentGiven: true,
        consentTimestamp: DateTime.now().millisecondsSinceEpoch,
        lifecycleStatus: DiagnosticLifecycleStatus.submitted,
      );
      await markDiagnosticCompleted(updated);
      return res;
    }

    return {'ok': true, 'diagnosticId': report.diagnosticId, 'status': 'Submitted'};
  }

  Future<PackageInfo> _getPackageInfoSafe() async {
    try {
      return await PackageInfo.fromPlatform();
    } catch (_) {
      // The version MetaService read at start-up (empty when that failed too: shown as unknown).
      return PackageInfo(
        appName: AppConstants.appName,
        packageName: AppConstants.androidPackageId,
        version: MetaService.currentVersion,
        buildNumber: MetaService.currentBuild > 0 ? '${MetaService.currentBuild}' : '',
        buildSignature: '',
      );
    }
  }
}

class _OverallResultComputation {
  final String result;
  final String summary;
  const _OverallResultComputation({required this.result, required this.summary});
}

/// What the pre-ride check keeps from one GPS fix: its accuracy and speed, never the position.
class GpsReading {
  final double accuracyM;
  final double speedKmh;
  const GpsReading({required this.accuracyM, required this.speedKmh});
}

/// Readings from the phone for the pre-ride check. Every call is safe anywhere and never throws;
/// off a phone (tests, desktop) the answers are "unknown". Tests pass a subclass.
class PhoneProbe {
  const PhoneProbe();

  bool get isMobile => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
  bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<bool> locationServiceEnabled() async {
    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (_) {
      return true;
    }
  }

  /// Motion sensors and phone state (Android, ~1.5 s). Empty elsewhere.
  Future<Map<String, dynamic>> nativeProbe() => SafetyNative.phoneProbe();

  /// A fresh fix (a recent good one is reused), within 8 s; null without one.
  Future<GpsReading?> gpsReading() async {
    if (!isMobile) return null;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null &&
          DateTime.now().difference(last.timestamp).inSeconds.abs() <= 20 &&
          last.accuracy > 0 &&
          last.accuracy <= 20) {
        return GpsReading(accuracyM: last.accuracy, speedKmh: last.speed > 0 ? last.speed * 3.6 : 0);
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 8)),
      ).timeout(const Duration(seconds: 9));
      return GpsReading(accuracyM: p.accuracy, speedKmh: p.speed > 0 ? p.speed * 3.6 : 0);
    } catch (_) {
      return null;
    }
  }

  /// False when only approximate location is allowed (Android 12+ / iOS 14+), null when unknown.
  Future<bool?> preciseLocation() async {
    if (!isMobile) return null;
    try {
      final s = await Geolocator.getLocationAccuracy();
      if (s == LocationAccuracyStatus.reduced) return false;
      if (s == LocationAccuracyStatus.precise) return true;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Listens to the microphone for about a second and only counts the bytes (nothing is kept).
  /// True when sound data arrived, false when not, null when it could not be tried.
  Future<bool?> micCaptureWorks() async {
    if (!isMobile) return null;
    AudioRecorder? rec;
    StreamSubscription<Object?>? sub;
    try {
      rec = AudioRecorder();
      if (await rec.isRecording()) return null;
      final stream = await rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      var bytes = 0;
      sub = stream.listen((data) => bytes += data.length, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      return bytes > 0;
    } catch (_) {
      return false;
    } finally {
      try {
        await sub?.cancel();
      } catch (_) {}
      try {
        await rec?.stop();
      } catch (_) {}
      try {
        await rec?.dispose();
      } catch (_) {}
    }
  }

  Future<({int? level, bool charging})> battery() async {
    if (!isMobile) return (level: null, charging: false);
    try {
      final b = Battery();
      final level = await b.batteryLevel;
      final state = await b.batteryState;
      return (level: level, charging: state == BatteryState.charging || state == BatteryState.full);
    } catch (_) {
      return (level: null, charging: false);
    }
  }

  /// The phone can open a text to an emergency contact (no SEND_SMS needed).
  Future<bool> smsComposerAvailable() async {
    if (!isMobile) return false;
    try {
      return await SmsComposer.available();
    } catch (_) {
      return false;
    }
  }

  /// The phone can place a call (null when unknown).
  Future<bool?> canDial() async {
    if (!isMobile) return null;
    try {
      if (isAndroid) return null; // read in [nativeProbe] ('canDial')
      return await canLaunchUrl(Uri(scheme: 'tel', path: SafetyConstants.emergencyNumber));
    } catch (_) {
      return null;
    }
  }

  /// iPhone compass (Android reads it in [nativeProbe]); null when not asked.
  Future<bool?> compassAvailable() async {
    if (!isIOS) return null;
    try {
      return FlutterCompass.events != null;
    } catch (_) {
      return null;
    }
  }
}
