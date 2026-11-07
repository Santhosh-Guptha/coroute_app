import '../../data/models/rider_model.dart';

/// 3.55 bike / pillion swap: two riders exchange bikes for the rest of the ride, or a rider and
/// their pillion change places. Pure: no Flutter, no I/O. The gateway decides (only the asked
/// rider answers, within 2 minutes) and sends RIDER_UPDATE for both plus SWAP_DONE.
enum SwapKind {
  bikes('BIKES'),
  pillion('PILLION');

  const SwapKind(this.wire);
  final String wire;

  static SwapKind? fromWire(Object? v) {
    final s = v?.toString().toUpperCase();
    for (final k in SwapKind.values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

/// Who may ask whom.
class SwapRules {
  SwapRules._();

  /// True when one of the two rides pillion with the other.
  static bool paired(RiderModel a, RiderModel b) =>
      (a.isCoRiding && a.ridingWithUserId == b.userId) || (b.isCoRiding && b.ridingWithUserId == a.userId);

  /// "Swap bikes": any other rider, when neither of us is a pillion (a pillion has no bike).
  static bool canSwapBikes(RiderModel me, RiderModel other) =>
      me.userId != other.userId && !me.isCoRiding && !other.isCoRiding;

  /// "Swap rider and pillion": only my own rider or pillion.
  static bool canSwapPillion(RiderModel me, RiderModel other) => me.userId != other.userId && paired(me, other);
}

/// A swap another rider asked me for (SWAP_ASK), until I answer or it expires.
class SwapAsk {
  const SwapAsk({required this.requestId, required this.fromUserId, required this.fromName, required this.kind});
  final String requestId;
  final String fromUserId;
  final String fromName;
  final SwapKind kind;

  /// How long the phone shows it (the gateway gives 2 minutes; a little less here for the round trip).
  static const Duration showFor = Duration(seconds: 115);

  static SwapAsk? fromWire(Map<String, dynamic> e) {
    final id = e['requestId']?.toString() ?? '';
    final from = e['fromUserId']?.toString() ?? '';
    final kind = SwapKind.fromWire(e['kind']);
    if (id.isEmpty || from.isEmpty || kind == null) return null;
    return SwapAsk(requestId: id, fromUserId: from, fromName: e['fromName']?.toString() ?? '', kind: kind);
  }

  String get _who => fromName.trim().isEmpty ? 'A rider' : fromName.trim();

  String get title => switch (kind) {
        SwapKind.bikes => '$_who wants to swap bikes with you',
        SwapKind.pillion => '$_who wants to change places: rider and pillion',
      };

  String get message => switch (kind) {
        SwapKind.bikes => 'You would ride each other\'s bike for the rest of this ride.',
        SwapKind.pillion => 'One of you rides, the other sits pillion. Stop safely first.',
      };

  String get speech => switch (kind) {
        SwapKind.bikes => '$_who wants to swap bikes with you. Accept or decline on the screen.',
        SwapKind.pillion => '$_who wants to change places with you. Accept or decline on the screen.',
      };
}

/// A short card (and the spoken line) about a swap.
class SwapNotice {
  const SwapNotice({required this.title, this.message = '', this.speech, this.mine = false});
  final String title;
  final String message;

  /// Said once when not null.
  final String? speech;

  /// About me (important tier), else normal.
  final bool mine;

  /// SWAP_DONE: {kind, a:{userId,name,vehicleNo}, b:{...}}. Null when malformed.
  static SwapNotice? done(Map<String, dynamic> e, {required String? myUserId}) {
    final kind = SwapKind.fromWire(e['kind']);
    final a = e['a'], b = e['b'];
    if (kind == null || a is! Map || b is! Map) return null;
    String s(Map m, String k) => m[k]?.toString() ?? '';
    final meIsA = s(a, 'userId') == myUserId, meIsB = s(b, 'userId') == myUserId;
    final me = meIsA ? a : (meIsB ? b : null);
    final other = meIsA ? b : a;
    final otherName = s(other, 'name').trim().isEmpty ? 'the other rider' : s(other, 'name').trim();
    if (me == null) {
      final an = s(a, 'name').trim(), bn = s(b, 'name').trim();
      return SwapNotice(
        title: kind == SwapKind.bikes ? '$an and $bn swapped bikes' : '$an and $bn changed places',
        message: kind == SwapKind.bikes ? 'Look for them on their new bikes.' : '',
      );
    }
    final plate = s(me, 'vehicleNo').trim();
    if (kind == SwapKind.pillion && plate.toUpperCase() == 'PILLION') {
      return SwapNotice(
        mine: true,
        title: 'You now ride pillion with $otherName',
        message: 'Hold on and enjoy the ride.',
        speech: 'Swap done. You now ride pillion with $otherName.',
      );
    }
    // "fuel" is avoided in this line: the cockpit keeps fuel words out of its top slot.
    return SwapNotice(
      mine: true,
      title: plate.isEmpty ? 'Swap done: you now ride $otherName\'s bike' : 'You\'re now riding $plate',
      message: 'Check the tank, mirrors and brakes before you ride off.',
      speech: plate.isEmpty ? 'Swap done. Check the bike before you ride off.' : 'Swap done. You are now riding $plate. Check the bike before you ride off.',
    );
  }

  /// SWAP_RESULT accepted:false (declined, or no answer in time).
  static SwapNotice declined({required String name, required SwapKind? kind, required bool expired}) {
    final who = name.trim().isEmpty ? 'The rider' : name.trim();
    final what = kind == SwapKind.pillion ? 'changing places' : 'the bike swap';
    return SwapNotice(
      title: expired ? 'No answer from $who about $what' : '$who declined $what',
      message: expired ? 'You can ask again when you stop.' : '',
    );
  }

  /// Asked (shown until the answer comes).
  static SwapNotice asked({required String name, required SwapKind kind}) {
    final who = name.trim().isEmpty ? 'the rider' : name.trim();
    return SwapNotice(
      title: kind == SwapKind.bikes ? 'Asked $who to swap bikes' : 'Asked $who to change places',
      message: 'Waiting for their answer.',
    );
  }

  /// A refusal from the gateway (reason code of the ERROR), or null when not about swaps.
  static SwapNotice? refused(String? reason, String? message) {
    const reasons = {'SWAP_PENDING', 'SWAP_EXPIRED', 'SWAP_RATE', 'NOT_PAIRED', 'PILLION_RIDER', 'BAD_SWAP', 'NOT_SWAP_TARGET'};
    if (reason == null || !reasons.contains(reason)) return null;
    return SwapNotice(title: 'Swap not possible', message: (message ?? '').trim());
  }
}
