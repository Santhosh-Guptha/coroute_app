// Public ride, safe contact and road warnings (gateway/src/public_ride.js). Immutable models and
// the small pieces of logic the UI relies on (radius filter, marker label, warning wording and
// when a warning is spoken). No positions of other riders beyond the coarse public-ride point.

/// Wire names shared with the gateway.
class PublicRideWire {
  PublicRideWire._();

  /// Gateway feature and client capability.
  static const String feature = 'pubride1';

  /// Radius choices (km), the same on both sides.
  static const List<int> radii = [5, 10, 25, 50];
  static const int defaultRadiusKm = 10;

  static int radiusOf(Object? v, [int def = defaultRadiusKm]) {
    final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    return n != null && radii.contains(n) ? n : def;
  }

  /// Free text next to a quick line.
  static const int textMax = 80;
}

/// The ride's Public ride settings (the host changes them; everyone in the ride sees them).
class PublicRideSettings {
  final bool on;
  final int radiusKm;
  final bool showName;
  final bool showDestRegion;

  const PublicRideSettings({this.on = false, this.radiusKm = PublicRideWire.defaultRadiusKm, this.showName = false, this.showDestRegion = false});

  static const PublicRideSettings off = PublicRideSettings();

  static PublicRideSettings fromJson(Object? json) {
    if (json is! Map) return off;
    return PublicRideSettings(
      on: json['on'] == true,
      radiusKm: PublicRideWire.radiusOf(json['radiusKm']),
      showName: json['showName'] == true,
      showDestRegion: json['showDestRegion'] == true,
    );
  }

  Map<String, dynamic> toJson() => {'on': on, 'radiusKm': radiusKm, 'showName': showName, 'showDestRegion': showDestRegion};

  PublicRideSettings copyWith({bool? on, int? radiusKm, bool? showName, bool? showDestRegion}) => PublicRideSettings(
        on: on ?? this.on,
        radiusKm: radiusKm == null ? this.radiusKm : PublicRideWire.radiusOf(radiusKm, this.radiusKm),
        showName: showName ?? this.showName,
        showDestRegion: showDestRegion ?? this.showDestRegion,
      );

  /// What other riders see of this ride, in plain words.
  String get shownAs => showName ? 'Your ride name, rider count and a rough location' : '"Rider" or "Group of N" and a rough location';

  @override
  bool operator ==(Object other) =>
      other is PublicRideSettings && other.on == on && other.radiusKm == radiusKm && other.showName == showName && other.showDestRegion == showDestRegion;

  @override
  int get hashCode => Object.hash(on, radiusKm, showName, showDestRegion);
}

/// My own choices, kept on the phone and sent with every JOIN.
class PublicRidePrefs {
  final bool showNearby;
  final int radiusKm;
  final bool roadWarnings;

  const PublicRidePrefs({this.showNearby = false, this.radiusKm = PublicRideWire.defaultRadiusKm, this.roadWarnings = false});

  static PublicRidePrefs fromJson(Object? json) {
    if (json is! Map) return const PublicRidePrefs();
    return PublicRidePrefs(
      showNearby: json['showNearby'] == true,
      radiusKm: PublicRideWire.radiusOf(json['radiusKm']),
      roadWarnings: json['roadWarnings'] == true,
    );
  }

  Map<String, dynamic> toJson() => {'showNearby': showNearby, 'radiusKm': radiusKm, 'roadWarnings': roadWarnings};

  PublicRidePrefs copyWith({bool? showNearby, int? radiusKm, bool? roadWarnings}) => PublicRidePrefs(
        showNearby: showNearby ?? this.showNearby,
        radiusKm: radiusKm == null ? this.radiusKm : PublicRideWire.radiusOf(radiusKm, this.radiusKm),
        roadWarnings: roadWarnings ?? this.roadWarnings,
      );
}

/// Another public ride near me (coarse point, about 500 m; never ids or names of riders).
class PublicRideMarker {
  final String rideId;
  final String label;
  final int riders;
  final int distanceKm;
  final double lat;
  final double lng;
  final String? heading;
  final String? destRegion;

  const PublicRideMarker({
    required this.rideId,
    required this.label,
    required this.riders,
    required this.distanceKm,
    required this.lat,
    required this.lng,
    this.heading,
    this.destRegion,
  });

  static PublicRideMarker? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['rideId']?.toString() ?? '';
    final lat = json['lat'], lng = json['lng'];
    if (id.isEmpty || lat is! num || lng is! num) return null;
    final riders = json['riders'];
    final d = json['distanceKm'];
    final heading = json['heading']?.toString();
    final region = json['destRegion']?.toString();
    return PublicRideMarker(
      rideId: id,
      label: (json['label']?.toString() ?? '').trim().isEmpty ? 'Rider' : json['label'].toString().trim(),
      riders: riders is num && riders > 0 ? riders.toInt() : 1,
      distanceKm: d is num ? d.round() : 0,
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      heading: heading == null || heading.isEmpty ? null : heading,
      destRegion: region == null || region.isEmpty ? null : region,
    );
  }

  /// "4 riders" / "1 rider".
  String get ridersText => riders == 1 ? '1 rider' : '$riders riders';

  /// "Public ride · 4 riders · 8 km".
  String get markerLabel => 'Public ride · $ridersText · $distanceKm km';

  /// "Group of 4, heading NE, to Coorg".
  String get detail {
    final parts = <String>[label];
    if (heading != null) parts.add('heading $heading');
    if (destRegion != null) parts.add('to $destRegion');
    return parts.join(', ');
  }
}

/// The radius filter the app applies on top of the server's (a radius I just lowered applies at once).
class PublicRideFilter {
  PublicRideFilter._();

  static List<PublicRideMarker> withinRadius(Iterable<PublicRideMarker> rides, int radiusKm) {
    final out = rides.where((r) => r.distanceKm <= radiusKm).toList()..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return List.unmodifiable(out);
  }
}

/// Kinds of first contact.
enum ContactKind {
  hi('HI', 'Say hi'),
  help('HELP', 'Ask for help'),
  warn('WARN', 'Warn about road ahead');

  final String wire;
  final String title;
  const ContactKind(this.wire, this.title);

  static ContactKind? fromWire(String? s) {
    for (final k in values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

/// Predefined lines (the server sends the text too).
class QuickLines {
  QuickLines._();

  static const Map<String, String> hi = {'HI': 'Hi from a rider nearby', 'RIDE_SAFE': 'Ride safe', 'NICE_RIDE': 'Nice ride!', 'WHERE_TO': 'Where are you heading?'};
  static const Map<String, String> help = {
    'FUEL': 'Need fuel',
    'PUNCTURE': 'Puncture, need help',
    'BREAKDOWN': 'Bike trouble, need help',
    'LOST': 'Lost the way',
    'FIRST_AID': 'Need first aid',
  };
  static const Map<String, String> warn = {
    'POLICE': 'Police check ahead',
    'ACCIDENT': 'Accident ahead',
    'BLOCKED': 'Road blocked ahead',
    'ANIMALS': 'Animals on road',
    'BAD_ROAD': 'Bad road ahead',
    'WEATHER': 'Fog or heavy rain ahead',
  };
  static const Map<String, String> reply = {
    'THANKS': 'Thanks!',
    'OK': 'Okay',
    'ON_MY_WAY': 'On my way',
    'WAIT_THERE': 'Wait where you are',
    'CANT_HELP': "Sorry, can't help now",
    'CALL_112': 'Call 112 if urgent',
  };

  static Map<String, String> forKind(ContactKind k) => switch (k) {
        ContactKind.hi => hi,
        ContactKind.help => help,
        ContactKind.warn => warn,
      };

  /// Lines usable in an open chat.
  static Map<String, String> get chat => {...reply, ...help, ...warn};

  static String textOf(String code) => chat[code] ?? hi[code] ?? '';
}

/// What the app refuses before sending (the server checks again): links, numbers, handles, too long.
class ContactText {
  ContactText._();

  static final RegExp _link = RegExp(r'(https?://|www\.|\b[a-z0-9-]{2,}\.(com|in|net|org|io|me|ly|co|app|link|xyz|info)\b|t\.me/|wa\.me/)', caseSensitive: false);
  static final RegExp _email = RegExp(r'[^\s@]+@[^\s@]+\.[a-z]{2,}', caseSensitive: false);
  static final RegExp _handle = RegExp(r'(^|\s)@[a-z0-9_.]{3,}', caseSensitive: false);

  /// Null when fine, else why not.
  static String? problem(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (t.length > PublicRideWire.textMax) return 'Keep it under ${PublicRideWire.textMax} characters.';
    if (_link.hasMatch(t) || _email.hasMatch(t) || _handle.hasMatch(t)) return 'No links or handles.';
    if (RegExp(r'\d').allMatches(t).length >= 7 || RegExp(r'\d[\d\s().+-]{5,}\d').hasMatch(t)) return 'No phone numbers.';
    return null;
  }
}

/// A request from another rider to my ride (I am its host).
class ContactRequest {
  final String requestId;
  final ContactKind kind;
  final String quick;
  final String quickText;
  final String text;
  final String fromLabel;
  final String? fromRideId;
  final int? distanceKm;
  final int at;
  final int expiresAt;

  const ContactRequest({
    required this.requestId,
    required this.kind,
    required this.quick,
    required this.quickText,
    required this.text,
    required this.fromLabel,
    this.fromRideId,
    this.distanceKm,
    required this.at,
    required this.expiresAt,
  });

  static ContactRequest? fromJson(Object? json, {required int now}) {
    if (json is! Map) return null;
    final id = json['requestId']?.toString() ?? '';
    final kind = ContactKind.fromWire(json['kind']?.toString());
    if (id.isEmpty || kind == null) return null;
    final from = json['from'] is Map ? json['from'] as Map : const {};
    final quick = json['quick']?.toString() ?? '';
    final d = json['distanceKm'];
    final exp = json['expiresAt'];
    return ContactRequest(
      requestId: id,
      kind: kind,
      quick: quick,
      quickText: (json['quickText']?.toString() ?? '').isNotEmpty ? json['quickText'].toString() : QuickLines.forKind(kind)[quick] ?? '',
      text: json['text']?.toString() ?? '',
      fromLabel: (from['label']?.toString() ?? '').isEmpty ? 'A rider' : from['label'].toString(),
      fromRideId: from['rideId']?.toString(),
      distanceKm: d is num ? d.round() : null,
      at: now,
      expiresAt: exp is num ? exp.toInt() : now + 10 * 60000,
    );
  }

  /// "Group of 4 · 3 km: Need fuel".
  String get headline => '$fromLabel${distanceKm == null ? '' : ' · $distanceKm km'}: $quickText';
}

/// One line in a request thread or chat.
class ContactLine {
  final bool mine;
  final String quickText;
  final String text;
  final int at;
  const ContactLine({required this.mine, required this.quickText, required this.text, required this.at});

  String get display => [quickText, text].where((s) => s.trim().isNotEmpty).join(' · ');
}

/// Something I sent (a request) and what became of it.
enum OutgoingState { sent, accepted, closed }

class OutgoingRequest {
  final String requestId;
  final String rideLabel;
  final ContactKind kind;
  final String quickText;
  final OutgoingState state;
  final List<ContactLine> replies;
  final String? channelId;
  final int at;

  const OutgoingRequest({
    required this.requestId,
    required this.rideLabel,
    required this.kind,
    required this.quickText,
    this.state = OutgoingState.sent,
    this.replies = const [],
    this.channelId,
    required this.at,
  });

  OutgoingRequest copyWith({OutgoingState? state, List<ContactLine>? replies, String? channelId}) => OutgoingRequest(
        requestId: requestId,
        rideLabel: rideLabel,
        kind: kind,
        quickText: quickText,
        state: state ?? this.state,
        replies: replies ?? this.replies,
        channelId: channelId ?? this.channelId,
        at: at,
      );

  /// "Waiting for a reply" / "Accepted" / "No reply".
  String get stateText => switch (state) {
        OutgoingState.sent => 'Waiting for a reply',
        OutgoingState.accepted => 'Accepted',
        OutgoingState.closed => 'No reply',
      };
}

/// An accepted contact: 30 minutes of quick lines, optional live location and contact details.
class ContactChannel {
  final String channelId;
  final String withLabel;
  final int expiresAt;
  final bool closed;
  final List<ContactLine> lines;
  final bool sharingMine;
  final double? theirLat;
  final double? theirLng;
  final int? theirLocationAt;
  final String? theirName;
  final String? theirPhone;

  const ContactChannel({
    required this.channelId,
    required this.withLabel,
    required this.expiresAt,
    this.closed = false,
    this.lines = const [],
    this.sharingMine = false,
    this.theirLat,
    this.theirLng,
    this.theirLocationAt,
    this.theirName,
    this.theirPhone,
  });

  bool isOpen(int now) => !closed && now < expiresAt;

  /// Whole minutes left, at least 0.
  int minutesLeft(int now) => ((expiresAt - now) / 60000).ceil().clamp(0, 999);

  ContactChannel copyWith({
    bool? closed,
    List<ContactLine>? lines,
    bool? sharingMine,
    double? theirLat,
    double? theirLng,
    int? theirLocationAt,
    bool clearTheirLocation = false,
    String? theirName,
    String? theirPhone,
  }) =>
      ContactChannel(
        channelId: channelId,
        withLabel: withLabel,
        expiresAt: expiresAt,
        closed: closed ?? this.closed,
        lines: lines ?? this.lines,
        sharingMine: sharingMine ?? this.sharingMine,
        theirLat: clearTheirLocation ? null : (theirLat ?? this.theirLat),
        theirLng: clearTheirLocation ? null : (theirLng ?? this.theirLng),
        theirLocationAt: clearTheirLocation ? null : (theirLocationAt ?? this.theirLocationAt),
        theirName: theirName ?? this.theirName,
        theirPhone: theirPhone ?? this.theirPhone,
      );
}

/// One-tap road warnings.
enum RoadWarningKind {
  police('POLICE', 'Police check'),
  accident('ACCIDENT', 'Accident ahead'),
  blocked('BLOCKED', 'Landslide or road blocked'),
  animals('ANIMALS', 'Animals on road'),
  fuelClosed('FUEL_CLOSED', 'Fuel station closed'),
  weather('WEATHER', 'Fog or heavy rain');

  final String wire;
  final String buttonLabel;
  const RoadWarningKind(this.wire, this.buttonLabel);

  static RoadWarningKind? fromWire(String? s) {
    for (final k in values) {
      if (k.wire == s) return k;
    }
    return null;
  }

  /// The noun used in "Accident reported 6 km ahead".
  String get noun => switch (this) {
        RoadWarningKind.police => 'Police check',
        RoadWarningKind.accident => 'Accident',
        RoadWarningKind.blocked => 'Road blocked',
        RoadWarningKind.animals => 'Animals on road',
        RoadWarningKind.fuelClosed => 'Fuel station closed',
        RoadWarningKind.weather => 'Fog or heavy rain',
      };
}

/// A road warning from another rider, for a spot ahead of me.
class RoadWarning {
  final String warnId;
  final RoadWarningKind kind;
  final int aheadKm;
  final double lat;
  final double lng;
  final bool confirmed;
  final int confirmations;
  /// ONCOMING (reported by a rider coming the other way), AHEAD (a rider ahead of me) or NEARBY.
  final String by;
  final int expiresAt;
  final int receivedAt;

  const RoadWarning({
    required this.warnId,
    required this.kind,
    required this.aheadKm,
    required this.lat,
    required this.lng,
    required this.confirmed,
    required this.confirmations,
    required this.by,
    required this.expiresAt,
    required this.receivedAt,
  });

  static RoadWarning? fromJson(Object? json, {required int now}) {
    if (json is! Map) return null;
    final id = json['warnId']?.toString() ?? '';
    final kind = RoadWarningKind.fromWire(json['kind']?.toString());
    final lat = json['lat'], lng = json['lng'];
    if (id.isEmpty || kind == null || lat is! num || lng is! num) return null;
    final ahead = json['aheadKm'];
    final c = json['confirmations'];
    final exp = json['expiresAt'];
    return RoadWarning(
      warnId: id,
      kind: kind,
      aheadKm: ahead is num ? ahead.round().clamp(1, 999) : 1,
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      confirmed: json['confirmed'] == true,
      confirmations: c is num ? c.toInt() : 1,
      by: json['by']?.toString() ?? 'NEARBY',
      expiresAt: exp is num ? exp.toInt() : now + 30 * 60000,
      receivedAt: now,
    );
  }

  String get _byText => switch (by) {
        'ONCOMING' => ' by an oncoming rider',
        'AHEAD' => ' by a rider ahead',
        _ => '',
      };

  /// "Accident reported 6 km ahead by an oncoming rider".
  String get bannerText => '${kind.noun} reported $aheadKm km ahead$_byText';

  /// The short spoken line.
  String get speech => '${kind.noun}, $aheadKm kilometres ahead.';

  /// "Not confirmed yet" / "Confirmed by 3 riders".
  String get confirmText => confirmed ? 'Confirmed by $confirmations riders' : 'Not confirmed yet';

  bool isExpired(int now) => now >= expiresAt;
}

/// Which warnings show and when one is spoken.
class RoadWarningPolicy {
  RoadWarningPolicy._();

  /// Live warnings, nearest first.
  static List<RoadWarning> visible(Iterable<RoadWarning> all, int now) {
    final out = all.where((w) => !w.isExpired(now)).toList()..sort((a, b) => a.aheadKm.compareTo(b.aheadKm));
    return List.unmodifiable(out);
  }

  /// Spoken once when it first arrives and once more when it becomes confirmed; never while my
  /// own group has an emergency open (the SOS speaks then) and never once expired.
  static String? speechKey(RoadWarning w, {required Set<String> spoken, required bool emergencyActive, required int now}) {
    if (emergencyActive || w.isExpired(now)) return null;
    final key = 'RW:${w.warnId}:${w.confirmed ? 'C' : 'U'}';
    if (spoken.contains(key)) return null;
    // An unconfirmed warning already spoken is not repeated by a later unconfirmed copy; the
    // confirmed upgrade is spoken.
    return key;
  }
}
