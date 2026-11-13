// Round 10 offline link: store-and-forward. Every rider keeps a bounded buffer of sealed frames worth carrying across a
// gap (SOS, alerts, the latest position of each rider, walkie-talkie clips, chat) and offers them again whenever a new
// link appears (epidemic spreading within the group). Its own SOS is resent on a back-off until ANYONE acknowledges it
// (another rider over the mesh, or the server through a bridge phone). Pure Dart, tested in
// test/mesh_store_forward_test.dart.
library;

import 'dart:typed_data';

import 'mesh_frame.dart';

class StoredFrame {
  StoredFrame({
    required this.id,
    required this.cls,
    required this.sealed,
    required this.storedAtMs,
    required this.expiresAtMs,
    required this.origin,
    this.key,
    this.own = false,
    this.sosClientId,
  });

  final String id;
  final MeshClass cls;
  final Uint8List sealed;
  final int storedAtMs;
  final int expiresAtMs;
  final int origin;

  /// Latest-only key (positions: one per rider; clips: one entry per chunk).
  final String? key;

  /// Originated by this phone.
  final bool own;

  /// For SOS frames: the SOS client id (acknowledgements refer to it).
  final String? sosClientId;

  bool acked = false;
  int txCount = 0;
  int lastTxAtMs = 0;
  int nextRetryAtMs = 0;

  /// Neighbours that were in range the last time this frame went out.
  Set<int> offeredTo = <int>{};

  int get bytes => sealed.length;
}

class StoreForwardConfig {
  const StoreForwardConfig({
    this.maxItems = 400,
    this.maxBytes = 640 * 1024,
    this.maxSos = 48,
    this.minOfferGapMs = 3000,
    this.maxOffersPerCall = 24,
    this.sosRetryMs = const [2000, 4000, 8000, 15000, 30000],
    this.sosRefreshMs = 20000,
    this.sosRefreshForMs = 10 * 60000,
  });

  final int maxItems;
  final int maxBytes;
  final int maxSos;

  /// The same frame is offered again at most this often (a burst of new links does not flood).
  final int minOfferGapMs;
  final int maxOffersPerCall;

  /// Own SOS resend back-off (the last value repeats until acknowledged).
  final List<int> sosRetryMs;

  /// Every rider carrying an SOS (anyone's) offers it again to the riders in range this often, for the first
  /// [sosRefreshForMs] after it was raised: a rider who lost the frame in the air while in range still gets it.
  final int sosRefreshMs;
  final int sosRefreshForMs;
}

/// How long each class is carried.
int storeLifetimeMs(MeshClass c) => switch (c) {
      MeshClass.sos => 6 * 3600 * 1000,
      MeshClass.alert => 10 * 60 * 1000,
      MeshClass.position => 2 * 60 * 1000,
      MeshClass.voice => 10 * 60 * 1000,
      MeshClass.chat => 30 * 60 * 1000,
      MeshClass.control => 0,
    };

class StoreForward {
  StoreForward({this.config = const StoreForwardConfig()});

  final StoreForwardConfig config;
  final Map<String, StoredFrame> _items = <String, StoredFrame>{};
  int _bytes = 0;
  int evicted = 0;

  int get length => _items.length;
  int get bytes => _bytes;
  Iterable<StoredFrame> get items => _items.values;
  StoredFrame? operator [](String id) => _items[id];

  /// Keeps a sealed frame. Returns false when it is not worth keeping (control, already expired, or already held).
  bool put(StoredFrame f, int nowMs) {
    if (f.cls == MeshClass.control || f.expiresAtMs <= nowMs) return false;
    if (_items.containsKey(f.id)) return false;
    if (f.key != null) {
      // Latest only: a newer position replaces the older one; an older (late) one is not kept.
      final old = _items.values.where((e) => e.key == f.key).toList();
      for (final o in old) {
        if (o.storedAtMs > f.storedAtMs && !f.own) return false;
        _remove(o.id);
      }
    }
    if (f.own && f.cls == MeshClass.sos) f.nextRetryAtMs = nowMs; // first send happens through the router itself
    _items[f.id] = f;
    _bytes += f.bytes;
    _enforce(nowMs);
    return _items.containsKey(f.id);
  }

  void _remove(String id) {
    final f = _items.remove(id);
    if (f != null) _bytes -= f.bytes;
  }

  void remove(String id) => _remove(id);

  /// An acknowledgement for the SOS [clientId] arrived: its resends stop (it is still carried for riders who have
  /// not heard it). Returns true when this phone held that SOS.
  bool ackSos(String clientId) {
    var hit = false;
    for (final f in _items.values) {
      if (f.cls == MeshClass.sos && f.sosClientId == clientId && !f.acked) {
        f.acked = true;
        hit = true;
      }
    }
    return hit;
  }

  bool isAcked(String clientId) => _items.values.any((f) => f.sosClientId == clientId && f.acked);

  /// Own SOS frames still waiting for an acknowledgement.
  List<StoredFrame> get unackedOwnSos => _items.values.where((f) => f.own && f.cls == MeshClass.sos && !f.acked).toList();

  /// The frames to put on the air now:
  ///  * own unacknowledged SOS on its back-off schedule (whether or not anyone is in range: a rider may be just out of
  ///    sight around the bend);
  ///  * anything not yet offered to a neighbour that is in range now (a new link: epidemic spreading), at most once
  ///    every [StoreForwardConfig.minOfferGapMs] per frame, most urgent first.
  List<StoredFrame> due(int nowMs, Set<int> neighbours) {
    _expire(nowMs);
    final out = <StoredFrame>[];
    for (final f in _items.values) {
      if (f.own && f.cls == MeshClass.sos && !f.acked && nowMs >= f.nextRetryAtMs) {
        out.add(f);
      }
    }
    if (neighbours.isNotEmpty) {
      final cands = _items.values
          .where((f) =>
              !out.contains(f) &&
              nowMs - f.lastTxAtMs >= config.minOfferGapMs &&
              (!f.offeredTo.containsAll(neighbours) ||
                  (f.cls == MeshClass.sos && nowMs - f.lastTxAtMs >= config.sosRefreshMs && nowMs - f.storedAtMs <= config.sosRefreshForMs)))
          .toList()
        ..sort((a, b) {
          final c = a.cls.index.compareTo(b.cls.index);
          return c != 0 ? c : b.storedAtMs.compareTo(a.storedAtMs);
        });
      for (final f in cands) {
        if (out.length >= config.maxOffersPerCall) break;
        out.add(f);
      }
    }
    for (final f in out) {
      f.txCount++;
      f.lastTxAtMs = nowMs;
      f.offeredTo = {...f.offeredTo, ...neighbours};
      if (f.own && f.cls == MeshClass.sos && !f.acked) {
        final steps = config.sosRetryMs;
        f.nextRetryAtMs = nowMs + steps[(f.txCount - 1).clamp(0, steps.length - 1)];
      }
    }
    return out;
  }

  /// A link to [id] (re)appeared: whatever it may have missed while away (or lost in the air while it was in range)
  /// is offered to it again.
  void forgetOffers(int id) {
    for (final f in _items.values) {
      if (f.offeredTo.contains(id)) f.offeredTo = {...f.offeredTo}..remove(id);
    }
  }

  /// Marks a frame as already offered to [neighbours] (it just went out through the router).
  void markSent(String id, Set<int> neighbours, int nowMs) {
    final f = _items[id];
    if (f == null) return;
    f.offeredTo = {...f.offeredTo, ...neighbours};
    f.lastTxAtMs = nowMs;
    if (f.own && f.cls == MeshClass.sos && !f.acked && f.txCount == 0) {
      f.txCount = 1;
      f.nextRetryAtMs = nowMs + config.sosRetryMs.first;
    }
  }

  void _expire(int nowMs) {
    final dead = _items.values.where((f) => f.expiresAtMs <= nowMs && !(f.own && f.cls == MeshClass.sos && !f.acked)).map((f) => f.id).toList();
    for (final id in dead) {
      _remove(id);
    }
  }

  /// Bounded storage: SOS is evicted last and only beyond its own cap (oldest acknowledged first); then chat, old
  /// positions, clips, alerts - oldest first within a class.
  void _enforce(int nowMs) {
    _expire(nowMs);
    final sos = _items.values.where((f) => f.cls == MeshClass.sos).toList();
    if (sos.length > config.maxSos) {
      sos.sort((a, b) {
        if (a.acked != b.acked) return a.acked ? -1 : 1;
        if (a.own != b.own) return a.own ? 1 : -1;
        return a.storedAtMs.compareTo(b.storedAtMs);
      });
      for (final f in sos.take(sos.length - config.maxSos)) {
        _remove(f.id);
        evicted++;
      }
    }
    const order = [MeshClass.chat, MeshClass.position, MeshClass.voice, MeshClass.alert];
    while (_items.length > config.maxItems || _bytes > config.maxBytes) {
      StoredFrame? victim;
      for (final c in order) {
        final list = _items.values.where((f) => f.cls == c).toList();
        if (list.isEmpty) continue;
        list.sort((a, b) => a.storedAtMs.compareTo(b.storedAtMs));
        victim = list.first;
        break;
      }
      if (victim == null) break; // only SOS left: never evicted for space
      _remove(victim.id);
      evicted++;
    }
  }

  void clear() {
    _items.clear();
    _bytes = 0;
  }
}
