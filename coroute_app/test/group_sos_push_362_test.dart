import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/notify/push_routing.dart';

/// v3.62: a group member's SOS pushed to a phone whose app was closed opens the app (the ride restores and its
/// re-join brings the SOS card).
void main() {
  test('GROUP_SOS and its close are known and open the app', () {
    expect(PushRouting.knownTypes, containsAll(['GROUP_SOS', 'GROUP_SOS_RESOLVED']));
    expect(PushRouting.routeFor('GROUP_SOS', {'groupId': 'g1', 'alertId': 'SOS-1'}).destination, PushDestination.home);
    expect(PushRouting.routeFor('GROUP_SOS_RESOLVED', const {}).destination, PushDestination.home);
  });
}
