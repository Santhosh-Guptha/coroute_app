import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_cockpit_stats_row.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_hold_to_talk_bar.dart';

class _MockRealtime extends RealtimeService {
  final StreamController<Map<String, dynamic>> _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<VoicePacket> _voiceCtrl = StreamController<VoicePacket>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
  @override
  Stream<VoicePacket> get voice => _voiceCtrl.stream;
  @override
  bool get isConnected => true;
  @override
  String? get groupId => 'test-group';
  @override
  RealtimeState get state => RealtimeState.connected;
  @override
  bool supports(String feature) => true;
  @override
  bool send(Map<String, dynamic> message) => true;
  @override
  void sendVoice(int kind, Map<String, dynamic> header, [Uint8List? payload]) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final me = RiderModel(
    userId: 'u1',
    name: 'Santhosh Kumar',
    lat: 12.9716,
    lng: 77.5946,
    speedKmh: 45.0,
    heading: 90.0,
    role: 'LEAD',
    lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
  );

  final rider2 = RiderModel(
    userId: 'u2',
    name: 'Kiran Rao',
    lat: 12.9800,
    lng: 77.6000,
    speedKmh: 48.0,
    heading: 90.0,
    role: 'RIDER',
    lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
  );

  final convoy = ConvoyModel(
    groupId: 'test-group',
    name: 'Bangalore Weekend Ride',
    joinCode: 'BLR123',
    createdByUserId: 'u1',
    createdByUserName: 'Santhosh Kumar',
    createdAtEpochMs: 1000,
    riders: {'u1': me, 'u2': rider2},
    destinationName: 'Nandi Hills',
  );

  final snap = RideSnapshot(
    me: me,
    remainingM: 9700,
    eta: const Duration(minutes: 35),
    nextStop: null,
    nextStopM: null,
    spreadM: 1200,
    ladder: [
      LadderRung(rider: rider2, isMe: false, fromMeM: 1200),
      LadderRung(rider: me, isMe: true, fromMeM: 0),
    ],
    stops: const [],
  );

  testWidgets('MinimalCockpitStatsRow renders ETA, remaining km, relative position, and guardian badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MinimalCockpitStatsRow(
            convoy: convoy,
            me: me,
            snap: snap,
            eta: '16:14',
            guardianOn: true,
            now: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );

    expect(find.textContaining('ETA 16:14'), findsOneWidget);
    expect(find.textContaining('9.7 km left'), findsOneWidget);
    expect(find.textContaining('Kiran 1.2 km ahead'), findsOneWidget);
    expect(find.text('Guardian on'), findsOneWidget);
  });

  testWidgets('MinimalHoldToTalkBar renders glove-friendly PTT button with waveform', (tester) async {
    final rt = _MockRealtime();
    final intercom = IntercomService(rt);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<IntercomService?>.value(
            value: intercom,
            child: MinimalHoldToTalkBar(
              convoy: convoy,
              me: me,
            ),
          ),
        ),
      ),
    );

    expect(find.text('HOLD TO TALK'), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);

    // Verify touch target height is at least 48dp (it is 54dp)
    final renderBox = tester.renderObject<RenderBox>(find.byType(AnimatedContainer));
    expect(renderBox.size.height, greaterThanOrEqualTo(48.0));
  });

  testWidgets('Strict Standards: ZERO emojis and ASCII hyphens in minimal cockpit widgets', (tester) async {
    final emojiRegex = RegExp(r'[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]', unicode: true);
    final unicodeDashRegex = RegExp(r'[\u2010\u2011\u2012\u2013\u2014\u2015]');

    final rt = _MockRealtime();
    final intercom = IntercomService(rt);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MinimalCockpitStatsRow(
                convoy: convoy,
                me: me,
                snap: snap,
                eta: '16:14',
                guardianOn: true,
                now: DateTime.now().millisecondsSinceEpoch,
              ),
              ChangeNotifierProvider<IntercomService?>.value(
                value: intercom,
                child: MinimalHoldToTalkBar(
                  convoy: convoy,
                  me: me,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text));
    for (final t in texts) {
      final s = t.data ?? t.textSpan?.toPlainText() ?? '';
      expect(emojiRegex.hasMatch(s), isFalse, reason: 'Found forbidden emoji in "$s"');
      expect(unicodeDashRegex.hasMatch(s), isFalse, reason: 'Found unicode dash in "$s"');
    }
  });
}
