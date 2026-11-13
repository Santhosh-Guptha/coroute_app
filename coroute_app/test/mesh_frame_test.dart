import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/mesh/mesh_frame.dart';
import 'package:coroute_app/domain/mesh/mesh_messages.dart';

// Round 10 offline link: sealed frames, authentication, replay protection and the message codecs
// (pure Dart: tool/pure_dart_test/run.sh test/mesh_frame_test.dart). gateway/test/mesh_bridge_r10.test.js opens frames
// sealed with the same layout.
Uint8List key(int seed) => Uint8List.fromList(List.generate(32, (i) => (i * 31 + seed) & 0xff));

MeshFrame frame({MeshClass cls = MeshClass.position, int origin = 0x6ff8bc7d, int boot = 7, int seq = 1, int t = 1800000000, int ttl = 4, Uint8List? payload}) =>
    MeshFrame(cls: cls, origin: origin, boot: boot, seq: seq, originTimeSec: t, initialTtl: ttl, ttl: ttl, payload: payload ?? Uint8List.fromList([MeshKind.chat, 2, 104, 105]), relay: origin, relayLat: 17.4, relayLng: 78.5);

void main() {
  test('short ids are FNV-1a 32 of the user id (same as gateway/src/mesh_bridge.js)', () {
    expect(meshShortId('u_ravi'), 0x6ff8bc7d);
    expect(meshShortId('rider-1'), 0x751f7b3d);
  });

  test('seal / open round trip keeps every field; header is 33 bytes + 16-byte tag', () {
    final c = MeshFrameCodec(MeshKeyring(key(1)));
    final sealed = c.seal(frame(cls: MeshClass.sos, seq: 99));
    expect(sealed.length, 33 + 4 + 16);
    final f = c.open(sealed)!;
    expect(f.cls, MeshClass.sos);
    expect(f.origin, 0x6ff8bc7d);
    expect(f.boot, 7);
    expect(f.seq, 99);
    expect(f.originTimeSec, 1800000000);
    expect(f.ttl, 4);
    expect(f.hops, 0);
    expect(f.relayLat, closeTo(17.4, 1e-4));
    expect(f.relayLng, closeTo(78.5, 1e-4));
    expect(MeshChat.decode(f.payload)!.text, 'hi');
  });

  test('an outsider (other ride key) can neither read nor inject; tampering fails', () {
    final mine = MeshFrameCodec(MeshKeyring(key(1)));
    final other = MeshFrameCodec(MeshKeyring(key(2)));
    final sealed = mine.seal(frame());
    expect(other.open(sealed), isNull, reason: 'other ride cannot open');
    expect(mine.open(other.seal(frame())), isNull, reason: 'frame sealed with another key is refused');
    for (final i in [4, 6, 12, 18, 21, 40, sealed.length - 1]) {
      final bad = Uint8List.fromList(sealed)..[i] ^= 0x01;
      expect(mine.open(bad), isNull, reason: 'authenticated byte $i');
    }
  });

  test('the relay header can be rewritten without the key and still opens (ttl, relay, position)', () {
    final c = MeshFrameCodec(MeshKeyring(key(1)));
    final sealed = c.seal(frame(ttl: 5));
    final relayed = MeshFrameCodec.rewriteRelay(sealed, ttl: 3, relay: 42, relayLat: -33.8688, relayLng: 151.2093);
    final f = c.open(relayed)!;
    expect(f.ttl, 3);
    expect(f.hops, 2);
    expect(f.relay, 42);
    expect(f.relayLat, closeTo(-33.8688, 1e-4));
    expect(f.relayLng, closeTo(151.2093, 1e-4));
    // A forged TTL above the authenticated initial TTL is capped.
    expect(c.open(MeshFrameCodec.rewriteRelay(sealed, ttl: 8, relay: 1))!.ttl, 5);
  });

  test('replay guard: once only, fresh only, future refused, eviction never lets an old id back in', () {
    final g = ReplayGuard(maxEntries: 50);
    const now = 1800000000;
    expect(g.check(frame(t: now), now), '');
    expect(g.check(frame(t: now), now), 'duplicate');
    expect(g.check(frame(seq: 2, t: now - 301), now), 'stale', reason: 'positions live 5 min');
    expect(g.check(frame(cls: MeshClass.sos, seq: 3, t: now - 3 * 3600), now), '', reason: 'SOS is carried for hours');
    expect(g.check(frame(seq: 4, t: now + 600), now), 'future');
    for (var i = 0; i < 80; i++) {
      g.check(frame(seq: 100 + i, t: now - 200 + i), now);
    }
    expect(g.size, lessThanOrEqualTo(50));
    expect(g.check(frame(seq: 100, t: now - 200), now), 'evicted');
    expect(g.check(frame(cls: MeshClass.sos, seq: 3, t: now - 3 * 3600), now), 'duplicate', reason: 'SOS ids are evicted last');
  });

  test('SOS, ack, alert, position, voice, chat and hello round trip', () {
    const sos = MeshSos(clientId: 'u_ravi-1800000000000', alertType: 'CRASH', lat: 17.385044, lng: 78.486671, occurredAtMs: 1800000000000, auto: true, accuracyM: 8, speedKmh: 42, heading: 271, source: 'CRASH_AUTO', linkToken: 'abcdefghijklmnopqrstuv', name: 'Ravi');
    final s = MeshSos.decode(sos.encode())!;
    expect([s.clientId, s.alertType, s.auto, s.resolved, s.accuracyM, s.speedKmh, s.heading, s.source, s.linkToken, s.name],
        ['u_ravi-1800000000000', 'CRASH', true, false, 8, 42.0, 271.0, 'CRASH_AUTO', 'abcdefghijklmnopqrstuv', 'Ravi']);
    expect(s.lat, closeTo(17.385044, 1e-6));
    expect(s.occurredAtMs, 1800000000000);

    final a = MeshSosAck.decode(const MeshSosAck(target: 5, clientId: 'c1', acker: 9, byServer: true, alertId: 'SOS-x').encode())!;
    expect([a.target, a.clientId, a.acker, a.byServer, a.alertId], [5, 'c1', 9, true, 'SOS-x']);

    final al = MeshAlert.decode(const MeshAlert(code: MeshAlertCode.chainStretch, subject: 77, text: 'x').encode())!;
    expect([al.code, al.subject, al.text], [1, 77, 'x']);

    const p = MeshPos(lat: 17.38504, lng: 78.48667, speedKmh: 58.3, heading: 90, batteryLevel: 64, isCharging: true, role: 'LEAD', sosActive: true, hasInternet: true, fuelUsableKm: 120, fixAgeSec: 3);
    final pe = p.encode();
    expect(pe.length, 19);
    final pd = MeshPos.decode(pe)!;
    expect(pd.lat, closeTo(17.38504, 1e-5));
    expect(pd.speedKmh, closeTo(58.3, 0.2));
    expect([pd.heading, pd.batteryLevel, pd.isCharging, pd.role, pd.sosActive, pd.hasInternet, pd.fuelUsableKm, pd.fixAgeSec], [90.0, 64, true, 'LEAD', true, true, 120.0, 3]);

    final v = MeshVoice.decode(MeshVoice(streamId: 3, frameSeq: 4, codec: MeshVoiceCodec.opus, sampleRate: 16000, payload: Uint8List.fromList([1, 2, 3]), start: true, clip: true, lead: true, clipChunks: 9, clipDurationMs: 7200, name: 'Ravi').encode())!;
    expect([v.streamId, v.frameSeq, v.codec, v.sampleRate, v.start, v.end, v.clip, v.lead, v.clipChunks, v.clipDurationMs, v.name, v.payload], [3, 4, 1, 16000, true, false, true, true, 9, 7200, 'Ravi', [1, 2, 3]]);

    expect(MeshChat.decode(const MeshChat('on my way').encode())!.text, 'on my way');
    final h = MeshHello.decode(const MeshHello(caps: MeshCaps.codedPhy | MeshCaps.internet, along10m: -12, name: 'Ann').encode())!;
    expect([h.caps, h.along10m, h.name], [MeshCaps.codedPhy | MeshCaps.internet, -12, 'Ann']);
    expect(MeshSos.decode(Uint8List.fromList([MeshKind.sos, 0, 0])), isNull, reason: 'truncated');
  });

  test('beacon: 13 bytes, MAC binds group, rider and time; outsiders and stale replays fail', () {
    final k = MeshKeyring(key(1));
    const now = 1800000000;
    final b = MeshBeacon(groupTag: k.groupTag, rider: 0x6ff8bc7d, seq: 9, caps: MeshCaps.codedPhy | MeshCaps.extendedAdv, psm: 0x85).encode(k, now);
    expect(b.length, 13);
    final d = MeshBeacon.decode(k, b, now + 30)!;
    expect([d.rider, d.seq, d.caps, d.psm], [0x6ff8bc7d, 9, 3, 0x85]);
    expect(MeshBeacon.decode(k, b, now + 600), isNull, reason: '10 minutes later the MAC no longer verifies');
    expect(MeshBeacon.decode(MeshKeyring(key(2)), b, now), isNull);
    final forged = Uint8List.fromList(b)..[5] ^= 1;
    expect(MeshBeacon.decode(k, forged, now), isNull);
  });
}
