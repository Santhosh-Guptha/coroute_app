// Round 10 offline link: a simulated group ride for the mesh (QA harness; not used by the app at runtime). Ten (or N)
// MeshNodeEngine instances - the same code the phones run - ride a straight road spread over ~1 km. A simple radio
// model connects them:
//   * path loss: RSSI = -60 - 27 log10(d / 10 m) + 4 dB shadowing per frame (calibrated so the Coded PHY median range
//     is ~390 m and 1M PHY ~150 m: the "200-600 m per hop between bikes" in docs/features_355/offline_long_range_link.md);
//   * reception: logistic around the sensitivity (-103 dBm Coded S8, -94 dBm 1M);
//   * airtime: each phone sends one frame at a time at the link's usable rate, plus 2-12 ms of processing;
//   * a reception that overlaps another one from a different sender is lost with probability [MeshSimConfig.collisionLoss].
// Mobility: everyone rides at ~60 km/h with small speed noise; "gap events" stop a rider for 15-45 s (fuel, lights,
// a photo) and then let them catch up 6 m/s faster, so links break and heal. Honest limits: it is broadcast-only (the
// phones use L2CAP/GATT links to <=4 neighbours, which removes most collisions but adds connection set-up time), it is
// a straight road (no terrain, no bends blocking line of sight), and there is no interference from other 2.4 GHz users.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'mesh_frame.dart';
import 'mesh_messages.dart';
import 'mesh_node.dart';
import 'mesh_router.dart';
import 'mesh_voice.dart';

class MeshSimConfig {
  const MeshSimConfig({
    this.riders = 10,
    this.lineM = 1000,
    this.speedMps = 16.7,
    this.durationMs = 600000,
    this.seed = 1,
    this.coded = true,
    this.gapEventsPerMin = 0.15,
    this.collisionLoss = 0.1,
    this.positionEveryMs = 2000,
    this.helloEveryMs = 1000,
    this.sosAtMs = const [60000, 200000, 340000, 480000],
    this.clipAtMs = const [100000, 250000, 400000, 520000],
    this.liveTalkAtMs = 300000,
    this.liveTalkMs = 20000,
    this.clipMs = 10000,
  });

  final int riders;
  final double lineM;
  final double speedMps;
  final int durationMs;
  final int seed;
  final bool coded;
  final double gapEventsPerMin;
  final double collisionLoss;
  final int positionEveryMs;
  final int helloEveryMs;
  final List<int> sosAtMs;
  final List<int> clipAtMs;
  final int? liveTalkAtMs;
  final int liveTalkMs;
  final int clipMs;

  int get linkBytesPerSec => coded ? 6000 : 25000;
  double get sensitivity => coded ? -103 : -94;
}

class _Rider {
  _Rider(this.index, this.slot, this.node);
  final int index;
  final double slot; // offset behind the lead (m)
  final MeshNodeEngine node;
  double x = 0;
  double speed = 0;
  int stoppedUntil = 0;
  bool catchingUp = false;
  int radioFreeAt = 0;
  final List<(int, int)> rxBusy = <(int, int)>[];
}

class MeshSimLatency {
  final List<double> values = <double>[];
  int expected = 0;
  void add(double v) => values.add(v);
  double get deliveryRate => expected == 0 ? 1 : values.length / expected;
  double pct(double p) {
    if (values.isEmpty) return double.nan;
    final s = List.of(values)..sort();
    return s[((s.length - 1) * p).round()];
  }

  void merge(MeshSimLatency o) {
    values.addAll(o.values);
    expected += o.expected;
  }

  String fmt(String unit) => '${(deliveryRate * 100).toStringAsFixed(1)} % delivered, p50 ${pct(0.5).toStringAsFixed(0)} $unit, p95 ${pct(0.95).toStringAsFixed(0)} $unit';
}

class MeshSimResult {
  final MeshSimLatency sos = MeshSimLatency(); // per (SOS, receiving rider), ms
  final MeshSimLatency sosAck = MeshSimLatency(); // per SOS: origin got an acknowledgement, ms
  final MeshSimLatency positions = MeshSimLatency(); // per (fix, rider) within 10 s, ms
  final MeshSimLatency clips = MeshSimLatency(); // per (clip, rider), complete, ms after the clip ended
  final MeshSimLatency liveVoice = MeshSimLatency(); // per (frame, rider) within 450 ms, ms
  int framesSent = 0;
  int bytesSent = 0;
  int relayed = 0;
  int suppressed = 0;
  int duplicates = 0;
  int maxHops = 0;
  double airtimeShareMax = 0;

  void merge(MeshSimResult o) {
    sos.merge(o.sos);
    sosAck.merge(o.sosAck);
    positions.merge(o.positions);
    clips.merge(o.clips);
    liveVoice.merge(o.liveVoice);
    framesSent += o.framesSent;
    bytesSent += o.bytesSent;
    relayed += o.relayed;
    suppressed += o.suppressed;
    duplicates += o.duplicates;
    maxHops = math.max(maxHops, o.maxHops);
    airtimeShareMax = math.max(airtimeShareMax, o.airtimeShareMax);
  }
}

class MeshSim {
  MeshSim(this.config) : _rnd = math.Random(config.seed);

  final MeshSimConfig config;
  final math.Random _rnd;
  static const int t0 = 1800000000000;
  static const double baseLat = 17.0;
  static const double baseLng = 78.0;
  int now = t0;
  late final List<_Rider> _riders;
  final List<(int, int, Uint8List, int)> _inFlight = <(int, int, Uint8List, int)>[]; // (deliverAt, to, bytes, from)

  double _gauss() {
    final u1 = math.max(1e-12, _rnd.nextDouble()), u2 = _rnd.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  double rssiAt(double d) => -60 - 27 * math.log(math.max(d, 1) / 10) / math.ln10;

  ({double lat, double lng}) _posOf(_Rider r) => (lat: baseLat, lng: baseLng + r.x / (111320 * math.cos(baseLat * math.pi / 180)));

  MeshSimResult run() {
    final key = Uint8List.fromList(List.generate(32, (i) => (i * 13 + config.seed) & 0xff));
    final keyring = MeshKeyring(key);
    final res = MeshSimResult();
    final spacing = config.lineM / math.max(1, config.riders - 1);
    _riders = [];
    for (var i = 0; i < config.riders; i++) {
      late _Rider r;
      final node = MeshNodeEngine(
        keyring: keyring,
        myId: 1000 + i,
        boot: _rnd.nextInt(1 << 31),
        transmit: (b, c) => _send(r, b, res),
        clockMs: () => now,
        random: math.Random(config.seed * 100 + i),
        myName: 'R$i',
        config: MeshRouterConfig(linkBytesPerSec: config.linkBytesPerSec),
      );
      r = _Rider(i, i * spacing, node)
        ..x = -i * spacing
        ..speed = config.speedMps;
      _riders.add(r);
    }

    // Measurement hooks.
    final posSent = <String, int>{}; // "origin:seq" -> sent time
    final sosSent = <String, (int, int)>{}; // clientId -> (time, origin index)
    final clipSent = <int, int>{}; // streamId*100 + origin -> time clip ended
    final liveSent = <int, int>{}; // frameSeq -> time
    for (final r in _riders) {
      r.node.onPosition = (origin, p, f) {
        final t = posSent['$origin:${p.fixAgeSec}:${f.originTimeSec}'];
        if (t != null && now - t <= 10000) res.positions.add((now - t).toDouble());
        res.maxHops = math.max(res.maxHops, f.hops);
      };
      final seenSos = <String>{};
      r.node.onSos = (origin, s, f) {
        final e = sosSent[s.clientId];
        if (e != null && seenSos.add(s.clientId)) res.sos.add((now - e.$1).toDouble());
      };
      final seenAck = <String>{};
      r.node.onSosAck = (a, f) {
        if (a.target != r.node.myId) return;
        final e = sosSent[a.clientId];
        if (e != null && seenAck.add(a.clientId)) res.sosAck.add((now - e.$1).toDouble());
      };
      r.node.onClip = (clip) {
        final t = clipSent[clip.streamId * 100 + clip.origin - 1000];
        if (t != null && clip.complete) res.clips.add((now - t).toDouble());
      };
      r.node.onLiveVoice = (origin, v, f) {
        final t = liveSent[v.frameSeq];
        if (t != null && now - t <= MeshVoicePolicy.liveMaxLatencyMs) res.liveVoice.add((now - t).toDouble());
      };
    }

    final sosQueue = List.of(config.sosAtMs);
    final clipQueue = List.of(config.clipAtMs);
    var nextPos = 1000, nextHello = 0;
    final clipRecs = <_Rider, (ClipRecorder, int, int)>{};
    var liveFrame = 0;
    const step = 10;
    for (var t = 0; t < config.durationMs; t += step) {
      now = t0 + t;
      _move(step);
      for (final r in _riders) {
        r.node.myPosition = _posOf(r);
      }
      // Deliveries due.
      if (_inFlight.isNotEmpty) {
        final due = _inFlight.where((e) => e.$1 <= now).toList();
        _inFlight.removeWhere((e) => e.$1 <= now);
        for (final d in due) {
          final to = _riders[d.$2];
          final from = _riders[d.$4];
          final dist = (to.x - from.x).abs();
          to.node.onRadioFrame(d.$3, rssi: (rssiAt(dist) + _gauss() * 2).round());
        }
      }
      if (t >= nextHello) {
        nextHello += config.helloEveryMs;
        for (final r in _riders) {
          r.node.sendHello();
        }
      }
      if (t >= nextPos) {
        nextPos += config.positionEveryMs;
        for (final r in _riders) {
          final p = _posOf(r);
          r.node.sendPosition(MeshPos(lat: p.lat, lng: p.lng, speedKmh: r.speed * 3.6, heading: 90, role: r.index == 0 ? 'LEAD' : 'PACK'));
          posSent['${r.node.myId}:0:${now ~/ 1000}'] = now;
          res.positions.expected += config.riders - 1;
        }
      }
      if (sosQueue.isNotEmpty && t >= sosQueue.first) {
        sosQueue.removeAt(0);
        final r = _riders[_rnd.nextInt(_riders.length)];
        final p = _posOf(r);
        final cid = 'sim-${r.index}-$t';
        sosSent[cid] = (now, r.index);
        res.sos.expected += config.riders - 1;
        res.sosAck.expected += 1;
        r.node.sendSos(MeshSos(clientId: cid, alertType: 'CRASH', lat: p.lat, lng: p.lng, occurredAtMs: now, auto: true));
      }
      if (clipQueue.isNotEmpty && t >= clipQueue.first) {
        clipQueue.removeAt(0);
        final r = _riders[_rnd.nextInt(_riders.length)];
        clipRecs[r] = (ClipRecorder(codec: MeshVoiceCodec.opus, sampleRate: 16000, frameMs: 40), now, r.node.newStreamId());
      }
      // Recording clips: one ~64-byte Opus frame (12 kbit/s, 40 ms) every 40 ms.
      for (final e in clipRecs.entries.toList()) {
        final (rec, started, sid) = e.value;
        if (t % 40 == 0) rec.add(Uint8List(60 + _rnd.nextInt(8)));
        if (now - started >= config.clipMs) {
          clipRecs.remove(e.key);
          e.key.node.sendClip(rec, streamId: sid);
          clipSent[sid * 100 + e.key.index] = now;
          res.clips.expected += config.riders - 1;
        }
      }
      final lt = config.liveTalkAtMs;
      if (lt != null && t >= lt && t < lt + config.liveTalkMs && t % MeshVoicePolicy.liveFrameMs == 0) {
        final r = _riders[0];
        liveFrame++;
        liveSent[liveFrame] = now;
        res.liveVoice.expected += config.riders - 1;
        // 80 ms of Opus at 12 kbit/s = 120 bytes + 2 x 2 bytes of packet lengths.
        r.node.sendLiveVoice(MeshVoice(streamId: 1, frameSeq: liveFrame, codec: MeshVoiceCodec.opus, sampleRate: 16000, payload: Uint8List(124), start: liveFrame == 1));
      }
      for (final r in _riders) {
        r.node.tick();
      }
    }
    for (final r in _riders) {
      final s = r.node.router.stats;
      res.relayed += s.relayed;
      res.suppressed += s.suppressed;
      res.duplicates += s.duplicates;
      for (final c in MeshClass.values) {
        res.framesSent += s.txByClass[c]!;
        res.bytesSent += s.txBytesByClass[c]!;
      }
      final share = s.txBytesByClass.values.fold<int>(0, (a, b) => a + b) / (config.durationMs / 1000) / config.linkBytesPerSec;
      res.airtimeShareMax = math.max(res.airtimeShareMax, share);
    }
    return res;
  }

  void _move(int stepMs) {
    final dt = stepMs / 1000.0;
    final lead = _riders.first;
    for (final r in _riders) {
      if (now < r.stoppedUntil) continue;
      if (r.index > 0 && _rnd.nextDouble() < config.gapEventsPerMin * dt / 60) {
        r.stoppedUntil = now + 15000 + _rnd.nextInt(30000);
        r.catchingUp = true;
        continue;
      }
      var v = config.speedMps + _gauss() * 0.3;
      if (r.index > 0) {
        final want = lead.x - r.slot;
        if (r.catchingUp) {
          v = config.speedMps + 6;
          if (r.x >= want) r.catchingUp = false;
        } else {
          v += (want - r.x) * 0.02; // hold the slot loosely
        }
      }
      r.speed = math.max(0, v);
      r.x += r.speed * dt;
    }
  }

  void _send(_Rider from, Uint8List bytes, MeshSimResult res) {
    final start = math.max(now, from.radioFreeAt);
    final air = (bytes.length / config.linkBytesPerSec * 1000).ceil();
    from.radioFreeAt = start + air;
    for (final to in _riders) {
      if (identical(to, from)) continue;
      final d = (to.x - from.x).abs();
      final rssi = rssiAt(d) + _gauss() * 4;
      final prr = 1 / (1 + math.exp(-(rssi - config.sensitivity) / 1.5));
      if (_rnd.nextDouble() > prr) continue;
      final at = start + air + 2 + _rnd.nextInt(10);
      final overlap = to.rxBusy.any((b) => b.$1 < at && b.$2 > start);
      to.rxBusy.removeWhere((b) => b.$2 < now - 1000);
      to.rxBusy.add((start, at));
      if (overlap && _rnd.nextDouble() < config.collisionLoss) continue;
      _inFlight.add((at, to.index, bytes, from.index));
    }
  }
}
