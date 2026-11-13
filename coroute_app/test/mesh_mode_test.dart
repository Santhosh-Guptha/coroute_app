import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/mesh/mesh_messages.dart';
import 'package:coroute_app/domain/mesh/offline_link_mode.dart';

// Round 10 offline link: automatic switching, duty cycles, capability report and the status chip
// (pure Dart: tool/pure_dart_test/run.sh test/mesh_mode_test.dart).
void main() {
  OfflineLinkMode step(OfflineModeSwitch s, int t, {bool ride = true, bool radio = true, bool socket = true, bool net = true, bool hears = false}) =>
      s.update(nowMs: t, inGroupRide: ride, radioAvailable: radio, socketConnected: socket, networkAvailable: net, hearsOfflinePeers: hears);

  test('off outside a group ride or without Bluetooth LE; standby while the server link is healthy', () {
    final s = OfflineModeSwitch();
    expect(step(s, 0, ride: false), OfflineLinkMode.off);
    expect(step(s, 0, radio: false), OfflineLinkMode.off);
    expect(step(s, 0), OfflineLinkMode.standby);
  });

  test('offline after the socket has been down 8 s, or 3 s with no network at all; back only after 10 s healthy', () {
    final s = OfflineModeSwitch();
    step(s, 0);
    expect(step(s, 1000, socket: false), OfflineLinkMode.standby);
    expect(step(s, 8500, socket: false), OfflineLinkMode.standby, reason: 'down 7.5 s');
    expect(step(s, 9100, socket: false), OfflineLinkMode.offline);
    expect(step(s, 10000), OfflineLinkMode.offline, reason: 'one good second is not enough');
    expect(step(s, 12000, socket: false), OfflineLinkMode.offline);
    expect(step(s, 13000), OfflineLinkMode.offline);
    expect(step(s, 23500), OfflineLinkMode.standby);
    final n = OfflineModeSwitch();
    step(n, 0);
    expect(step(n, 1000, socket: false, net: false), OfflineLinkMode.standby);
    expect(step(n, 4100, socket: false, net: false), OfflineLinkMode.offline);
  });

  test('bridge while online and a rider in range has lost signal', () {
    final s = OfflineModeSwitch();
    expect(step(s, 0, hears: true), OfflineLinkMode.bridge);
    expect(step(s, 1000, hears: false), OfflineLinkMode.standby);
    expect(step(s, 2000, ride: false), OfflineLinkMode.off);
  });

  test('duty cycles: aggressive only while offline in a ride; SOS overrides low battery', () {
    expect(MeshDutyPlan.forMode(OfflineLinkMode.off).scan, MeshScanMode.off);
    expect(MeshDutyPlan.forMode(OfflineLinkMode.standby).maxLinks, 0);
    expect(MeshDutyPlan.forMode(OfflineLinkMode.standby).scan, MeshScanMode.lowPower);
    expect(MeshDutyPlan.forMode(OfflineLinkMode.offline).scan, MeshScanMode.lowLatency);
    expect(MeshDutyPlan.forMode(OfflineLinkMode.offline, lowBattery: true).scan, MeshScanMode.balanced);
    expect(MeshDutyPlan.forMode(OfflineLinkMode.offline, lowBattery: true, sosActive: true).scan, MeshScanMode.lowLatency);
    expect(MeshDutyPlan.forMode(OfflineLinkMode.offline).estimatedMilliAmps, greaterThan(MeshDutyPlan.forMode(OfflineLinkMode.standby).estimatedMilliAmps));
  });

  test('capability report: "4 of 6 phones support long range"', () {
    const lr = MeshCaps.codedPhy | MeshCaps.extendedAdv;
    final caps = {'a': lr, 'b': lr, 'c': lr | MeshCaps.l2cap, 'd': lr, 'e': MeshCaps.l2cap, 'f': 0};
    final r = MeshCapabilityReport.of(caps.keys, (id) => caps[id]);
    expect(r.line, '4 of 6 phones support long range');
    final partial = MeshCapabilityReport.of(['a', 'x', 'y'], (id) => caps[id]);
    expect(partial.line, '1 of 3 phones supports long range (2 not checked yet)');
    expect(MeshCapabilityReport.of(['e'], (id) => caps[id]).line, '0 of 1 phone support long range');
    expect(MeshCaps.longRange(MeshCaps.codedPhy), isFalse, reason: 'Coded PHY needs extended advertising too');
  });

  test('status chip text', () {
    expect(offlineLinkChipText(riders: 5, maxHops: 2), 'Offline link: 5 riders, 2 hops');
    expect(offlineLinkChipText(riders: 1, maxHops: 1), 'Offline link: 1 rider');
    expect(offlineLinkChipText(riders: 0, maxHops: 0), 'Offline link: searching for riders');
  });
}
