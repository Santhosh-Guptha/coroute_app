import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/helmet_voice_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/voice/helmet_voice_hotword.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  group('HelmetVoiceMatcher Keyword Recognition Tests', () {
    test('Recognizes "CoRoute I\'m OK" and variations', () {
      expect(HelmetVoiceMatcher.match("CoRoute I'm OK")?.hotword, equals(HelmetVoiceHotword.imOk));
      expect(HelmetVoiceMatcher.match("i am ok")?.hotword, equals(HelmetVoiceHotword.imOk));
      expect(HelmetVoiceMatcher.match("cancel sos")?.hotword, equals(HelmetVoiceHotword.imOk));
      expect(HelmetVoiceMatcher.match("all clear")?.hotword, equals(HelmetVoiceHotword.imOk));
    });

    test('Recognizes "CoRoute SOS" and distress beacons', () {
      expect(HelmetVoiceMatcher.match("coroute sos")?.hotword, equals(HelmetVoiceHotword.emergency));
      expect(HelmetVoiceMatcher.match("Emergency! Mayday!")?.hotword, equals(HelmetVoiceHotword.emergency));
      expect(HelmetVoiceMatcher.match("Need help quickly")?.hotword, equals(HelmetVoiceHotword.emergency));
    });

    test('Recognizes "CoRoute Fuel" and petrol requests', () {
      expect(HelmetVoiceMatcher.match("coroute fuel")?.hotword, equals(HelmetVoiceHotword.fuel));
      expect(HelmetVoiceMatcher.match("need fuel soon")?.hotword, equals(HelmetVoiceHotword.fuel));
      expect(HelmetVoiceMatcher.match("petrol stop please")?.hotword, equals(HelmetVoiceHotword.fuel));
    });

    test('Recognizes "CoRoute Regroup" and wait requests', () {
      expect(HelmetVoiceMatcher.match("coroute regroup")?.hotword, equals(HelmetVoiceHotword.regroup));
      expect(HelmetVoiceMatcher.match("wait for me")?.hotword, equals(HelmetVoiceHotword.regroup));
      expect(HelmetVoiceMatcher.match("please wait")?.hotword, equals(HelmetVoiceHotword.regroup));
    });

    test('Recognizes "CoRoute Intercom" and mic mute toggles', () {
      expect(HelmetVoiceMatcher.match("coroute intercom")?.hotword, equals(HelmetVoiceHotword.intercom));
      expect(HelmetVoiceMatcher.match("mute mic")?.hotword, equals(HelmetVoiceHotword.intercom));
      expect(HelmetVoiceMatcher.match("unmute mic")?.hotword, equals(HelmetVoiceHotword.intercom));
    });

    test('Rejects unrelated chatter', () {
      expect(HelmetVoiceMatcher.match("the weather is quite nice today"), isNull);
      expect(HelmetVoiceMatcher.match("look at that scenery"), isNull);
    });
  });

  group('HelmetVoiceService Integration Tests', () {
    late ConvoyService convoyService;
    late HelmetVoiceService helmetVoice;

    setUp(() {
      final client = MockClient((request) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: client);
      convoyService = ConvoyService(
        api,
        RealtimeService(),
        TripStorageService(api),
      );
      convoyService.setMyUserIdForTesting('user_me');

      final convoy = ConvoyModel(
        groupId: 'grp_ghats',
        name: 'Western Ghats Ride',
        joinCode: 'GHAT1',
        createdByUserId: 'user_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 1000,
        riders: {
          'user_me': RiderModel(
            userId: 'user_me',
            name: 'Santhosh',
            lat: 13.0000,
            lng: 75.0000,
            lastSeenEpochMs: 1000,
          ),
        },
      );
      convoyService.setActiveConvoyForTesting(convoy);

      helmetVoice = HelmetVoiceService(
        convoyService: convoyService,
      );
    });

    tearDown(() {
      helmetVoice.dispose();
      convoyService.dispose();
    });

    test('Spoken "CoRoute SOS" triggers emergency SOS alert in convoy', () async {
      final match = await helmetVoice.processSpeech("CoRoute SOS");
      expect(match, isNotNull);
      expect(match!.hotword, equals(HelmetVoiceHotword.emergency));

      // Pending SOS is created in convoy
      expect(convoyService.pendingSos, isNotNull);
      expect(convoyService.pendingSos!.type, equals('CRASH_OR_EMERGENCY'));
    });

    test('Spoken "CoRoute Fuel" dispatches fuel request message to convoy', () async {
      final match = await helmetVoice.processSpeech("Need fuel at next petrol bunk");
      expect(match, isNotNull);
      expect(match!.hotword, equals(HelmetVoiceHotword.fuel));

      // Outbox contains fuel chat request
      expect(convoyService.outbox, isNotEmpty);
      final item = convoyService.outbox.first;
      expect(item.type, equals('CHAT'));
      expect(item.payload['cardType'], equals('FUEL'));
      expect(item.payload['text'], contains('Fuel stop requested'));
    });

    test('Spoken "Wait for me" dispatches WAIT regroup request', () async {
      final match = await helmetVoice.processSpeech("Wait for me please");
      expect(match, isNotNull);
      expect(match!.hotword, equals(HelmetVoiceHotword.regroup));

      // Outbox contains WAIT request
      expect(convoyService.outbox.any((i) => i.type == 'WAIT'), isTrue);
    });

    test('Spoken "CoRoute I\'m OK" confirms safety check-in', () async {
      final match = await helmetVoice.processSpeech("CoRoute I'm OK");
      expect(match, isNotNull);
      expect(match!.hotword, equals(HelmetVoiceHotword.imOk));
    });
  });
}
