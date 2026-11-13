import 'dart:async';

/// What a frame is, for the order in which a phone handles frames that wait together.
enum FrameLane {
  /// An alert or an emergency event (ALERT, SOS updates, crash / rider-down reports, WAIT).
  alert,

  /// Rider positions (RIDER_UPDATE, RIDER_UPDATES): the newest matter, a few ms of delay do not.
  position,

  /// Everything else (SNAPSHOT, chat, roles, route...): strictly in arrival order.
  ordered,
}

/// Inbound frame order on the phone (round 7; pure).
///
/// Small frames with nothing waiting are handled at once, exactly as before (no added delay).
/// A BIG frame (a snapshot of a large group, a long position batch) is decoded off the UI
/// thread by [decodeBig]; frames that arrive meanwhile wait. When the decoder returns:
///  * alert frames are delivered FIRST, ahead of waiting position frames, so the alert banner is
///    shown before any map work;
///  * an alert never jumps over an `ordered` frame (a snapshot replaces the alert list: an alert
///    applied before the snapshot it followed would be lost), so order is kept across those;
///  * position frames keep their own order.
class InboundFrameSequencer<T> {
  InboundFrameSequencer({required this.laneOfType, required this.decodeSmall, required this.decodeBig, required this.deliver, this.bigBytes = 48 * 1024, this.typeOf = defaultTypeOf});

  /// Frame type -> lane.
  final FrameLane Function(String type) laneOfType;

  /// Decodes on this thread (small frames).
  final T? Function(String raw) decodeSmall;

  /// Decodes away from the UI thread (big frames). A failure delivers nothing.
  final Future<T?> Function(String raw) decodeBig;
  final void Function(T frame) deliver;
  final int bigBytes;

  /// Reads the frame type from the first bytes of the raw text without decoding it.
  final String Function(String raw) typeOf;

  final List<_Waiting<T>> _waiting = <_Waiting<T>>[];
  bool _busy = false;

  /// Big frames decoded off-thread so far, and alerts that overtook positions (diagnostics).
  int bigDecoded = 0, overtakes = 0;

  bool get idle => !_busy && _waiting.isEmpty;

  static final RegExp _type = RegExp(r'"type"\s*:\s*"([A-Z_0-9]{1,40})"');

  /// The gateway writes "type" first; only the head of the text is searched.
  static String defaultTypeOf(String raw) {
    final head = raw.length > 200 ? raw.substring(0, 200) : raw;
    return _type.firstMatch(head)?.group(1) ?? '';
  }

  /// A text frame from the socket.
  void add(String raw) {
    final lane = laneOfType(typeOf(raw));
    final big = raw.length >= bigBytes;
    if (!_busy && _waiting.isEmpty && !big) {
      final f = decodeSmall(raw);
      if (f != null) deliver(f);
      return;
    }
    _waiting.add(_Waiting<T>(raw, lane, big));
    if (!_busy) unawaited(_drain());
  }

  /// Drops what waits (the socket closed, the ride ended).
  void clear() => _waiting.clear();

  Future<void> _drain() async {
    _busy = true;
    try {
      while (_waiting.isNotEmpty) {
        final i = _pick();
        final w = _waiting.removeAt(i);
        if (i > 0) overtakes++;
        T? f;
        if (w.big) {
          try {
            f = await decodeBig(w.raw);
            bigDecoded++;
          } catch (_) {
            f = null;
          }
        } else {
          f = decodeSmall(w.raw);
        }
        if (f != null) deliver(f);
      }
    } finally {
      _busy = false;
    }
  }

  /// The next frame: the first alert that has only position frames in front of it, else the head.
  int _pick() {
    for (var i = 0; i < _waiting.length; i++) {
      final l = _waiting[i].lane;
      if (l == FrameLane.alert) return i;
      if (l == FrameLane.ordered) break;
    }
    return 0;
  }
}

class _Waiting<T> {
  _Waiting(this.raw, this.lane, this.big);
  final String raw;
  final FrameLane lane;
  final bool big;
}
