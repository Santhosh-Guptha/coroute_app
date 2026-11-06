// Wiring of the auto re-route: the spoken lines exist in every voice
// language, my own server-side "off the planned route" alert is shown but
// never spoken (the ride's navigation voice says it, with its own limits),
// and a new route is asked for with my direction of travel.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/geo_service.dart';
import 'package:coroute_app/data/services/nav_voice.dart';
import 'package:coroute_app/domain/navigation/nav_prompts.dart';
import 'package:coroute_app/domain/notify/alert_policy.dart';

void main() {
  test('every navigation line exists in en, hi and te; the English text is the one in the code', () {
    for (final p in NavPrompt.values) {
      expect(NavVoice.text(p, 'en'), p.english);
      for (final lang in ['hi', 'te']) {
        expect(L10n.has(p.l10nKey, lang), isTrue, reason: '${p.l10nKey}/$lang');
        expect(NavVoice.text(p, lang), isNot(p.english), reason: '${p.l10nKey}/$lang');
      }
    }
  });

  test("my own off-route alert from the group timeline is never spoken; a rider's alert for the lead still is", () {
    const e = TimelineEventModel(eventId: 'e1', groupId: 'G', userId: 'me', userName: 'Kiran', type: 'OFF_ROUTE', startedAt: 0, open: true);
    final policy = AlertPolicy();
    final mine = policy.standing([e], const AlertViewer(userId: 'me'), nowMs: 120000).singleWhere((a) => a.key == 'OFF_ROUTE:me');
    expect(mine.title, 'You are off the planned route');
    expect(mine.silent, isTrue);
    final lead = policy.standing([e], const AlertViewer(userId: 'lead', isLead: true), nowMs: 120000).singleWhere((a) => a.key == 'OFF_ROUTE:me');
    expect(lead.silent, isFalse);
    expect(mine == AlertSpec(mine.key, mine.channel, mine.title, mine.body), isFalse, reason: 'silent is part of equality');
  });

  test('a new route is asked for with my direction of travel (none for a planned route)', () async {
    Map<String, dynamic>? body;
    final api = ApiClient(httpClient: MockClient((r) async {
      body = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
      return http.Response(jsonEncode({'distanceM': 11000, 'durationS': 600, 'polyline': '_p~iF~ps|U_ulLnnqC'}), 200);
    }));
    final geo = GeoService(api);
    final r = await geo.route([(17.0, 78.0), (17.1, 78.0)], startHeadingDeg: 271.6);
    expect(r, isNotNull);
    expect(body!['startBearing'], 272);
    expect((body!['waypoints'] as List).length, 2);
    await geo.route([(17.0, 78.0), (17.1, 78.0)], startHeadingDeg: -90);
    expect(body!['startBearing'], 270);
    await geo.route([(17.0, 78.0), (17.1, 78.0)]);
    expect(body!.containsKey('startBearing'), isFalse);
  });
}
