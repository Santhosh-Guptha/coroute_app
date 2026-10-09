import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/ui/ride_alert.dart';
import 'safety_service.dart';

/// Called by flutter_local_notifications on a background isolate when a
/// notification button that does not open the app is pressed (for example
/// "I'm OK" on the lock screen). It hands the press to the app's main isolate,
/// where the countdown runs. If the app is not running there is nothing to do.
@pragma('vm:entry-point')
void alarmNotificationBackground(NotificationResponse response) {
  final port = IsolateNameServer.lookupPortByName(AlarmNotifier.portName);
  port?.send(<String?>[response.actionId, response.payload]);
}

/// The one place that initialises flutter_local_notifications (the plugin keeps
/// only the callbacks of the last initialize call), plus the safety
/// notifications: the crash alarm, the rider prompts and the admin alarm.
///
/// Payload prefixes: 'CRASH' (crash alarm), 'PROMPT' (`PROMPT:<key>`), 'ADMIN'.
/// Button ids: 'crash_ok', 'crash_send', 'prompt_ok', 'prompt_secondary' (3.16:
/// "Filled up", "Need help").
class AlarmNotifier {
  AlarmNotifier._();

  static const String portName = 'coroute_alarm_actions';
  static const String payloadCrash = 'CRASH';
  static const String payloadPrompt = 'PROMPT';
  static const String payloadAdmin = 'ADMIN';
  static const String actionCrashOk = 'crash_ok';
  static const String actionCrashSend = 'crash_send';
  static const String actionPromptOk = 'prompt_ok';
  static const String actionPromptSecondary = 'prompt_secondary';

  static FlutterLocalNotificationsPlugin? _plugin;
  static Future<bool>? _init;
  static ReceivePort? _port;
  static final Map<String, void Function(String? actionId, String? payload)> _handlers = {};

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  // Repeating pattern: the phone keeps buzzing while the alarm is up.
  static final Int64List _alarmVibration = Int64List.fromList(const [0, 900, 500, 900, 500, 900]);
  static final Int32List _insistent = Int32List.fromList(const [4]); // FLAG_INSISTENT: sound repeats until cancelled

  /// Initialises the plugin once with the tap/button dispatcher and creates the
  /// safety channels. Safe to call many times and from several services.
  static Future<bool> ensureInitialized([FlutterLocalNotificationsPlugin? plugin]) {
    if (!_supported) return Future<bool>.value(false);
    _plugin ??= plugin ?? FlutterLocalNotificationsPlugin();
    return _init ??= _doInit();
  }

  static Future<bool> _doInit() async {
    final plugin = _plugin!;
    try {
      _listenForBackgroundPresses();
      final ok = await plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: _onResponse,
        onDidReceiveBackgroundNotificationResponse: alarmNotificationBackground,
      );
      final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(AndroidNotificationChannel(
        SafetyConstants.channelCrash,
        'Crash alarm',
        description: 'Rings when the phone senses a possible crash during a ride.',
        importance: Importance.max,
        enableVibration: true,
        vibrationPattern: _alarmVibration,
        audioAttributesUsage: AudioAttributesUsage.alarm,
      ));
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        SafetyConstants.channelSafety,
        'Ride safety',
        description: 'Are you OK? checks and break reminders, for you only.',
        importance: Importance.high,
      ));
      await android?.createNotificationChannel(AndroidNotificationChannel(
        SafetyConstants.channelAdminAlarm,
        'Emergency alarm (admin)',
        description: 'Rings on the admin console while an SOS or crash is open.',
        importance: Importance.max,
        enableVibration: true,
        vibrationPattern: _alarmVibration,
        audioAttributesUsage: AudioAttributesUsage.alarm,
      ));
      return ok ?? false;
    } catch (e) {
      debugPrint('alarm notifier init note: $e');
      _init = null; // try again next time
      return false;
    }
  }

  static void _listenForBackgroundPresses() {
    if (_port != null) return;
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(portName);
    IsolateNameServer.registerPortWithName(port.sendPort, portName);
    port.listen((message) {
      if (message is List && message.length == 2) {
        final a = message[0], p = message[1];
        _dispatch(a is String ? a : null, p is String ? p : null);
      }
    });
    _port = port;
  }

  static void _onResponse(NotificationResponse r) => _dispatch(r.actionId, r.payload);

  static void _dispatch(String? actionId, String? payload) {
    if (payload == null) return;
    for (final entry in _handlers.entries.toList()) {
      if (payload == entry.key || payload.startsWith('${entry.key}:')) entry.value(actionId, payload);
    }
  }

  /// Registers the handler for notifications whose payload is [prefix] or starts with "[prefix]:".
  /// A later registration for the same prefix replaces the earlier one.
  static void onAction(String prefix, void Function(String? actionId, String? payload) handler) {
    _handlers[prefix] = handler;
  }

  /// Removes the handler for [prefix] (when a service is disposed).
  static void removeAction(String prefix) => _handlers.remove(prefix);

  /// Test hook: delivers a press as if it came from the notification.
  @visibleForTesting
  static void debugDispatch(String? actionId, String? payload) => _dispatch(actionId, payload);

  /// The crash alarm: full-screen over the lock screen (when Android allows it),
  /// alarm volume, repeating sound and vibration, buttons "I'm OK" and "Need Help"
  /// that work without unlocking (labels in the safety language).
  static Future<void> showCrashAlarm({required String title, required String body}) async {
    if (!await ensureInitialized()) return;
    final details = AndroidNotificationDetails(
      SafetyConstants.channelCrash,
      'Crash alarm',
      channelDescription: 'Rings when the phone senses a possible crash during a ride.',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
      vibrationPattern: _alarmVibration,
      additionalFlags: _insistent,
      visibility: NotificationVisibility.public, // no position or names of others in the text
      ongoing: true,
      autoCancel: false,
      showWhen: true,
      styleInformation: BigTextStyleInformation(body),
      actions: [
        AndroidNotificationAction(actionCrashOk, L10n.t('notif.crash.ok'), showsUserInterface: false, cancelNotification: true),
        AndroidNotificationAction(actionCrashSend, L10n.t('notif.crash.help'), showsUserInterface: false, cancelNotification: true),
      ],
    );
    try {
      await _plugin?.show(SafetyConstants.crashAlarmId, title, body, NotificationDetails(android: details), payload: payloadCrash);
    } catch (e) {
      debugPrint('crash alarm note: $e');
    }
  }

  static Future<void> cancelCrashAlarm() => _cancel(SafetyConstants.crashAlarmId);

  /// A rider prompt ("Are you OK?", "Time for a break", "Fuel soon", "Still okay?")
  /// with its main button and, when the prompt has one, its second button.
  static Future<void> showPrompt(SafetyPrompt p) async {
    if (!await ensureInitialized()) return;
    final urgent = p.tier == AlertTier.important;
    final secondary = p.secondaryLabel;
    final details = AndroidNotificationDetails(
      SafetyConstants.channelSafety,
      'Ride safety',
      channelDescription: 'Are you OK? checks and break reminders, for you only.',
      importance: Importance.high,
      priority: urgent ? Priority.high : Priority.defaultPriority,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.public,
      onlyAlertOnce: true,
      autoCancel: true,
      styleInformation: BigTextStyleInformation(p.message),
      actions: [
        AndroidNotificationAction(actionPromptOk, p.primaryLabel, showsUserInterface: false, cancelNotification: true),
        if (secondary != null && secondary.isNotEmpty)
          AndroidNotificationAction(actionPromptSecondary, secondary, showsUserInterface: false, cancelNotification: true),
      ],
    );
    try {
      await _plugin?.show(_promptId(p.key), p.title, p.message, NotificationDetails(android: details), payload: '$payloadPrompt:${p.key}');
    } catch (e) {
      debugPrint('prompt note: $e');
    }
  }

  static Future<void> cancelPrompt(String key) => _cancel(_promptId(key));

  static int _promptId(String key) => switch (key) {
        SafetyConstants.promptCheckIn => SafetyConstants.checkInId,
        SafetyConstants.promptFuel => SafetyConstants.fuelId,
        SafetyConstants.promptFollowUp => SafetyConstants.followUpId,
        _ => SafetyConstants.fatigueId,
      };

  /// Admin console: rings (alarm volume, repeating) while an emergency is open and not silenced.
  static Future<void> startAdminAlarm({required String title, required String body}) async {
    if (!await ensureInitialized()) return;
    final details = AndroidNotificationDetails(
      SafetyConstants.channelAdminAlarm,
      'Emergency alarm (admin)',
      channelDescription: 'Rings on the admin console while an SOS or crash is open.',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
      vibrationPattern: _alarmVibration,
      additionalFlags: _insistent,
      visibility: NotificationVisibility.private,
      ongoing: true,
      autoCancel: false,
      styleInformation: BigTextStyleInformation(body),
    );
    try {
      await _plugin?.show(SafetyConstants.adminAlarmId, title, body, NotificationDetails(android: details), payload: payloadAdmin);
    } catch (e) {
      debugPrint('admin alarm note: $e');
    }
  }

  static Future<void> stopAdminAlarm() => _cancel(SafetyConstants.adminAlarmId);

  static Future<void> _cancel(int id) async {
    if (!_supported || _init == null) return;
    try {
      await _plugin?.cancel(id);
    } catch (_) {}
  }
}
