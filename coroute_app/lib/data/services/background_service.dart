import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/tracking/fix_gate.dart';
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

  /// 3.55: a microphone consumer may need capture during this ride (siren alerts on, or
  /// the intercom allowed). Set in main.dart; null = no. With it true and RECORD_AUDIO already
  /// granted, [start] starts the service as location|microphone at once (Android 14 needs the
  /// type at start; adding it later means a stop and restart, see [ensureMicrophoneType]).
  static bool Function()? micMayBeNeeded;

  /// 3.55: the running service has the microphone type (capture keeps working with the screen
  /// off on Android). False when no service runs or it runs as location only.
  static bool get runningWithMic => _runningWithMic;

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

  /// Service types for this phone. Location always; microphone only when explicitly active.
  /// (dataSync is not used: location already keeps the connection alive, and Android 15
  /// limits dataSync services to 6 hours a day.)
  @visibleForTesting
  static List<ForegroundServiceTypes> serviceTypesFor({bool micActive = false, bool? micGranted}) {
    final active = micGranted ?? micActive;
    return [
      ForegroundServiceTypes.location,
      if (active) ForegroundServiceTypes.microphone,
    ];
  }

  static Future<bool> _micGranted() async {
    try {
      return await Permission.microphone.isGranted;
    } catch (_) {
      return false;
    }
  }

  static bool _safeCall(bool Function()? f) {
    try {
      return f?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The app is visible (resumed / inactive). Before the first frame the state is null: main()
  /// runs with the app in front, so that counts as in front.
  static bool _appInFront() {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == null || s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;
    } catch (_) {
      return false;
    }
  }

  /// Must be called once in main() before runApp (sets up the isolate port).
  static void initCommunicationPort() {
    if (!_isAndroidOrIos) return;
    FlutterForegroundTask.initCommunicationPort();
  }

  /// v3.58: the helmet small icon (one colour) instead of the launcher icon. The manifest meta-data
  /// below points at @drawable/ic_stat_coroute.
  static const NotificationIcon rideNotificationIcon =
      NotificationIcon(metaDataName: 'space.devmonks.coroute_app.NOTIFICATION_ICON');

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
        // A periodic tick keeps the service classed as active and prevents OS throttling.
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialised = true;
  }

  /// Starts (or updates) the persistent service for the given convoy.
  static Future<bool> start({required String convoyName, required int riderCount, bool micActive = false}) async {
    if (!_isAndroidOrIos) return false;
    _ensureInit();
    _convoyName = convoyName;
    _riderCount = riderCount;
    final text = '$riderCount rider${riderCount == 1 ? '' : 's'} connected. Position sharing is active.';
    _plainTitle = 'Convoy: $convoyName';
    _plainText = text;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        // The big ride notification is showing: re-posting the plain one would replace it.
        if (_richActive) return true;
        final r = await FlutterForegroundTask.updateService(
          notificationTitle: 'Convoy: $convoyName',
          notificationText: text,
          notificationIcon: rideNotificationIcon,
        );
        return r is ServiceRequestSuccess;
      }
      // 3.55: microphone type from the first start when a mic consumer may be needed and the
      // permission is ALREADY granted (only checked, never requested here), and only with the app
      // in front: Android 14 refuses a microphone-type start from the background (the ride service
      // would then not start at all). A background start stays location only; RideMicHub adds the
      // type on the next resume (ensureMicrophoneType).
      final withMic = Platform.isAndroid &&
          (micActive || _safeCall(micMayBeNeeded)) &&
          _appInFront() &&
          await _micGranted();
      final r = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: Platform.isAndroid ? serviceTypesFor(micActive: withMic) : null,
        notificationTitle: 'Convoy: $convoyName',
        notificationText: text,
        notificationIcon: rideNotificationIcon,
        notificationButtons: const [
          NotificationButton(id: buttonSos, text: 'SOS'),
          NotificationButton(id: buttonLeave, text: 'Leave ride'),
        ],
        callback: coRouteForegroundCallback,
      );
      if (r is ServiceRequestFailure) debugPrint('Foreground service start failed: ${r.error}');
      if (r is ServiceRequestSuccess) {
        _runningWithMic = withMic;
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
    if (!_appInFront()) return; // 3.55: never restart into a mic type from the background
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      if (!await _micGranted()) return;
      await FlutterForegroundTask.stopService();
      await start(convoyName: _convoyName, riderCount: _riderCount, micActive: true);
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
        await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text, notificationIcon: rideNotificationIcon);
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

  static Future<bool> requestIgnoreBatteryOptimization() => requestIgnoreBatteryOptimizations();

  static const String _keyBatteryAskedAt = 'battery_exempt_asked_at_v1';

  /// 3.56 audit B-01: the system "Let the app run in the background?" question was opened at every
  /// ride start (and every time GPS came back) for riders who had answered "Deny". Now: only when
  /// the phone still restricts CoRoute and the question was not shown in the last 7 days
  /// ([BatteryExemptionAsk]). The pre-ride phone check keeps its own button for asking at any time.
  static Future<void> requestIgnoreBatteryOptimizationIfDue({int? nowMs}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final exempt = await isIgnoringBatteryOptimizations();
      final prefs = await SharedPreferences.getInstance();
      final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      if (!BatteryExemptionAsk.shouldAsk(nowMs: now, lastAskedMs: prefs.getInt(_keyBatteryAskedAt) ?? 0, alreadyExempt: exempt)) return;
      await prefs.setInt(_keyBatteryAskedAt, now);
      await requestIgnoreBatteryOptimizations();
    } catch (_) {
      // Never in the way of starting a ride.
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
