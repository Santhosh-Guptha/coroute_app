import '../../data/models/rider_model.dart';
import '../garage/bike_type.dart';

/// 3.55 pillion seat: a pillion confirms whose bike they sit on (PILLION_SEAT {withUserId}); the
/// gateway links pillion → rider, tells everyone (PILLION_SEATED), and the rider may decline within
/// a minute or remove the pillion any time (PILLION_UNSEAT, PILLION_UNSEATED). Pure Dart, unit tested.
class PillionSeat {
  PillionSeat._();

  /// The rider may decline within this window (the gateway's PILLION_DECLINE_MS).
  static const Duration declineWindow = Duration(seconds: 60);

  static bool _isPillion(RiderModel r) => r.isCoRiding || r.vehicleNo.trim().toUpperCase() == 'PILLION';

  /// Riders I can sit behind: in this ride, not me, a bike of their own (not a pillion), no pillion
  /// yet (my own current seat counts as free). Sorted by name.
  static List<RiderModel> candidates(Map<String, RiderModel> riders, String myUserId) {
    final taken = <String>{
      for (final p in riders.values)
        if (p.isCoRiding && p.ridingWithUserId.isNotEmpty && p.userId != myUserId) p.ridingWithUserId,
    };
    final list = [
      for (final r in riders.values)
        if (r.userId != myUserId && !_isPillion(r) && !taken.contains(r.userId)) r,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// "Royal Enfield Classic 350 (Red)", "Classic 350", "Red bike" or "bike".
  static String bikeLine(RiderModel r) {
    final m = r.vehicleModel.trim();
    final c = r.vehicleColor.trim();
    if (m.isNotEmpty && c.isNotEmpty) return '$m ($c)';
    if (m.isNotEmpty) return m;
    final t = BikeType.parse(r.vehicleKind);
    if (c.isNotEmpty) return '$c ${t == null ? 'bike' : t.label.toLowerCase()}';
    return t == null ? 'bike' : t.label.toLowerCase();
  }

  static String _first(String name) {
    final n = name.trim();
    return n.isEmpty ? 'this rider' : n;
  }

  /// "You'll ride pillion on Asha's Royal Enfield Classic 350 (Red). Confirm?"
  static String confirmText(RiderModel rider) => "You'll ride pillion on ${_first(rider.name)}'s ${bikeLine(rider)}. Confirm?";

  /// The PILLION_SEAT message.
  static Map<String, dynamic> seatMessage(String riderUserId) => {'withUserId': riderUserId};

  /// The PILLION_UNSEAT message: no id = I get off; an id = I decline / remove my pillion.
  static Map<String, dynamic> unseatMessage([String? pillionUserId]) =>
      {if (pillionUserId != null && pillionUserId.isNotEmpty) 'userId': pillionUserId};

  /// True while the rider of the bike may still "Decline" (else "Remove pillion").
  static bool canDecline(RiderModel pillion, int nowMs) =>
      pillion.pillionSeatAt > 0 && nowMs - pillion.pillionSeatAt <= declineWindow.inMilliseconds;

  /// The pillion on [riderUserId]'s bike, or null.
  static RiderModel? pillionOn(Map<String, RiderModel> riders, String riderUserId) {
    for (final p in riders.values) {
      if (p.isCoRiding && p.ridingWithUserId == riderUserId && p.userId != riderUserId) return p;
    }
    return null;
  }

  /// A pillion who is not seated on a bike of this ride: they are asked to pick one (a pillion
  /// account, or a seat whose rider left).
  static bool needsSeat(RiderModel me, Map<String, RiderModel> riders) {
    if (me.isCoRiding) return !riders.containsKey(me.ridingWithUserId) || me.ridingWithUserId == me.userId;
    return me.vehicleNo.trim().toUpperCase() == 'PILLION';
  }
}

/// A seat offer on my bike that I may still decline (shown to the rider of the bike).
class PillionOffer {
  const PillionOffer({required this.pillionUserId, required this.pillionName, required this.declineByMs});
  final String pillionUserId;
  final String pillionName;
  final int declineByMs;

  String get _who => pillionName.trim().isEmpty ? 'A rider' : pillionName.trim();
  String get title => '$_who is riding pillion with you';
  String get message => 'Not right? Decline within a minute, or remove them later from their rider card.';
}

/// The card and spoken line for PILLION_SEATED / PILLION_UNSEATED (everyone gets one).
class PillionNotice {
  const PillionNotice({required this.title, this.message = '', this.speech, this.mine = false, this.pickAgain = false});
  final String title;
  final String message;
  final String? speech;

  /// About me (important tier).
  final bool mine;

  /// I am a pillion without a bike now: offer "Pick the bike".
  final bool pickAgain;

  static String _n(Object? m) {
    final s = m is Map ? (m['name']?.toString() ?? '').trim() : '';
    return s.isEmpty ? 'A rider' : s;
  }

  static String _id(Object? m) => m is Map ? (m['userId']?.toString() ?? '') : '';

  /// PILLION_SEATED {pillion:{userId,name}, rider:{userId,name,vehicleModel,vehicleColor,vehicleKind}, declineBy}.
  static PillionNotice? seated(Map<String, dynamic> e, {required String? myUserId}) {
    final p = e['pillion'], r = e['rider'];
    if (_id(p).isEmpty || _id(r).isEmpty) return null;
    final pn = _n(p), rn = _n(r);
    if (_id(p) == myUserId) {
      return PillionNotice(mine: true, title: 'You\'re riding pillion with $rn', message: 'Hold on. Your phone keeps its safety features on.',
          speech: 'You are riding pillion with $rn.');
    }
    if (_id(r) == myUserId) {
      return PillionNotice(mine: true, title: '$pn is riding pillion with you', speech: '$pn is riding pillion with you.');
    }
    return PillionNotice(title: '$pn is riding pillion with $rn', speech: '$pn is riding pillion with $rn.');
  }

  /// PILLION_UNSEATED {pillion, rider, reason: DECLINED | REMOVED | PILLION_LEFT | RIDER_LEFT | MOVED}.
  static PillionNotice? unseated(Map<String, dynamic> e, {required String? myUserId}) {
    final p = e['pillion'], r = e['rider'];
    final reason = e['reason']?.toString() ?? '';
    if (_id(p).isEmpty) return null;
    final pn = _n(p), rn = _n(r);
    final meP = _id(p) == myUserId, meR = _id(r) == myUserId;
    switch (reason) {
      case 'DECLINED':
      case 'REMOVED':
        if (meP) {
          return PillionNotice(mine: true, pickAgain: true, title: reason == 'DECLINED' ? '$rn declined you as pillion' : '$rn removed you as pillion',
              message: 'Pick the bike you ride on.', speech: reason == 'DECLINED' ? '$rn declined you as pillion. Pick the bike you ride on.' : null);
        }
        if (meR) return PillionNotice(title: '$pn is no longer your pillion');
        return null;
      case 'RIDER_LEFT':
        if (meP) {
          return PillionNotice(mine: true, pickAgain: true, title: '$rn left the ride', message: 'Pick the bike you ride on now.',
              speech: '$rn left the ride. Pick the bike you ride on.');
        }
        return null;
      case 'PILLION_LEFT':
        if (meR) return PillionNotice(title: '$pn is no longer riding pillion with you');
        return null;
      case 'MOVED':
        if (meR) return PillionNotice(title: '$pn moved to another bike');
        return null;
    }
    return null;
  }

  /// A refusal from the gateway about a seat (reason code), or null when not about the seat.
  static PillionNotice? refused(String? reason, String? message) {
    const reasons = {'BAD_PILLION', 'TARGET_PILLION', 'SEAT_TAKEN', 'HAS_PILLION', 'PILLION_RATE', 'NOT_SEATED', 'NOT_YOUR_PILLION'};
    if (reason == null || !reasons.contains(reason)) return null;
    return PillionNotice(title: 'Pillion seat not changed', message: (message ?? '').trim());
  }
}
