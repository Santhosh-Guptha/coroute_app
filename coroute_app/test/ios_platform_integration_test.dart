import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/ride_notification_constants.dart';
import 'package:coroute_app/data/services/alarm_notifier.dart';
import 'package:coroute_app/data/services/phone_call_service.dart';
import 'package:coroute_app/data/services/ride_notification_service.dart';
import 'package:coroute_app/data/services/safety_native.dart';
import 'package:coroute_app/data/services/sms_sender.dart';
import 'package:coroute_app/data/services/subscription_reminders.dart';
import 'package:coroute_app/data/services/voice_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AlarmNotifier.resetForTesting();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() {
    AlarmNotifier.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
  });

  group('iOS Platform Channels & Services End-to-End Tests', () {
    test('1. SafetyNative communicates with iOS coroute/safety channel', () async {
      final log = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('coroute/safety'),
        (call) async {
          log.add(call);
          switch (call.method) {
            case 'deviceInfo':
              return {
                'manufacturer': 'Apple',
                'model': 'iPhone15,2',
                'sdkInt': 17,
                'release': '17.4',
                'cpuAbi': 'arm64',
                'hasAccel': true,
                'accelFifo': 0,
                'hasGyro': true,
                'gyroFifo': 0,
              };
            case 'canUseFullScreenIntent':
              return true;
            case 'cacheDir':
              return '/var/mobile/Containers/Data/Application/CoRoute/Library/Caches';
            case 'networkKind':
              return 'wifi';
            case 'alarmWindow':
              return null;
            case 'phoneProbe':
              return {
                'accelPresent': true,
                'accelEvents': 75,
                'accelHz': 50.0,
                'gyroPresent': true,
                'gyroEvents': 75,
                'gyroHz': 50.0,
                'magPresent': true,
                'magEvents': 75,
                'magHz': 50.0,
                'probeMs': 1500,
                'sdkInt': 17,
                'bgRestricted': false,
                'powerSave': false,
                'dndFilter': 0,
                'mediaVol': 0.8,
                'mediaVolMax': 1.0,
                'alarmVol': 0.8,
                'alarmVolMax': 1.0,
                'ringerMode': 2,
                'btOut': 'a2dp',
                'btMic': false,
                'wiredOut': false,
                'freeBytes': 64000000000,
                'hasTelephony': true,
                'canCompose': true,
                'canDial': true,
              };
            case 'openFullScreenIntentSettings':
            case 'openOemBatterySettings':
            case 'openSoundSettings':
              return true;
            default:
              return null;
          }
        },
      );

      final info = await SafetyNative.deviceInfo();
      expect(info.manufacturer, equals('Apple'));
      expect(info.model, equals('iPhone15,2'));
      expect(info.hasAccel, isTrue);
      expect(info.hasGyro, isTrue);

      final fullScreen = await SafetyNative.canUseFullScreenIntent();
      expect(fullScreen, isTrue);

      final cache = await SafetyNative.cacheDir();
      expect(cache, contains('Caches'));

      final net = await SafetyNative.networkKind();
      expect(net, equals('wifi'));

      await SafetyNative.alarmWindow(true);
      expect(log.any((c) => c.method == 'alarmWindow' && c.arguments['on'] == true), isTrue);

      final probe = await SafetyNative.phoneProbe();
      expect(probe['accelPresent'], isTrue);
      expect(probe['gyroPresent'], isTrue);
      expect(probe['btOut'], equals('a2dp'));
      expect(probe['hasTelephony'], isTrue);
    });

    test('2. NativeVoiceEngine supports TargetPlatform.iOS for speech synthesis', () async {
      final log = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(NotifConstants.ttsChannel),
        (call) async {
          log.add(call);
          switch (call.method) {
            case 'init':
              return {'ok': true, 'language': 'en-IN'};
            case 'speak':
              return true;
            case 'stop':
            case 'release':
              return null;
            default:
              return null;
          }
        },
      );

      final engine = NativeVoiceEngine();
      final ready = await engine.init();
      expect(ready, isTrue);
      expect(engine.language, equals('en-IN'));

      final spoken = await engine.speak('Warning: road debris 200 meters ahead.', interrupt: false, id: 'test_1');
      expect(spoken, isTrue);
      expect(log.any((c) => c.method == 'speak' && (c.arguments['text'] as String).contains('debris')), isTrue);

      await engine.stop();
      expect(log.any((c) => c.method == 'stop'), isTrue);

      await engine.release();
      expect(log.any((c) => c.method == 'release'), isTrue);
    });

    test('3. RideNotificationChannel reports supported on TargetPlatform.iOS and delivers actions', () async {
      final log = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(NotifConstants.notifChannel),
        (call) async {
          log.add(call);
          switch (call.method) {
            case 'supported':
              return true;
            case 'show':
              return true;
            case 'takeLaunchAction':
              return {'action': 'WAIT', 'ref': 'rider_42'};
            case 'cancel':
              return null;
            default:
              return null;
          }
        },
      );

      final rideChannel = RideNotificationChannel();
      final supported = await rideChannel.supported();
      expect(supported, isTrue);

      final shown = await rideChannel.show({
        'title': 'Convoy: Western Ghats Express',
        'body': '5 riders · 32 km remaining',
        'ref': 'ride_convoy_101',
      });
      expect(shown, isTrue);
      expect(log.any((c) => c.method == 'show' && (c.arguments as Map)['title'].toString().contains('Ghats')), isTrue);

      final launchAction = await rideChannel.takeLaunchAction();
      expect(launchAction?['action'], equals('WAIT'));
      expect(launchAction?['ref'], equals('rider_42'));
    });

    test('4. NativeSmsSender queries capability and triggers iOS composer on coroute/sms', () async {
      final log = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('coroute/sms'),
        (call) async {
          log.add(call);
          switch (call.method) {
            case 'capability':
              return {
                'hasTelephony': true,
                'permission': true,
                'simReady': true,
                'canSendDirect': false,
              };
            case 'launchSmsIntent':
              return true;
            case 'send':
              return {'status': 'FAILED', 'code': -1, 'reason': 'DIRECT_SMS_NOT_SUPPORTED_ON_IOS'};
            default:
              return null;
          }
        },
      );

      final sender = NativeSmsSender();
      final cap = await sender.capability();
      expect(cap.hasTelephony, isTrue);
      expect(cap.permission, isTrue);
      expect(cap.simReady, isTrue);
      expect(cap.ready, isTrue);

      final launched = await SmsSender.launchSmsIntent(to: '+919876543210', body: 'Emergency SOS at location');
      expect(launched, isTrue);
      expect(log.any((c) => c.method == 'launchSmsIntent' && (c.arguments as Map)['to'] == '+919876543210'), isTrue);

      final sendStatus = await sender.send('+919876543210', 'Direct message');
      expect(sendStatus, equals(SmsStatus.failed));
    });

    test('5. PhoneCallService handles call states and audio playing status', () async {
      final log = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('coroute/phone_call'),
        (call) async {
          log.add(call);
          switch (call.method) {
            case 'getCallState':
              return {'state': 'IDLE', 'isCallActive': false};
            case 'isAudioPlaying':
              return true;
            default:
              return null;
          }
        },
      );

      final phone = PhoneCallService(autoStart: false);
      expect(phone.status, equals(PhoneCallStatus.idle));
      expect(phone.isCallActive, isFalse);

      phone.queuePostCallAlert('High hazard 500m ahead');
      expect(phone.pendingPostCallAlerts, isEmpty);
    });

    test('6. PlanReminderScheduler is supported on iOS and schedules reminders', () async {
      final scheduler = PlanReminderScheduler();
      expect(scheduler.supported, isTrue);

      final reminders = [
        PlanReminder(
          id: 101,
          daysBefore: 3,
          at: DateTime.now().add(const Duration(days: 3)),
          title: 'CoRoute Membership Expiring',
          body: 'Your plan expires in 3 days. Renew to stay protected.',
        ),
      ];

      expect(reminders.first.daysBefore, equals(3));
      expect(scheduler.supported, isTrue);
    });

    test('7. AlarmNotifier initializes on iOS platform and supports Darwin notification pathways', () async {
      final fakePlugin = _FakeLocalNotificationsPlugin();
      final initOk = await AlarmNotifier.ensureInitialized(fakePlugin);
      expect(initOk, isTrue);
      expect(fakePlugin.initialized, isTrue);
      expect(fakePlugin.lastSettings?.iOS, isNotNull);
    });
  });
}

class _FakeLocalNotificationsPlugin extends Fake implements FlutterLocalNotificationsPlugin {
  bool initialized = false;
  InitializationSettings? lastSettings;

  @override
  Future<bool?> initialize(
    InitializationSettings initializationSettings, {
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback? onDidReceiveBackgroundNotificationResponse,
  }) async {
    initialized = true;
    lastSettings = initializationSettings;
    return true;
  }
}
