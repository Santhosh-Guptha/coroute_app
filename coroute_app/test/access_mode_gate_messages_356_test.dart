import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/membership_model.dart';
import 'package:coroute_app/domain/membership/plan_gate_messages.dart';
import 'package:coroute_app/domain/membership/plan_summary.dart';
import 'package:coroute_app/domain/membership/ride_capabilities.dart';
import 'package:coroute_app/domain/notify/push_kinds.dart';

/// 3.56 access mode (gateway src/access_mode.js): the app only reads capabilities and shows neutral
/// words; push kinds map to their own channel and switch.
void main() {
  RideCapabilities caps(Map<String, dynamic> json) => RideCapabilities.fromJson(json);

  test('free for everyone: nothing is gated, no message, no plan UI', () {
    final c = caps({'gated': false, 'canHostGroup': true, 'maxRiders': 12, 'groupFeatures': 'all', 'reason': null, 'version': 4});
    expect(c.gated, isFalse);
    expect(c.allGroupFeatures, isTrue);
    expect(PlanGateMessages.forCapabilities(c), isNull);
    expect(PlanGateMessages.forFeature(c, 'intercom'), isNull);
    final overview = MyMembershipOverview.fromJson({
      'paymentsEnabled': true,
      'plan': {'source': 'community', 'category': 'community', 'name': 'Community', 'seats': 1},
      'capabilities': {'gated': false, 'canHostGroup': true, 'maxRiders': 12, 'groupFeatures': 'all'},
    });
    expect(overview.plansEnforced, isFalse, reason: 'free mode hides every plan line, like payments off');
    expect(overview.capabilities!.maxRiders, 12);
  });

  test('free up to limits: neutral words for the monthly limit and a feature left out', () {
    final limited = caps({'gated': true, 'canHostGroup': false, 'maxRiders': 1, 'groupFeatures': <String>[], 'hostedRidesLeft': 0, 'hostedRidesLimit': 8, 'reason': 'HOSTED_RIDES_LIMIT'});
    expect(PlanGateMessages.forCapabilities(limited), 'Hosting more group rides needs a group plan.');
    final freeTier = caps({'gated': true, 'canHostGroup': true, 'maxRiders': 6, 'groupFeatures': ['intercom', 'crewRides'], 'hostedRidesLeft': 3, 'hostedRidesLimit': 8});
    expect(PlanGateMessages.forCapabilities(freeTier), isNull, reason: 'hosting is allowed');
    expect(PlanGateMessages.forFeature(freeTier, 'intercom'), isNull);
    expect(PlanGateMessages.forFeature(freeTier, 'rideRoles'), "This isn't included in this ride.");
    expect(freeTier.allows('sos'), isTrue, reason: 'safety is never limited');
    expect(freeTier.hostedRidesLeft, 3);
    // Server refusals map to the same words.
    expect(PlanGateMessages.forCode('HOSTED_RIDES_LIMIT'), PlanGateMessages.hostingMoreNeedsGroupPlan);
    expect(PlanGateMessages.forCode('GROUP_FEATURE_LOCKED'), PlanGateMessages.notInThisRide);
    expect(PlanGateMessages.forCode('CONVOY_FULL'), 'This ride is full.');
    expect(PlanGateMessages.neutral('GROUP_FEATURE_LOCKED', null, 'whatever the server said'), "This isn't included in this ride.");
  });

  test('paid: the existing neutral line', () {
    final c = caps({'gated': true, 'canHostGroup': false, 'maxRiders': 1, 'groupFeatures': <String>[], 'reason': 'GROUP_PLAN_REQUIRED'});
    expect(PlanGateMessages.forCapabilities(c), PlanGateMessages.hostingNeedsGroupPlan);
    expect(PlanGateMessages.forCapabilities(caps({'gated': true, 'canHostGroup': false, 'maxRiders': 1})), PlanGateMessages.hostingNeedsGroupPlan);
  });

  test('no gate message has money or buying words, and none is a link', () {
    for (final m in [
      PlanGateMessages.hostingMoreNeedsGroupPlan,
      PlanGateMessages.notInThisRide,
      PlanGateMessages.hostingNeedsGroupPlan,
      PlanGateMessages.rideFull,
    ]) {
      expect(planForbiddenText.hasMatch(m), isFalse, reason: m);
      expect(m.contains('http'), isFalse, reason: m);
      expect(m.contains('/plans'), isFalse, reason: m);
    }
  });

  test('a ride limited to some group features (CONFIG / snapshot)', () {
    final limited = ConvoyModel.fromJson({'groupId': 'GRP-AB12', 'name': 'Ride', 'capacity': 6, 'groupFeatures': ['intercom']});
    expect(limited.allowsGroupFeature('intercom'), isTrue);
    expect(limited.allowsGroupFeature('rideRoles'), isFalse);
    expect(limited.allowsGroupFeature('pillionSeat'), isTrue, reason: 'only gatable features can be left out');
    final all = ConvoyModel.fromJson({'groupId': 'GRP-AB12', 'name': 'Ride', 'capacity': 6, 'groupFeatures': 'all'});
    expect(all.groupFeatures, isNull);
    expect(all.allowsGroupFeature('rideRoles'), isTrue);
    expect(limited.copyWith(groupFeatures: null).allowsGroupFeature('rideRoles'), isTrue, reason: 'a lifted limit clears the list');
    expect(limited.copyWith(capacity: 12).groupFeatures, ['intercom'], reason: 'other changes keep it');
  });

  test('push kinds: own channel and switch; partner perks off by default and labelled', () {
    expect(PushKinds.all.map((k) => k.id), ['update', 'event', 'safety_tip', 'community', 'partner_perk']);
    expect(PushKinds.all.map((k) => k.channel).toSet().length, PushKinds.all.length);
    expect(PushKinds.update.serverKey, 'news');
    expect(PushKinds.update.localKey, 'push_news_enabled', reason: 'the 3.56 News switch is kept');
    expect(PushKinds.partnerPerk.defaultOn, isFalse);
    expect(PushKinds.of('event'), PushKinds.event);
    expect(PushKinds.of(null), PushKinds.update, reason: 'an older gateway sends no kind');
    expect(PushKinds.of('advert'), PushKinds.update);
    expect(PushKinds.labelFor('partner_perk', 'Speed Garage'), 'Partner perk · Speed Garage');
    expect(PushKinds.labelFor('partner_perk', null), 'Partner perk');
    expect(PushKinds.labelFor('event', 'x'), isNull);
    for (final k in PushKinds.all) {
      expect(planForbiddenText.hasMatch('${k.title} ${k.subtitle}'), isFalse, reason: k.id);
    }
  });
}
