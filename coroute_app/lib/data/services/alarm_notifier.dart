import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/ui/ride_alert.dart';
import 'audio_priority_manager.dart';
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
/// Payload prefixes: 'CRASH' (crash alarm), 'PROMPT' (`PROMPT:<key>`), 'ADMIN',
/// 'PLAN' (`PLAN:<tier>`, plan expiry reminders).
/// Button ids: 'crash_ok', 'crash_send', 'prompt_ok', 'prompt_secondary' (3.16:
/// "Filled up", "Need help").
class AlarmNotifier {
  AlarmNotifier._();

  static const String portName = 'coroute_alarm_actions';
  static const String payloadCrash = 'CRASH';
  static const String payloadPrompt = 'PROMPT';
  static const String payloadAdmin = 'ADMIN';
  static const String payloadPlan = 'PLAN';
  static const String channelPlan = 'coroute_plan_reminders';
  /// 3.55 friends: "X wants to be friends" / "X accepted your friend request" while the app is
  /// in the background (foreground: a snackbar). Normal importance, never a ride alert.
  static const String channelSocial = 'coroute_social';
  static const String payloadSocial = 'SOCIAL';
  static const int socialNoticeId = 4713;

  /// 3.55: critical ride alerts the rider may not hear (during a phone call, or when speech failed):
  /// alarm sound (plays through Do Not Disturb when alarms are allowed, or when the rider gave
  /// CoRoute Do Not Disturb access), heads-up, public on the lock screen (names only, no position).
  static const String channelCritical = 'coroute_critical_alerts';
  static const int criticalAlertId = 4711;

  /// 3.55 sound awareness: a siren heard by the ride mic while the app is not in front (screen
  /// locked, phone in a pocket), where app vibration (HapticFeedback) may not work. Heads-up with
  /// VIBRATION ONLY: the spoken alert is the sound (no notification sound on top of it).
  static const String channelSoundAlerts = 'coroute_sound_alerts';
  static const int soundAlertId = 4712;
  static final Int64List _sirenVibration = Int64List.fromList(const [0, 400, 200, 400, 200, 400]);
  static const String actionCrashOk = 'crash_ok';
  static const String actionCrashSend = 'crash_send';
  static const String actionPromptOk = 'prompt_ok';
  static const String actionPromptSecondary = 'prompt_secondary';

  static FlutterLocalNotificationsPlugin? _plugin;
  static Future<bool>? _init;
  static ReceivePort? _port;
  static final Map<String, void Function(String? actionId, String? payload)> _handlers = {};

  static bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  // Repeating pattern: the phone keeps buzzing while the alarm is up.
  static final Int64List _alarmVibration = Int64List.fromList(const [0, 900, 500, 900, 500, 900]);
  static final Int32List _insistent = Int32List.fromList(const [4]); // FLAG_INSISTENT: sound repeats until cancelled

  @visibleForTesting
  static void resetForTesting() {
    _init = null;
    _plugin = null;
  }

  /// Initialises the plugin once with the tap/button dispatcher and creates the
  /// safety channels. Safe to call many times and from several services.
  static Future<bool> ensureInitialized([FlutterLocalNotificationsPlugin? plugin]) {
    if (!_supported) return Future<bool>.value(false);
    _plugin = plugin ?? _plugin ?? FlutterLocalNotificationsPlugin();
    return _init ??= _doInit();
  }

  static Future<bool> _doInit() async {
    final plugin = _plugin!;
    try {
      tz_data.initializeTimeZones();
      _listenForBackgroundPresses();
      final ok = await plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: _onResponse,
        onDidReceiveBackgroundNotificationResponse: alarmNotificationBackground,
      );
      if (defaultTargetPlatform == TargetPlatform.android) {
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
        await android?.createNotificationChannel(AndroidNotificationChannel(
          channelCritical,
          'Critical ride alerts',
          description: 'Crash, SOS or emergency vehicle alerts you might not hear (during a call, or when speech is unavailable).',
          importance: Importance.max,
          bypassDnd: true,
          enableVibration: true,
          vibrationPattern: _alarmVibration,
          audioAttributesUsage: AudioAttributesUsage.alarm,
        ));
        await android?.createNotificationChannel(AndroidNotificationChannel(
          channelSoundAlerts,
          'Siren alerts',
          description: 'Vibrates when your phone hears an emergency siren close by while the screen is off.',
          importance: Importance.high,
          playSound: false,
          enableVibration: true,
          vibrationPattern: _sirenVibration,
        ));
        await android?.createNotificationChannel(const AndroidNotificationChannel(
          channelSocial,
          'Friends',
          description: 'Friend requests and accepted requests.',
          importance: Importance.defaultImportance,
        ));
        await android?.createNotificationChannel(const AndroidNotificationChannel(
          channelPlan,
          'Plan reminders',
          description: 'Tells you a few days before your CoRoute plan ends.',
          importance: Importance.defaultImportance,
        ));
      }
      // Critical lines the rider may not hear get a heads-up notification (AudioPriorityManager).
      AudioPriorityManager.criticalNotifier ??= showCriticalAlert;
      return ok ?? true;
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
      await _plugin?.show(
        SafetyConstants.crashAlarmId,
        title,
        body,
        NotificationDetails(
          android: details,
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBanner: true,
            // Time sensitive (iOS 15+, Time Sensitive capability): critical alerts need an Apple
            // entitlement CoRoute does not have. See docs/BATTERY.md (iOS gaps).
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
        payload: payloadCrash,
      );
    } catch (e) {
      debugPrint('crash alarm note: $e');
    }
  }

  static Future<void> cancelCrashAlarm() => _cancel(SafetyConstants.crashAlarmId);

  /// 3.55: heads-up for a critical line the rider may not hear (during a phone call: a short tone and
  /// phrase also play in the call audio; or when speech failed). Alarm sound and vibration, public on
  /// the lock screen (texts carry names only), auto-cancels after 2 minutes. No full-screen intent:
  /// it must never cover the call screen.
  static Future<void> showCriticalAlert(String title, String body) async {
    if (!await ensureInitialized()) return;
    final details = AndroidNotificationDetails(
      channelCritical,
      'Critical ride alerts',
      channelDescription: 'Crash, SOS or emergency vehicle alerts you might not hear (during a call, or when speech is unavailable).',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
      vibrationPattern: _alarmVibration,
      visibility: NotificationVisibility.public,
      autoCancel: true,
      timeoutAfter: const Duration(minutes: 2).inMilliseconds,
      styleInformation: BigTextStyleInformation(body),
    );
    try {
      await _plugin?.show(
        criticalAlertId,
        title,
        body,
        NotificationDetails(
          android: details,
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBanner: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
      );
    } catch (e) {
      debugPrint('critical alert note: $e');
    }
  }

  /// 3.55: siren heads-up with vibration only, for the lock screen (see [channelSoundAlerts]).
  /// One id: a newer alert replaces the older one. Public on the lock screen (no private data).
  static Future<void> showSoundAwarenessAlert(String title, String body, {Duration showFor = const Duration(seconds: 30)}) async {
    if (!await ensureInitialized()) return;
    final details = AndroidNotificationDetails(
      channelSoundAlerts,
      'Siren alerts',
      channelDescription: 'Vibrates when your phone hears an emergency siren close by while the screen is off.',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.navigation,
      playSound: false,
      enableVibration: true,
      vibrationPattern: _sirenVibration,
      visibility: NotificationVisibility.public,
      autoCancel: true,
      timeoutAfter: showFor.inMilliseconds,
    );
    try {
      await _plugin?.show(
        soundAlertId,
        title,
        body,
        NotificationDetails(
          android: details,
          iOS: const DarwinNotificationDetails(presentAlert: true, presentSound: false, presentBanner: true),
        ),
      );
    } catch (e) {
      debugPrint('sound alert note: $e');
    }
  }

  /// A rider prompt ("Are you OK?", "Time for a break", "Fuel soon", "Still okay?")
  /// with its main button and, when the prompt has one, its second button.
  static Future<void> showPrompt(SafetyPrompt p) async {
    if (!await ensureInitialized()) return;
    final isCritical = p.tier == AlertTier.critical;
    final urgent = p.tier == AlertTier.important || isCritical;
    final secondary = p.secondaryLabel;
    final details = AndroidNotificationDetails(
      SafetyConstants.channelSafety,
      'Ride safety',
      channelDescription: 'Are you OK? checks and break reminders, for you only.',
      importance: isCritical ? Importance.max : Importance.high,
      priority: isCritical ? Priority.max : (urgent ? Priority.high : Priority.defaultPriority),
      category: isCritical ? AndroidNotificationCategory.alarm : AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.public,
      onlyAlertOnce: !isCritical,
      autoCancel: true,
      enableVibration: true,
      vibrationPattern: isCritical ? _alarmVibration : null,
      styleInformation: BigTextStyleInformation(p.message),
      actions: [
        AndroidNotificationAction(actionPromptOk, p.primaryLabel, showsUserInterface: false, cancelNotification: true),
        if (secondary != null && secondary.isNotEmpty)
          AndroidNotificationAction(actionPromptSecondary, secondary, showsUserInterface: false, cancelNotification: true),
      ],
    );
    try {
      await _plugin?.show(
        _promptId(p.key),
        p.title,
        p.message,
        NotificationDetails(
          android: details,
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBanner: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
        ),
        payload: '$payloadPrompt:${p.key}',
      );
    } catch (e) {
      debugPrint('prompt note: $e');
    }
  }

  static Future<void> cancelPrompt(String key) => _cancel(_promptId(key));

  static int _promptId(String key) => switch (key) {
        SafetyConstants.promptCheckIn => SafetyConstants.checkInId,
        SafetyConstants.promptFuel => SafetyConstants.fuelId,
        SafetyConstants.promptFollowUp => SafetyConstants.followUpId,
        SafetyConstants.promptOverspeed => SafetyConstants.overspeedId,
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

  /// 3.55 friends: one system notification (replaced by the next) for a friend request or an
  /// accepted request while the app is in the background. Tapping it opens the app.
  static Future<void> showSocialNotice(String title, String body) async {
    try {
      if (!await ensureInitialized()) return;
      final details = AndroidNotificationDetails(
        channelSocial,
        'Friends',
        channelDescription: 'Friend requests and accepted requests.',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        category: AndroidNotificationCategory.social,
        autoCancel: true,
        styleInformation: BigTextStyleInformation(body),
      );
      await _plugin?.show(
        socialNoticeId,
        title,
        body,
        NotificationDetails(
          android: details,
          iOS: const DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
        ),
        payload: payloadSocial,
      );
    } catch (e) {
      debugPrint('social notice note: $e');
    }
  }

  /// A plan reminder at the absolute instant [at]. Inexact (no exact-alarm
  /// permission); a few minutes late is fine for a renewal nudge. Instants in
  /// the past are skipped (the plugin refuses them).
  static Future<void> schedulePlanReminder({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required String payload,
  }) async {
    try {
      if (!await ensureInitialized()) return;
      if (!at.isAfter(DateTime.now())) return;
      final details = AndroidNotificationDetails(
        channelPlan,
        'Plan reminders',
        channelDescription: 'Tells you a few days before your CoRoute plan ends.',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        category: AndroidNotificationCategory.reminder,
        autoCancel: true,
        styleInformation: BigTextStyleInformation(body),
      );
      await _plugin?.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(at.toUtc(), tz.UTC),
        NotificationDetails(
          android: details,
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
    } catch (e) {
      debugPrint('plan reminder note: $e');
    }
  }

  /// Cancels scheduled plan reminders. Initialises first: the reminders outlive
  /// the process, so they must be cancellable before anything else ran.
  static Future<void> cancelPlanReminders(Iterable<int> ids) async {
    if (!await ensureInitialized()) return;
    for (final id in ids) {
      try {
        await _plugin?.cancel(id);
      } catch (_) {}
    }
  }

  /// Asks for the notification permission (Android 13+ / iOS). True when granted.
  static Future<bool> requestNotificationPermission() async {
    if (!await ensureInitialized()) return false;
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final ios = _plugin?.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
        return await ios?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
      }
      final android = _plugin?.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The payload of the notification that launched the app from a cold start, if any.
  static Future<String?> launchPayload() async {
    if (!await ensureInitialized()) return null;
    try {
      final d = await _plugin?.getNotificationAppLaunchDetails();
      if (d == null || !d.didNotificationLaunchApp) return null;
      return d.notificationResponse?.payload;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _cancel(int id) async {
    if (!_supported || _init == null) return;
    try {
      await _plugin?.cancel(id);
    } catch (_) {}
  }
}
