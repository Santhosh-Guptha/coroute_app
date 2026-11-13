// Round 10 rescue beacon: the near-ultrasonic locator DETECTOR on a responder's phone (pure Dart).
//
// Input: raw microphone samples at 48 kHz (or 44.1 kHz). The ride mic hub runs at 16 kHz for the
// siren detector and the intercom; while a rescue listener is attached it opens the mic at
// 48 kHz, hands these frames here and gives everyone else the same 16 kHz frames as before
// (lib/domain/rescue/decimator.dart). Nothing is recorded or kept.
//
// Method (cheap enough to run for hours on an old phone):
//  * every 5 ms "hop", Goertzel power at the 4 FSK tones of each enabled band and at 5 reference
//    frequencies between / beside them (the local noise floor). 18 Goertzels per 5 ms;
//  * after every hop, test whether a whole packet ended just now: 16 symbols of 8 hops (40 ms
//    tone) every 10 hops. The 4 sync symbols must each have the expected tone as the strongest by
//    [syncRatio] (3 dB) AND above the noise floor by [minSnr]; the 12 data symbols are read as the
//    strongest tone; the 24 bits must pass the CRC-8;
//  * neighbouring hop offsets of the same packet are merged (the best one wins).
// Engine, wind, road and handling noise are mostly below 5 kHz; what reaches 14..20 kHz is
// broadband (clicks, gusts): it lifts all tones AND the reference bins together, so neither the
// sync ratio nor the SNR test pass. A steady insect / whistle tone hits one bin only: the sync
// needs all four tones in a fixed order.
//
// One decoded packet is NOT a detection: [RescueBeaconTracker] needs [minPackets] packets with the
// same id within a window before it says "heard".
import 'dart:math' as math;
import 'dart:typed_data';

import 'proximity_trend.dart';
import 'rescue_acoustics.dart';

class BeaconPacket {
  final int id;
  final BeaconBand band;

  /// Mean tone-to-noise ratio of the packet's 16 symbols (dB, in one 200 Hz bin).
  final double snrDb;

  /// Stream time (s since the detector started) at the end of the packet.
  final double timeS;

  const BeaconPacket({required this.id, required this.band, required this.snrDb, required this.timeS});

  @override
  String toString() => 'BeaconPacket(${id.toRadixString(16)}, $band, ${snrDb.toStringAsFixed(1)} dB, ${timeS.toStringAsFixed(2)} s)';
}

class _Goertzel {
  _Goertzel(double f, int sampleRate) : coef = 2 * math.cos(2 * math.pi * f / sampleRate);
  final double coef;
}

class _BandState {
  _BandState(this.band, int sampleRate, int ring)
      : tones = [for (final f in BeaconBandSpec.of(band).tones) _Goertzel(f, sampleRate)],
        refs = [for (final f in BeaconBandSpec.of(band).noiseRefs) _Goertzel(f, sampleRate)],
        toneP = List.generate(4, (_) => Float64List(ring)),
        noiseP = Float64List(ring);

  final BeaconBand band;
  final List<_Goertzel> tones;
  final List<_Goertzel> refs;
  final List<Float64List> toneP;
  final Float64List noiseP;
  BeaconPacket? pending;
  int pendingStart = -1;
  double pendingScore = -1e9;
  int blockUntil = -1;
}

class RescueBeaconDetector {
  RescueBeaconDetector({
    required this.sampleRate,
    List<BeaconBand> bands = const [BeaconBand.high, BeaconBand.low],
    this.syncRatio = 2.0,
    this.minSnr = 2.5,
    Iterable<int> targets = const [],
    this.matchedMinDb = 3.0,
    this.matchedMinHits = 11,
  })  : hop = (sampleRate * 0.005).round(),
        _hopBuf = Float64List((sampleRate * 0.005).round()) {
    for (final b in bands) {
      _bands.add(_BandState(b, sampleRate, _ring));
    }
    _eps = hop * hop * 1e-13;
    setTargets(targets);
  }

  /// Known-id ("matched") detection: when the phone looks for a known rider, all 16 symbols of
  /// that rider's packet are known in advance, so the detector can test the whole pattern at once
  /// instead of reading symbol by symbol. About 3..6 dB more sensitive (longer range). A packet
  /// passes when, over the 16 symbols, the expected tone beats the mean of the other three by
  /// [matchedMinDb] on average and is the strongest in at least [matchedMinHits] symbols.
  final double matchedMinDb;
  final int matchedMinHits;
  final Map<int, List<int>> _targets = {};

  void setTargets(Iterable<int> ids) {
    _targets
      ..clear()
      ..addEntries([for (final id in ids) if (id > 0 && id <= 0xFFFF) MapEntry(id, BeaconFormat.symbolsFor(id))]);
  }

  final int sampleRate;

  /// Samples per 5 ms hop.
  final int hop;

  /// Sync symbols: expected tone / strongest other tone (power ratio).
  final double syncRatio;

  /// Sync symbols: expected tone / noise floor (power ratio).
  final double minSnr;

  static const int _ring = 256; // hops (1.28 s), more than one packet (158 hops)
  static const int _hopsPerSymbol = 10;
  static const int _toneHops = 8;
  static const int _packetHops = (BeaconFormat.symbols - 1) * _hopsPerSymbol + _toneHops; // 158

  final List<_BandState> _bands = [];
  final Float64List _hopBuf;
  int _fill = 0;
  int _hops = 0; // hops completed
  late final double _eps;

  /// Hops processed so far (for tests and timing).
  int get hopsProcessed => _hops;

  void reset() {
    _fill = 0;
    _hops = 0;
    for (final b in _bands) {
      for (final t in b.toneP) {
        t.fillRange(0, t.length, 0);
      }
      b.noiseP.fillRange(0, b.noiseP.length, 0);
      b.pending = null;
      b.pendingStart = -1;
      b.blockUntil = -1;
    }
  }

  /// PCM16 microphone samples. Returns the packets completed by these samples.
  List<BeaconPacket> addPcm16(Int16List samples) {
    final out = <BeaconPacket>[];
    for (var i = 0; i < samples.length; i++) {
      _hopBuf[_fill++] = samples[i] / 32768.0;
      if (_fill == hop) {
        _fill = 0;
        _processHop(out);
      }
    }
    return out;
  }

  /// Float samples (-1..1), e.g. from the lab.
  List<BeaconPacket> addFloat(List<double> samples) {
    final out = <BeaconPacket>[];
    for (var i = 0; i < samples.length; i++) {
      _hopBuf[_fill++] = samples[i];
      if (_fill == hop) {
        _fill = 0;
        _processHop(out);
      }
    }
    return out;
  }

  double _power(_Goertzel g) {
    var s1 = 0.0, s2 = 0.0;
    final c = g.coef;
    final buf = _hopBuf;
    for (var i = 0; i < buf.length; i++) {
      final s0 = buf[i] + c * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    return s1 * s1 + s2 * s2 - c * s1 * s2;
  }

  void _processHop(List<BeaconPacket> out) {
    final slot = _hops % _ring;
    for (final b in _bands) {
      for (var t = 0; t < 4; t++) {
        b.toneP[t][slot] = _power(b.tones[t]);
      }
      var n = 0.0;
      for (final r in b.refs) {
        n += _power(r);
      }
      b.noiseP[slot] = n / b.refs.length;
    }
    _hops++;
    final h = _hops - 1; // index of the hop just stored
    for (final b in _bands) {
      final s = h - _packetHops + 1;
      if (s >= 0 && s >= b.blockUntil) {
        final cand = _tryDecode(b, s) ?? _tryMatched(b, s);
        if (cand != null) {
          final (pkt, score) = cand;
          if (b.pending == null || score > b.pendingScore) {
            b.pending = pkt;
            b.pendingScore = score;
            b.pendingStart = s;
          }
        }
      }
      // Emit the best offset once no better neighbour came for 4 hops.
      if (b.pending != null && s - b.pendingStart > 4) {
        out.add(b.pending!);
        b.blockUntil = b.pendingStart + 120; // the next packet is at least 1 s later
        b.pending = null;
        b.pendingScore = -1e9;
      }
    }
  }

  (BeaconPacket, double)? _tryMatched(_BandState b, int start) {
    if (_targets.isEmpty) return null;
    // Symbol energies once, then each target's pattern.
    final e = List.generate(BeaconFormat.symbols, (_) => Float64List(4));
    final noise = Float64List(BeaconFormat.symbols);
    for (var k = 0; k < BeaconFormat.symbols; k++) {
      final s0 = start + k * _hopsPerSymbol;
      var n = 0.0;
      for (var j = 0; j < _toneHops; j++) {
        final slot = (s0 + j) % _ring;
        for (var t = 0; t < 4; t++) {
          e[k][t] += b.toneP[t][slot];
        }
        n += b.noiseP[slot];
      }
      noise[k] = math.max(n, _eps);
    }
    // Quick reject: the sync part must look right (expected tone strongest in 3 of 4).
    var syncHits = 0;
    for (var k = 0; k < BeaconFormat.sync.length; k++) {
      final x = BeaconFormat.sync[k];
      var best = true;
      for (var t = 0; t < 4; t++) {
        if (t != x && e[k][t] >= e[k][x]) best = false;
      }
      if (best) syncHits++;
    }
    if (syncHits < 3) return null;
    (BeaconPacket, double)? out;
    for (final entry in _targets.entries) {
      final sym = entry.value;
      var sumDb = 0.0, snrSum = 0.0;
      var hits = 0;
      for (var k = 0; k < BeaconFormat.symbols; k++) {
        final x = sym[k];
        var others = 0.0;
        var best = true;
        for (var t = 0; t < 4; t++) {
          if (t == x) continue;
          others += e[k][t];
          if (e[k][t] >= e[k][x]) best = false;
        }
        if (best) hits++;
        others = math.max(others / 3, _eps);
        sumDb += 10 * math.log(math.max(e[k][x], _eps) / others) / math.ln10;
        snrSum += 10 * math.log(math.max(e[k][x], _eps) / noise[k]) / math.ln10;
      }
      final meanDb = sumDb / BeaconFormat.symbols;
      final snr = snrSum / BeaconFormat.symbols;
      if (hits >= matchedMinHits && meanDb >= matchedMinDb && snr >= 1.0) {
        final endS = ((start + _packetHops) * hop) / sampleRate;
        // Scored a little below a full decode at the same offset, so a clean decode wins the merge.
        final score = snr - 0.5;
        if (out == null || score > out.$2) out = (BeaconPacket(id: entry.key, band: b.band, snrDb: snr, timeS: endS), score);
      }
    }
    return out;
  }

  (BeaconPacket, double)? _tryDecode(_BandState b, int start) {
    final data = <int>[];
    var snrSum = 0.0;
    for (var k = 0; k < BeaconFormat.symbols; k++) {
      final e = Float64List(4);
      var noise = 0.0;
      final s0 = start + k * _hopsPerSymbol;
      for (var j = 0; j < _toneHops; j++) {
        final slot = (s0 + j) % _ring;
        for (var t = 0; t < 4; t++) {
          e[t] += b.toneP[t][slot];
        }
        noise += b.noiseP[slot];
      }
      noise = math.max(noise, _eps);
      var best = 0;
      for (var t = 1; t < 4; t++) {
        if (e[t] > e[best]) best = t;
      }
      var second = 0.0;
      for (var t = 0; t < 4; t++) {
        if (t != best && e[t] > second) second = e[t];
      }
      if (k < BeaconFormat.sync.length) {
        if (best != BeaconFormat.sync[k]) return null;
        if (e[best] < syncRatio * second) return null;
        if (e[best] < minSnr * noise) return null;
      } else {
        data.add(best);
      }
      snrSum += 10 * math.log(e[best] / noise) / math.ln10;
    }
    final id = BeaconFormat.idFromData(data);
    if (id == null) return null;
    final snr = snrSum / BeaconFormat.symbols;
    final endS = ((start + _packetHops) * hop) / sampleRate;
    return (BeaconPacket(id: id, band: b.band, snrDb: snr, timeS: endS), snr);
  }
}

/// What the finder knows about one beacon it hears.
class BeaconLock {
  BeaconLock(this.id);

  final int id;
  final List<int> heardAt = [];
  final ProximityTrend trend = ProximityTrend(recentMs: 8000, previousMs: 12000, thresholdDb: 2.0);
  bool confirmed = false;
  int lastHeardMs = -1;
  BeaconBand? lastBand;

  double? get snrDb => trend.smoothed;
}

/// Turns decoded packets into a confirmed detection of ONE rider (false-positive guard) and a
/// strength reading with a hotter / colder trend.
class RescueBeaconTracker {
  RescueBeaconTracker({
    this.targetId,
    this.helpAnyone = false,
    this.minPackets = 2,
    this.windowMs = 12000,
    this.lostAfterMs = 20000,
  });

  /// The rider this phone is looking for (0 / null: none).
  int? targetId;

  /// "Help anyone": also lock on to other rescue ids (the rider chose it).
  bool helpAnyone;

  /// Packets with the same id needed within [windowMs] before it counts as heard.
  final int minPackets;
  final int windowMs;

  /// No packet for this long: not heard any more.
  final int lostAfterMs;

  final Map<int, BeaconLock> _locks = {};

  /// Ids heard that are not the target (shown as "another rescue beacon nearby").
  final Set<int> otherIds = {};

  /// Other riders' ids also tracked (every open SOS around me), without "help anyone".
  final Set<int> alsoAccept = {};

  bool accepts(int id) => helpAnyone || alsoAccept.contains(id) || (targetId != null && targetId != 0 && id == targetId);

  /// The confirmed lock of [id], or null.
  BeaconLock? lockFor(int id, int nowMs) {
    expire(nowMs);
    final l = _locks[id];
    return l != null && l.confirmed ? l : null;
  }

  void onPacket(BeaconPacket p, int nowMs) {
    if (!accepts(p.id)) {
      otherIds.add(p.id);
      return;
    }
    final lock = _locks.putIfAbsent(p.id, () => BeaconLock(p.id));
    lock.heardAt.add(nowMs);
    lock.heardAt.removeWhere((t) => t < nowMs - windowMs);
    if (lock.heardAt.length >= minPackets) lock.confirmed = true;
    if (lock.confirmed) lock.trend.add(nowMs, p.snrDb);
    lock.lastHeardMs = nowMs;
    lock.lastBand = p.band;
  }

  /// Drops locks not heard for [lostAfterMs] (they must be confirmed again).
  void expire(int nowMs) {
    _locks.removeWhere((_, l) => nowMs - l.lastHeardMs > lostAfterMs);
  }

  /// The confirmed lock of the target (or, with "help anyone", the strongest confirmed one).
  BeaconLock? best(int nowMs) {
    expire(nowMs);
    final t = targetId;
    if (t != null && t != 0) {
      final l = _locks[t];
      if (l != null && l.confirmed) return l;
    }
    if (!helpAnyone) return null;
    BeaconLock? out;
    for (final l in _locks.values) {
      if (!l.confirmed) continue;
      if (out == null || (l.snrDb ?? -99) > (out.snrDb ?? -99)) out = l;
    }
    return out;
  }

  void reset() {
    _locks.clear();
    otherIds.clear();
  }
}
