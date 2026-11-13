// Round 10 offline link: the messages inside a sealed mesh frame (mesh_frame.dart). Compact binary, big-endian. The first
// payload byte is the kind. Positions use the Round 8 pos2 scales (1e-5 degrees, dm/s, whole degrees) so a bridged
// position becomes a pos2-style patch on the gateway without any rounding change. Pure Dart, tested in
// test/mesh_frame_test.dart; the gateway decodes SOS, SOS_ACK and POS (gateway/src/mesh_bridge.js).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'mesh_frame.dart';

class MeshKind {
  static const int sos = 0x01;
  static const int sosAck = 0x02;
  static const int alert = 0x10;
  static const int pos = 0x20;
  static const int voice = 0x30;
  static const int clipNack = 0x31;
  static const int chat = 0x40;
  static const int hello = 0x50;

  static MeshClass classOf(int kind) => switch (kind) {
        sos || sosAck => MeshClass.sos,
        alert => MeshClass.alert,
        pos => MeshClass.position,
        voice || clipNack => MeshClass.voice,
        chat => MeshClass.chat,
        _ => MeshClass.control,
      };
}

class _W {
  final BytesBuilder b = BytesBuilder(copy: false);
  void u8(int v) => b.addByte(v & 0xff);
  void u16(int v) => b.add([(v >> 8) & 0xff, v & 0xff]);
  void u32(int v) => b.add([(v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff]);
  void i32(int v) => u32(v & 0xffffffff);
  void str(String s, int max) {
    var e = utf8.encode(s);
    if (e.length > max) e = e.sublist(0, max);
    u8(e.length);
    b.add(e);
  }

  void bytes(Uint8List v) => b.add(v);
  Uint8List done() => b.takeBytes();
}

class _R {
  _R(this.d) : bd = ByteData.sublistView(d);
  final Uint8List d;
  final ByteData bd;
  int o = 0;
  bool get ok => o <= d.length;
  int u8() => o < d.length ? d[o++] : (o++ & 0);
  int u16() {
    if (o + 2 > d.length) {
      o += 2;
      return 0;
    }
    final v = bd.getUint16(o);
    o += 2;
    return v;
  }

  int u32() {
    if (o + 4 > d.length) {
      o += 4;
      return 0;
    }
    final v = bd.getUint32(o);
    o += 4;
    return v;
  }

  int i32() {
    if (o + 4 > d.length) {
      o += 4;
      return 0;
    }
    final v = bd.getInt32(o);
    o += 4;
    return v;
  }

  String str() {
    final n = u8();
    if (o + n > d.length) {
      o += n;
      return '';
    }
    final s = utf8.decode(d.sublist(o, o + n), allowMalformed: true);
    o += n;
    return s;
  }

  Uint8List rest() {
    if (o >= d.length) return Uint8List(0);
    final r = Uint8List.sublistView(d, o);
    o = d.length;
    return r;
  }
}

/// SOS types on the wire (same names as the app's SosTypes / the gateway's sosType()). Anything else travels as 'SOS'
/// (the gateway normalises it like any SOS); 'CRASH_OR_EMERGENCY' and other CRASH* kinds as CRASH.
const List<String> meshSosTypes = ['CRASH', 'BREAKDOWN', 'MEDICAL', 'STOPPED', 'CUSTOM', 'SOS'];

int _sosTypeIndex(String t) {
  final u = t.toUpperCase();
  if (u.startsWith('CRASH')) return 0;
  final i = meshSosTypes.indexOf(u);
  return i < 0 ? meshSosTypes.length - 1 : i;
}

/// An SOS raised (or resolved) by its origin. [clientId] is the phone's own SOS id, so the gateway stores ONE alert
/// whichever copy arrives first (direct socket, HTTP, bridge, or several bridges).
class MeshSos {
  const MeshSos({
    required this.clientId,
    required this.alertType,
    required this.lat,
    required this.lng,
    required this.occurredAtMs,
    this.auto = false,
    this.resolved = false,
    this.accuracyM,
    this.speedKmh,
    this.heading,
    this.source = 'MANUAL',
    this.linkToken = '',
    this.name = '',
  });

  final String clientId;
  final String alertType;
  final double lat;
  final double lng;
  final int occurredAtMs;
  final bool auto;
  final bool resolved;
  final int? accuracyM;
  final double? speedKmh;
  final double? heading;
  final String source;
  final String linkToken;
  final String name;

  Uint8List encode() {
    final w = _W()
      ..u8(MeshKind.sos)
      ..u8((auto ? 1 : 0) | (resolved ? 2 : 0) | (accuracyM != null ? 4 : 0) | (speedKmh != null ? 8 : 0) | (heading != null ? 16 : 0))
      ..u8(_sosTypeIndex(alertType))
      ..i32((lat * 1e6).round())
      ..i32((lng * 1e6).round())
      ..u32((occurredAtMs ~/ 1000) & 0xffffffff)
      ..u16((accuracyM ?? 0).clamp(0, 65535))
      ..u8((speedKmh ?? 0).round().clamp(0, 255))
      ..u16(((heading ?? 0).round() % 360 + 360) % 360)
      ..str(source, 24)
      ..str(clientId, 64)
      ..str(linkToken, 32)
      ..str(name, 32);
    return w.done();
  }

  static MeshSos? decode(Uint8List p) {
    final r = _R(p);
    if (r.u8() != MeshKind.sos) return null;
    final f = r.u8();
    final t = r.u8();
    final lat = r.i32() / 1e6, lng = r.i32() / 1e6;
    final at = r.u32() * 1000;
    final acc = r.u16();
    final sp = r.u8();
    final hd = r.u16();
    final src = r.str(), cid = r.str(), link = r.str(), name = r.str();
    if (!r.ok || cid.isEmpty) return null;
    return MeshSos(
      clientId: cid,
      alertType: meshSosTypes[t.clamp(0, meshSosTypes.length - 1)],
      lat: lat,
      lng: lng,
      occurredAtMs: at,
      auto: f & 1 != 0,
      resolved: f & 2 != 0,
      accuracyM: f & 4 != 0 ? acc : null,
      speedKmh: f & 8 != 0 ? sp.toDouble() : null,
      heading: f & 16 != 0 ? hd.toDouble() : null,
      source: src.isEmpty ? 'MANUAL' : src,
      linkToken: link,
      name: name,
    );
  }
}

/// "Your SOS reached someone": from any rider (heard it over the mesh) or from the server (via a bridge). The origin
/// stops resending its SOS only after this arrives.
class MeshSosAck {
  const MeshSosAck({required this.target, required this.clientId, required this.acker, this.byServer = false, this.alertId = ''});
  final int target;
  final String clientId;
  final int acker;
  final bool byServer;
  final String alertId;

  Uint8List encode() => (_W()
        ..u8(MeshKind.sosAck)
        ..u32(target)
        ..u32(acker)
        ..u8(byServer ? 1 : 0)
        ..str(clientId, 64)
        ..str(alertId, 64))
      .done();

  static MeshSosAck? decode(Uint8List p) {
    final r = _R(p);
    if (r.u8() != MeshKind.sosAck) return null;
    final target = r.u32(), acker = r.u32(), f = r.u8();
    final cid = r.str(), aid = r.str();
    if (!r.ok || cid.isEmpty) return null;
    return MeshSosAck(target: target, clientId: cid, acker: acker, byServer: f & 1 != 0, alertId: aid);
  }
}

/// Group alert codes.
class MeshAlertCode {
  /// "Group link stretched behind (subject)" (chain-keeper, for the lead).
  static const int chainStretch = 1;

  /// A rider's status (stopped / fuel / regroup) - [text] is the status reason.
  static const int status = 2;

  /// "I'm going" / "I'm with them" for an SOS ([subject] = the SOS origin).
  static const int sosRespond = 3;
}

class MeshAlert {
  const MeshAlert({required this.code, this.subject = 0, this.text = ''});
  final int code;
  final int subject;
  final String text;

  Uint8List encode() => (_W()
        ..u8(MeshKind.alert)
        ..u8(code)
        ..u32(subject)
        ..str(text, 120))
      .done();

  static MeshAlert? decode(Uint8List p) {
    final r = _R(p);
    if (r.u8() != MeshKind.alert) return null;
    final code = r.u8(), subject = r.u32();
    final text = r.str();
    return r.ok ? MeshAlert(code: code, subject: subject, text: text) : null;
  }
}

/// A position fix, pos2 scales. 22 bytes.
class MeshPos {
  const MeshPos({
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.heading,
    this.batteryLevel = 100,
    this.isCharging = false,
    this.role = 'PACK',
    this.sosActive = false,
    this.hasInternet = false,
    this.fuelUsableKm,
    this.fixAgeSec = 0,
  });

  final double lat;
  final double lng;
  final double speedKmh;
  final double heading;
  final int batteryLevel;
  final bool isCharging;
  final String role;
  final bool sosActive;
  final bool hasInternet;
  final double? fuelUsableKm;

  /// Seconds between the fix and the frame's origin time (a proxied position from the server is older).
  final int fixAgeSec;

  static int _role(String r) => switch (r.toUpperCase()) { 'LEAD' => 1, 'SWEEPER' => 2, _ => 0 };
  static String _roleName(int v) => switch (v) { 1 => 'LEAD', 2 => 'SWEEPER', _ => 'PACK' };

  Uint8List encode() => (_W()
        ..u8(MeshKind.pos)
        ..i32((lat * 1e5).round())
        ..i32((lng * 1e5).round())
        ..u16((speedKmh / 0.36).round().clamp(0, 65535))
        ..u16(((heading.round() % 360) + 360) % 360)
        ..u8((batteryLevel.clamp(0, 100)) | (isCharging ? 0x80 : 0))
        ..u8(_role(role) | (sosActive ? 0x04 : 0) | (hasInternet ? 0x08 : 0))
        ..u16(fuelUsableKm == null ? 0xffff : fuelUsableKm!.round().clamp(0, 65534))
        ..u16(fixAgeSec.clamp(0, 65535)))
      .done();

  static MeshPos? decode(Uint8List p) {
    final r = _R(p);
    if (r.u8() != MeshKind.pos) return null;
    final a = r.i32(), o = r.i32(), v = r.u16(), h = r.u16(), b = r.u8(), f = r.u8(), fu = r.u16(), age = r.u16();
    if (!r.ok) return null;
    return MeshPos(
      lat: a / 1e5,
      lng: o / 1e5,
      speedKmh: (v * 0.36 * 10).round() / 10,
      heading: h.toDouble(),
      batteryLevel: b & 0x7f,
      isCharging: b & 0x80 != 0,
      role: _roleName(f & 0x03),
      sosActive: f & 0x04 != 0,
      hasInternet: f & 0x08 != 0,
      fuelUsableKm: fu == 0xffff ? null : fu.toDouble(),
      fixAgeSec: age,
    );
  }
}

class MeshVoiceCodec {
  static const int opus = 1; // Round 8 opus1 frame payload ([len u16][packet]...)
  static const int adpcm = 2; // IMA ADPCM 4-bit (mesh_adpcm.dart), near neighbours only
  static const int pcm16 = 3;
}

/// One voice frame (live) or one chunk of a walkie-talkie clip.
class MeshVoice {
  const MeshVoice({
    required this.streamId,
    required this.frameSeq,
    required this.codec,
    required this.sampleRate,
    required this.payload,
    this.start = false,
    this.end = false,
    this.clip = false,
    this.lead = false,
    this.clipChunks = 0,
    this.clipDurationMs = 0,
    this.name = '',
  });

  final int streamId;
  final int frameSeq;
  final int codec;
  final int sampleRate;
  final bool start;
  final bool end;
  final bool clip;
  final bool lead;

  /// Clips: number of chunks in the clip (known when the clip is complete; 0 for live frames).
  final int clipChunks;
  final int clipDurationMs;

  /// Speaker's display name (first frame / every clip chunk) so the chip can say "Voice message from Ravi".
  final String name;
  final Uint8List payload;

  Uint8List encode() => (_W()
        ..u8(MeshKind.voice)
        ..u8((start ? 1 : 0) | (end ? 2 : 0) | (clip ? 4 : 0) | (lead ? 8 : 0))
        ..u16(streamId)
        ..u16(frameSeq)
        ..u8(codec)
        ..u8(sampleRate == 8000 ? 1 : 2)
        ..u16(clipChunks)
        ..u16(clipDurationMs)
        ..str(name, 32)
        ..bytes(payload))
      .done();

  static MeshVoice? decode(Uint8List p) {
    final r = _R(p);
    if (r.u8() != MeshKind.voice) return null;
    final f = r.u8(), sid = r.u16(), fs = r.u16(), codec = r.u8(), rate = r.u8(), chunks = r.u16(), dur = r.u16();
    final name = r.str();
    final payload = r.rest();
    if (!r.ok) return null;
    return MeshVoice(
      streamId: sid,
      frameSeq: fs,
      codec: codec,
      sampleRate: rate == 1 ? 8000 : 16000,
      start: f & 1 != 0,
      end: f & 2 != 0,
      clip: f & 4 != 0,
      lead: f & 8 != 0,
      clipChunks: chunks,
      clipDurationMs: dur,
      name: name,
      payload: Uint8List.fromList(payload),
    );
  }
}

/// "I am missing these chunks of a clip": riders holding them send them again (targeted repair instead of re-sending
/// whole clips to every new link).
class MeshClipNack {
  const MeshClipNack({required this.origin, required this.streamId, required this.total, required this.missing});
  final int origin;
  final int streamId;
  final int total;
  final List<int> missing;

  Uint8List encode() {
    final bits = Uint8List((total + 7) ~/ 8);
    for (final i in missing) {
      if (i >= 0 && i < total) bits[i >> 3] |= 1 << (i & 7);
    }
    return (_W()
          ..u8(MeshKind.clipNack)
          ..u32(origin)
          ..u16(streamId)
          ..u16(total)
          ..bytes(bits))
        .done();
  }

  static MeshClipNack? decode(Uint8List p) {
    final r = _R(p);
    if (r.u8() != MeshKind.clipNack) return null;
    final origin = r.u32(), sid = r.u16(), total = r.u16();
    final bits = r.rest();
    if (!r.ok || total == 0 || bits.length < (total + 7) ~/ 8) return null;
    return MeshClipNack(origin: origin, streamId: sid, total: total, missing: [for (var i = 0; i < total; i++) if (bits[i >> 3] & (1 << (i & 7)) != 0) i]);
  }
}

class MeshChat {
  const MeshChat(this.text);
  final String text;
  Uint8List encode() => (_W()
        ..u8(MeshKind.chat)
        ..str(text, 240))
      .done();
  static MeshChat? decode(Uint8List p) {
    final r = _R(p);
    if (r.u8() != MeshKind.chat) return null;
    final t = r.str();
    return r.ok ? MeshChat(t) : null;
  }
}

/// Capability bits (beacon and HELLO).
class MeshCaps {
  static const int codedPhy = 0x01;
  static const int extendedAdv = 0x02;
  static const int l2cap = 0x04;
  static const int internet = 0x08; // this phone has a healthy server link (it can bridge)
  static const int opusEnc = 0x10;
  static const int opusDec = 0x20;
  static const int lowBattery = 0x40;
  static const int lead = 0x80;

  static bool longRange(int caps) => caps & codedPhy != 0 && caps & extendedAdv != 0;
}

/// HELLO over a data link (UDP / L2CAP / GATT): who I am, what I can do, where I am in the convoy.
class MeshHello {
  const MeshHello({required this.caps, this.along10m, this.name = ''});
  final int caps;
  final int? along10m;
  final String name;

  Uint8List encode() => (_W()
        ..u8(MeshKind.hello)
        ..u8(caps)
        ..u16((along10m ?? -32768) & 0xffff)
        ..str(name, 32))
      .done();

  static MeshHello? decode(Uint8List p) {
    final r = _R(p);
    if (r.u8() != MeshKind.hello) return null;
    final caps = r.u8();
    final a = r.u16();
    final name = r.str();
    if (!r.ok) return null;
    final signed = a >= 0x8000 ? a - 0x10000 : a;
    return MeshHello(caps: caps, along10m: signed == -32768 ? null : signed, name: name);
  }
}

/// The 13-byte advertising beacon (fits a legacy scan response next to the 128-bit service UUID):
///   group tag u16 | rider short id u32 | seq u8 | caps u8 | L2CAP PSM u8 (0 = none) | MAC u32
/// The MAC is the first 4 bytes of AES(beaconKey, tag|rider|seq|caps|psm|time-slot), with the time slot = unix seconds / 60:
/// a beacon replayed more than a minute later does not verify. Outsiders cannot forge a member's beacon.
class MeshBeacon {
  const MeshBeacon({required this.groupTag, required this.rider, required this.seq, required this.caps, this.psm = 0});
  final int groupTag;
  final int rider;
  final int seq;
  final int caps;
  final int psm;

  static const int length = 13;

  static Uint8List _macInput(int tag, int rider, int seq, int caps, int psm, int slot) {
    final b = Uint8List(16);
    final bd = ByteData.sublistView(b);
    bd.setUint16(0, tag);
    bd.setUint32(2, rider);
    b[6] = seq & 0xff;
    b[7] = caps & 0xff;
    b[8] = psm & 0xff;
    bd.setUint32(9, slot);
    b[15] = 0xB1;
    return b;
  }

  Uint8List encode(MeshKeyring k, int nowSec) {
    final out = Uint8List(length);
    final bd = ByteData.sublistView(out);
    bd.setUint16(0, groupTag);
    bd.setUint32(2, rider);
    out[6] = seq & 0xff;
    out[7] = caps & 0xff;
    out[8] = psm & 0xff;
    final mac = k.beaconKey.encrypt16(_macInput(groupTag, rider, seq, caps, psm, nowSec ~/ 60));
    out.setRange(9, 13, mac);
    return out;
  }

  /// The beacon when it is ours and its MAC verifies for this minute or the one before / after.
  static MeshBeacon? decode(MeshKeyring k, Uint8List b, int nowSec) {
    if (b.length < length) return null;
    final bd = ByteData.sublistView(b);
    final tag = bd.getUint16(0);
    if (tag != k.groupTag) return null;
    final rider = bd.getUint32(2);
    final seq = b[6], caps = b[7], psm = b[8];
    for (final d in const [0, -1, 1]) {
      final mac = k.beaconKey.encrypt16(_macInput(tag, rider, seq, caps, psm, nowSec ~/ 60 + d));
      if (mac[0] == b[9] && mac[1] == b[10] && mac[2] == b[11] && mac[3] == b[12]) {
        return MeshBeacon(groupTag: tag, rider: rider, seq: seq, caps: caps, psm: psm);
      }
    }
    return null;
  }
}
