import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/constants/ride_notification_constants.dart';

/// Keeps CoRoute alive while a convoy is active and the phone is in a pocket or
/// mounted with the screen locked.
///
/// Android stops background GPS, microphone and network for apps that are not
/// visible unless they run a *foreground service*. This class runs one service
/// (type location, plus microphone only when the rider allowed the microphone:
/// Android 14+ refuses a microphone-type service without that permission, which
/// would leave the rider with no background location at all) with a persistent notification
/// that shows the convoy name and offers two actions riders can use without
/// unlocking the phone: SOS and Leave ride. Neither acts by itself (3.16): SOS
/// opens the hold-to-send screen and Leave ride opens a confirm in the app
/// (ConvoyService only flags `leaveRequestedFromNotification`). The Dart code of
/// the app keeps running in the main isolate; the service's own isolate only
/// forwards button taps.
///
/// 3.15: during a ride RideNotificationService replaces this plain notification
/// in place with the big ride notification (same id [NotifConstants.serviceNotificationId],
/// same channel [NotifConstants.channelId]). While it is shown ([richActive]) nothing here
/// re-posts the plain one; when it is given up, the last plain text is posted again.
class BackgroundService {
  BackgroundService._();

  static const int _serviceId = NotifConstants.serviceNotificationId;
  static const String buttonSos = 'sos';
  static const String buttonLeave = 'leave';
  static bool _initialised = false;
  static bool _runningWithMic = false;
  static String _convoyName = '';
  static int _riderCount = 0;

  static bool _richActive = false;
  static String? _plainTitle;
  static String? _plainText;

  /// The big ride notification currently replaces the plain one. While true,
  /// [updateStatus] and a repeated [start] do not touch the notification.
  static bool get richActive => _richActive;

  /// Called after every successful [start] of the service (first start and the
  /// microphone restart), so the big ride notification can be posted again at once.
  static VoidCallback? onServiceStarted;

  /// Set by RideNotificationService only. Switching off posts the last plain
  /// status again (the big notification would otherwise stay until the next change).
  static Future<void> setRichActive(bool value) async {
    if (_richActive == value) return;
    _richActive = value;
    if (value) return;
    final title = _plainTitle, text = _plainText;
    if (title == null || text == null) return;
    await updateStatus(title: title, text: text);
  }

  @visibleForTesting
  static void debugReset() {
    _richActive = false;
    _plainTitle = null;
    _plainText = null;
    onServiceStarted = null;
  }

  /// The last plain title and text asked for (shown again when the big notification is given up).
  @visibleForTesting
  static ({String? title, String? text}) get lastPlain => (title: _plainTitle, text: _plainText);

  /// Whether the foreground service runs (false off Android/iOS or on any error).
  static Future<bool> isRunning() async {
    if (!_isAndroidOrIos) return false;
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  static void _notifyStarted() {
    final cb = onServiceStarted;
    if (cb == null) return;
    try {
      cb();
    } catch (e) {
      debugPrint('ride notification restart note: $e');
    }
  }

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
    _plainTitle = 'Convoy: $convoyName';
    _plainText = text;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        // The big ride notification is showing: re-posting the plain one would replace it.
        if (_richActive) return true;
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
          NotificationButton(id: buttonLeave, text: 'Leave ride'),
        ],
        callback: coRouteForegroundCallback,
      );
      if (r is ServiceRequestFailure) debugPrint('Foreground service start failed: ${r.error}');
      if (r is ServiceRequestSuccess) {
        _runningWithMic = mic;
        // The plugin posted its plain notification: the big one goes back up at once.
        _notifyStarted();
      }
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
    _plainTitle = title;
    _plainText = text;
    // The big ride notification replaces this one; updating would put the plain one back.
    if (_richActive) return;
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
      // The service removes its notification (ours too: same id).
      _richActive = false;
    } catch (e) {
      debugPrint('Foreground service stop note: $e');
    }
  }

  /// Sends the app to the background without closing it (Android back during a ride), so the
  /// ride keeps running in the main isolate exactly as when the rider presses Home.
  static void minimizeApp() {
    if (!_isAndroidOrIos) return;
    try {
      FlutterForegroundTask.minimizeApp();
    } catch (e) {
      debugPrint('Minimize note: $e');
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
    // Both buttons open the app: SOS to the hold screen, Leave ride to its confirm (3.16).
    if (id == BackgroundService.buttonSos || id == BackgroundService.buttonLeave) FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {}
}
