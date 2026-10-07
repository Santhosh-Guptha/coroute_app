import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

/// Keeps CoRoute alive while a convoy is active and the phone is in a pocket or
/// mounted with the screen locked.
///
/// Android stops background GPS, microphone and network for apps that are not
/// visible unless they run a *foreground service*. This class runs one service
/// (type location, plus microphone only when the rider allowed the microphone:
/// Android 14+ refuses a microphone-type service without that permission, which
/// would leave the rider with no background location at all) with a persistent notification
/// that shows the convoy name and offers two actions riders can use without
/// unlocking the phone: SOS and Leave. The Dart code of the app keeps running
/// in the main isolate; the service's own isolate only forwards button taps.
class BackgroundService {
  BackgroundService._();

  static const int _serviceId = 1001;
  static const String buttonSos = 'sos';
  static const String buttonLeave = 'leave';
  static bool _initialised = false;
  static bool _runningWithMic = false;
  static String _convoyName = '';
  static int _riderCount = 0;

  /// Service types for this phone. Location always; microphone only when granted.
  /// (dataSync is not used: location already keeps the connection alive, and Android 15
  /// limits dataSync services to 6 hours a day.)
  @visibleForTesting
  static List<ForegroundServiceTypes> serviceTypesFor({required bool micGranted}) => [
        ForegroundServiceTypes.location,
        if (micGranted) ForegroundServiceTypes.microphone,
      ];

  static Future<bool> _micGranted() async {
    try {
      return await Permission.microphone.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Must be called once in main() before runApp (sets up the isolate port).
  static void initCommunicationPort() {
    if (!_isAndroidOrIos) return;
    FlutterForegroundTask.initCommunicationPort();
  }

  static bool get _isAndroidOrIos => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static void _ensureInit() {
    if (_initialised || !_isAndroidOrIos) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'coroute_convoy',
        channelName: 'Active convoy',
        channelDescription: 'Shown while CoRoute shares your position and keeps the intercom open for your convoy.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
        showWhen: false,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        // A light tick keeps the service classed as active; the app's own timers do the real work.
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialised = true;
  }

  /// Starts (or updates) the persistent service for the given convoy.
  static Future<bool> start({required String convoyName, required int riderCount}) async {
    if (!_isAndroidOrIos) return false;
    _ensureInit();
    _convoyName = convoyName;
    _riderCount = riderCount;
    final text = '$riderCount rider${riderCount == 1 ? '' : 's'} connected. Position sharing and intercom are on.';
    try {
      if (await FlutterForegroundTask.isRunningService) {
        final r = await FlutterForegroundTask.updateService(notificationTitle: 'Convoy: $convoyName', notificationText: text);
        return r is ServiceRequestSuccess;
      }
      final mic = Platform.isAndroid && await _micGranted();
      final r = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: Platform.isAndroid ? serviceTypesFor(micGranted: mic) : null,
        notificationTitle: 'Convoy: $convoyName',
        notificationText: text,
        notificationButtons: const [
          NotificationButton(id: buttonSos, text: 'SOS'),
          NotificationButton(id: buttonLeave, text: 'Leave convoy'),
        ],
        callback: coRouteForegroundCallback,
      );
      if (r is ServiceRequestFailure) debugPrint('Foreground service start failed: ${r.error}');
      if (r is ServiceRequestSuccess) _runningWithMic = mic;
      return r is ServiceRequestSuccess;
    } catch (e) {
      debugPrint('Foreground service note: $e');
      return false;
    }
  }

  /// The rider allowed the microphone during a ride: restart the service once with the
  /// microphone type, so the intercom also works with the screen off. Does nothing when
  /// the running service already has it, or when no service runs.
  static Future<void> ensureMicrophoneType() async {
    if (kIsWeb || !Platform.isAndroid || _runningWithMic) return;
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      if (!await _micGranted()) return;
      await FlutterForegroundTask.stopService();
      await start(convoyName: _convoyName, riderCount: _riderCount);
    } catch (e) {
      debugPrint('Foreground service mic note: $e');
    }
  }

  /// Replaces the notification's title and text in place (no sound, no new
  /// notification). The first line of [text] is what the collapsed
  /// notification shows; the expanded one shows every line.
  static Future<void> updateStatus({required String title, required String text}) async {
    if (!_isAndroidOrIos) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
      }
    } catch (e) {
      debugPrint('Foreground service update note: $e');
    }
  }

  static Future<void> stop() async {
    if (!_isAndroidOrIos) return;
    try {
      if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
      _runningWithMic = false;
    } catch (e) {
      debugPrint('Foreground service stop note: $e');
    }
  }

  /// Listen for notification button taps forwarded from the service isolate.
  static void addButtonListener(void Function(String buttonId) onButton) {
    if (!_isAndroidOrIos) return;
    FlutterForegroundTask.addTaskDataCallback((Object data) {
      if (data is String && (data == buttonSos || data == buttonLeave)) onButton(data);
    });
  }

  /// Battery optimisation exemption: without it some phones kill background apps after a few minutes.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {
      return true;
    }
  }

  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      return await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {
      return false;
    }
  }
}

/// Entry point for the service isolate. Keep it tiny: it only relays button taps.
@pragma('vm:entry-point')
void coRouteForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_CoRouteTaskHandler());
}

class _CoRouteTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {
    FlutterForegroundTask.sendDataToMain(id);
    if (id == BackgroundService.buttonSos) FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {}
}
