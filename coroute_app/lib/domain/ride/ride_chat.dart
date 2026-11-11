// 3.55 owner decision "Ride chat, simple action buttons instead of heavy taps".
//
// * One always-visible Chat button on the cockpit (unread badge) opens a compact sheet: recent
//   messages and a row of big one-tap quick actions (Fuel, Break, Wait for me, I'm OK, Slow down,
//   Regroup here, On my way, Arrived; the order can be changed).
// * While moving (RideTapGate: 8 km/h and more) typing is hidden: quick actions only. A pillion can
//   always type.
// * Incoming: a quick action is spoken in one short line ("Kiran: fuel stop"); a text gets a banner
//   and is spoken only when short or when stopped. Each message once (NoticeDedupe 'CHAT:<id>').
// * Blocked / hidden riders' messages are not shown, counted or spoken.
//
// Pure Dart: no Flutter (icons live in the sheet), no I/O, no timers (test/ride_chat_test.dart).

import 'ride_tap_gate.dart';

/// One quick action: [id] (stable, used for the saved order), the 1-2 word chip [label], the chat
/// [text] sent to the group, the gateway [cardType] (max 24 characters) and the short [spoken] words.
class RideQuickAction {
  final String id;
  final String label;
  final String text;
  final String cardType;
  final String spoken;

  /// "Wait for me" asks the group to wait (a timed request the gateway also posts in the chat).
  final bool isWait;

  const RideQuickAction({
    required this.id,
    required this.label,
    required this.text,
    required this.cardType,
    required this.spoken,
    this.isWait = false,
  });
}

class RideChat {
  RideChat._();

  /// The quick actions, in the default order.
  static const List<RideQuickAction> actions = [
    RideQuickAction(id: 'fuel', label: 'Fuel', text: 'Fuel stop', cardType: 'FUEL', spoken: 'fuel stop'),
    RideQuickAction(id: 'break', label: 'Break', text: 'Taking a break', cardType: 'BREAK', spoken: 'break'),
    RideQuickAction(id: 'wait', label: 'Wait for me', text: 'Wait for me', cardType: 'WAIT_2MIN', spoken: 'wait for me', isWait: true),
    RideQuickAction(id: 'ok', label: "I'm OK", text: "I'm OK", cardType: 'OK', spoken: "I'm OK"),
    RideQuickAction(id: 'slow', label: 'Slow down', text: 'Slow down', cardType: 'SLOW_DOWN', spoken: 'slow down'),
    RideQuickAction(id: 'regroup', label: 'Regroup here', text: 'Regroup here', cardType: 'REGROUP', spoken: 'regroup here'),
    RideQuickAction(id: 'onmyway', label: 'On my way', text: 'On my way', cardType: 'ON_MY_WAY', spoken: 'on my way'),
    RideQuickAction(id: 'arrived', label: 'Arrived', text: 'Arrived', cardType: 'ARRIVED', spoken: 'arrived'),
  ];

  /// Spoken words for card types sent by older apps and the helmet hotwords.
  static const Map<String, String> _legacySpoken = {
    'MECHANICAL': 'bike problem',
    'HAZARD': 'road hazard ahead',
  };

  /// A text longer than this is not spoken while moving (banner only).
  static const int shortSpokenChars = 40;

  /// The longest text ever spoken (longer texts: "Kiran sent a message").
  static const int maxSpokenChars = 120;

  /// Message text limit in the app (the gateway keeps 500).
  static const int maxTextChars = 300;

  static RideQuickAction? byId(String id) {
    for (final a in actions) {
      if (a.id == id) return a;
    }
    return null;
  }

  static RideQuickAction? byCardType(String cardType) {
    for (final a in actions) {
      if (a.cardType == cardType) return a;
    }
    return null;
  }

  /// The actions in the rider's saved order: unknown ids are dropped, duplicates kept once, and
  /// actions missing from the saved list follow in the default order.
  static List<RideQuickAction> ordered(List<String>? savedIds) {
    final out = <RideQuickAction>[];
    final seen = <String>{};
    for (final id in savedIds ?? const <String>[]) {
      final a = byId(id);
      if (a != null && seen.add(a.id)) out.add(a);
    }
    for (final a in actions) {
      if (seen.add(a.id)) out.add(a);
    }
    return out;
  }

  /// [ids] with [id] moved one place earlier ([up]) or later; unchanged at the ends.
  static List<String> move(List<String> ids, String id, {required bool up}) {
    final list = List<String>.from(ids);
    final i = list.indexOf(id);
    final j = up ? i - 1 : i + 1;
    if (i < 0 || j < 0 || j >= list.length) return list;
    list[i] = list[j];
    list[j] = id;
    return list;
  }

  /// Typing is shown: stopped, or riding pillion. While moving only quick actions.
  static bool canType(RideTapGate gate) => gate.canTap;

  /// The same rule from a single sample (no hysteresis), for places without a gate.
  static bool canTypeAt({required double speedKmh, bool passenger = false}) =>
      passenger || !(speedKmh.isFinite && speedKmh >= RideTapGate.movingKmh);

  /// First name for spoken lines ("Kiran Kumar" -> "Kiran").
  static String firstName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'A rider';
    return n.split(RegExp(r'\s+')).first;
  }

  /// The spoken line for a quick card ("Kiran: fuel stop"), or null when it is not a quick card.
  static String? quickSpoken({required String senderName, required String cardType, required String text}) {
    final words = byCardType(cardType)?.spoken ?? _legacySpoken[cardType];
    if (words == null) return null;
    return '${firstName(senderName)}: $words';
  }

  /// The spoken line for a text message, or null when it should stay a banner only:
  /// long texts are not spoken while [moving]; very long ones never word for word.
  static String? textSpoken({required String senderName, required String text, required bool moving}) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return null;
    if (t.length > shortSpokenChars && moving) return null;
    if (t.length > maxSpokenChars) return '${firstName(senderName)} sent a message';
    return '${firstName(senderName)} says: $t';
  }
}

/// A chat message as the decision rules need it (no model import: pure).
class ChatLine {
  final String id;
  final String senderId;
  final String senderName;
  final String text;
  final int timestamp;
  final bool isQuickCard;
  final String cardType;

  /// For gateway posted cards (SYSTEM sender): the rider who asked ("Wait for me").
  final String requestedBy;

  const ChatLine({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    this.isQuickCard = false,
    this.cardType = 'CUSTOM',
    this.requestedBy = '',
  });

  /// The rider behind the line (the requester for a SYSTEM card).
  String get authorId => (senderId == 'SYSTEM' && requestedBy.isNotEmpty) ? requestedBy : senderId;
}

/// What to do with one incoming message.
class ChatNotice {
  /// Spoken line (null: silent).
  final String? speech;

  /// Show a banner (text messages).
  final bool banner;

  const ChatNotice({this.speech, this.banner = false});

  static const ChatNotice none = ChatNotice();

  bool get isNone => speech == null && !banner;
}

class ChatRules {
  ChatRules._();

  /// Lines from me (or a SYSTEM card I asked for) and from hidden riders are never notified.
  static bool fromOthers(ChatLine m, {required String myUserId, Set<String> hidden = const {}}) {
    final who = m.authorId;
    return who != myUserId && !hidden.contains(who);
  }

  /// The notice for an incoming [m]: quick cards are spoken ("Kiran: fuel stop"), texts get a
  /// banner and are spoken only when short or stopped. Nothing while an emergency is open
  /// ([emergency]: the SOS owns the voice), for my own lines or hidden riders.
  static ChatNotice decide(ChatLine m, {required String myUserId, required bool moving, Set<String> hidden = const {}, bool emergency = false}) {
    if (!fromOthers(m, myUserId: myUserId, hidden: hidden)) return ChatNotice.none;
    if (m.isQuickCard) {
      final line = RideChat.quickSpoken(senderName: m.senderName, cardType: m.cardType, text: m.text);
      if (line != null) return ChatNotice(speech: emergency ? null : line);
    }
    return ChatNotice(banner: true, speech: emergency ? null : RideChat.textSpoken(senderName: m.senderName, text: m.text, moving: moving));
  }

  /// Visible lines (hidden riders' messages removed), oldest first.
  static List<T> visible<T>(List<T> lines, String Function(T) authorOf, Set<String> hidden) =>
      hidden.isEmpty ? lines : [for (final l in lines) if (!hidden.contains(authorOf(l))) l];
}

/// Unread count per ride: messages from others after the last time the chat was open.
class ChatUnread {
  final Map<String, int> _seenAt = {};

  /// The last time the chat of [rideId] was seen (epoch ms; 0 = never).
  int seenAt(String rideId) => _seenAt[rideId] ?? 0;

  /// The rider looked at the chat up to [timestamp] (only moves forward).
  void markSeen(String rideId, int timestamp) {
    if (timestamp > seenAt(rideId)) _seenAt[rideId] = timestamp;
  }

  /// Messages from others newer than [seenAt], hidden riders excluded.
  int count(String rideId, Iterable<ChatLine> lines, {required String myUserId, Set<String> hidden = const {}}) {
    final since = seenAt(rideId);
    var n = 0;
    for (final m in lines) {
      if (m.timestamp > since && ChatRules.fromOthers(m, myUserId: myUserId, hidden: hidden)) n++;
    }
    return n;
  }

  /// The badge text: "" for none, "9+" above 9.
  static String badge(int n) => n <= 0 ? '' : (n > 9 ? '9+' : '$n');

  void forget(String rideId) => _seenAt.remove(rideId);

  Map<String, int> toJson() => Map<String, int>.from(_seenAt);

  void load(Map<String, dynamic> raw) {
    raw.forEach((k, v) {
      if (v is num) _seenAt[k] = v.toInt();
    });
  }
}
