// Emergency texts from the rider's own phone (SIM), sent automatically after an SOS or an
// unanswered crash alarm (docs/features_355/sos_sms.md, "Phone-first").
//
// Pure Dart: who gets a text, the job ids (dedupe per incident), the retry schedule, the daily
// cap, cancel-before-send and the "I'm safe now" follow-up. The native queue (SmsChannel.kt /
// EmergencyTexts.kt) only executes the jobs: it sends, retries with [EmergencyTextPolicy.retryDelays],
// reports sent / delivered per job and keeps the queue on disk across an app kill.
// Tested in test/emergency_texts_357_test.dart.

import '../../data/models/emergency_roster.dart';
import 'sms_plan.dart';

/// What a text is about. Wire letters go into the job id: A(lert), S(afe), T(est).
enum EmergencyTextKind {
  alert('A'),
  safe('S'),
  test('T');

  const EmergencyTextKind(this.letter);
  final String letter;

  static EmergencyTextKind? fromLetter(String? s) {
    for (final k in values) {
      if (k.letter == s) return k;
    }
    return null;
  }
}

/// A job state as the native queue reports it.
enum EmergencyTextState {
  queued,
  sending,
  sent,
  delivered,
  failed,
  cancelled;

  static EmergencyTextState fromWire(String? s) {
    switch ((s ?? '').toUpperCase()) {
      case 'SENDING':
        return EmergencyTextState.sending;
      case 'SENT':
        return EmergencyTextState.sent;
      case 'DELIVERED':
        return EmergencyTextState.delivered;
      case 'FAILED':
        return EmergencyTextState.failed;
      case 'CANCELLED':
        return EmergencyTextState.cancelled;
      default:
        return EmergencyTextState.queued;
    }
  }

  String get wire => name.toUpperCase();

  /// Left the phone (or is leaving it now): the contact has, or will have, the text.
  bool get reached => this == sending || this == sent || this == delivered;

  bool get finished => this == sent || this == delivered || this == failed || this == cancelled;
}

/// One text for the native queue. [to] and [body] never go into a log.
class EmergencyTextJob {
  final String id;
  final String incident;
  final EmergencyTextKind kind;
  final String to;
  final String body;

  /// Not sent before this time (epoch ms): the grace window in which a cancel stops it.
  final int notBeforeMs;

  const EmergencyTextJob({
    required this.id,
    required this.incident,
    required this.kind,
    required this.to,
    required this.body,
    required this.notBeforeMs,
  });

  int get parts => SmsText.parts(body);

  Map<String, Object> toWire() => {
        'id': id,
        'incident': incident,
        'kind': kind.letter,
        'to': to,
        'body': body,
        'notBefore': notBeforeMs,
      };

  @override
  String toString() => 'EmergencyTextJob(${kind.name}, ${EmergencyTexts.last3(to)})';
}

/// One job's state, from the native queue (no number: only its last 3 digits).
class EmergencyTextStatus {
  final String id;
  final EmergencyTextState state;
  final int attempts;

  /// SmsManager result code of the last failure (0: none). Negative: CoRoute's own codes.
  final int code;
  final String last3;
  final int updatedAt;

  const EmergencyTextStatus({
    required this.id,
    required this.state,
    this.attempts = 0,
    this.code = 0,
    this.last3 = '',
    this.updatedAt = 0,
  });

  EmergencyTextKind? get kind => EmergencyTextKind.fromLetter(EmergencyTexts.partsOf(id)?.$2);
  String? get incident => EmergencyTexts.partsOf(id)?.$1;

  static EmergencyTextStatus? fromWire(Object? j) {
    if (j is! Map) return null;
    final id = j['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final l3 = j['last3']?.toString() ?? '';
    return EmergencyTextStatus(
      id: id,
      state: EmergencyTextState.fromWire(j['state']?.toString()),
      attempts: (j['attempts'] as num?)?.toInt() ?? 0,
      code: (j['code'] as num?)?.toInt() ?? 0,
      last3: RegExp(r'^\d{0,3}$').hasMatch(l3) ? l3 : '',
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() => 'EmergencyTextStatus(${state.name}, try $attempts, code $code)';
}

/// The fixed numbers of the phone-first emergency texts.
class EmergencyTextPolicy {
  EmergencyTextPolicy._();

  /// Emergency contacts texted per incident.
  static const int maxContacts = 5;

  /// Texts per rolling 24 h (alert and test texts; "safe now" only follows texts already sent).
  static const int dailyCap = 30;

  /// Waits before the 2nd, 3rd, 4th and 5th try of a text that failed with a retryable code.
  static const List<Duration> retryDelays = [
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
  ];

  /// A deliberate SOS press (SOS hold screen, ride notification) waits this long, so a press
  /// cancelled at once on the SOS screen texts nobody. Automatic SOS (crash alarm ran out,
  /// rider-down, missing rider, solo check-in) already had their countdown and go at once.
  static const Duration pressGrace = Duration(seconds: 10);

  /// An SOS older than this (restored from disk long after) is not texted any more.
  static const Duration maxIncidentAge = Duration(hours: 2);

  // SmsManager.RESULT_ERROR_* values (stable since API 4) and CoRoute's own codes.
  static const int errorGeneric = 1;
  static const int errorRadioOff = 2;
  static const int errorNullPdu = 3;
  static const int errorNoService = 4;
  static const int errorTimeout = -100; // no sent report within 3 min (the native queue)
  static const int errorNoPermission = -10;

  /// Worth another try: no signal, radio off (airplane mode), a generic failure, or no report.
  static bool retryable(int code) =>
      code == errorGeneric || code == errorRadioOff || code == errorNoService || code == errorTimeout;

  /// The wait before the next try after [attempts] tries all failed with [code]; null: give up.
  static Duration? retryAfter(int attempts, int code) {
    if (!retryable(code) || attempts < 1 || attempts > retryDelays.length) return null;
    return retryDelays[attempts - 1];
  }

  /// The grace window for an incident: [deliberatePress] for a button press, else none.
  static Duration graceFor({required bool deliberatePress}) => deliberatePress ? pressGrace : Duration.zero;

  static List<int> get retryDelaysMs => [for (final d in retryDelays) d.inMilliseconds];
}

/// The text bodies (plain GSM where possible: one SMS part for a normal alert).
class EmergencyTexts {
  EmergencyTexts._();

  /// The alert: name, SOS or possible crash, time, live link, coordinates as text, and the map
  /// link and ride name while they fit one part ([SmsText.sos]).
  static String alert({
    required String name,
    required bool crash,
    required double lat,
    required double lng,
    required DateTime at,
    String? liveLink,
    String? convoyName,
  }) =>
      SmsText.sos(name: name, auto: crash, lat: lat, lng: lng, at: at, liveLink: liveLink, convoyName: convoyName);

  /// "I'm safe now", sent to the same contacts when the SOS is closed after texts went out.
  static String safeNow({required String name, required DateTime at}) {
    final who = name.trim().isEmpty ? 'The rider' : name.trim();
    return 'CoRoute: $who is safe now. The SOS was closed at ${_two(at.hour)}:${_two(at.minute)}. No action is needed.';
  }

  /// The Safety health test text (only after the rider confirms).
  static const String test = 'CoRoute test: emergency texts work. No action is needed.';

  static String _two(int v) => v < 10 ? '0$v' : '$v';

  /// The last 3 digits of a number, for logs and status lines ('' when fewer).
  static String last3(String phone) {
    final d = phone.replaceAll(RegExp(r'[^0-9]'), '');
    return d.length < 3 ? '' : d.substring(d.length - 3);
  }

  /// Short stable hash of a number's comparison key (FNV-1a 32 bit, 8 hex): job ids never carry
  /// the number itself.
  static String keyHash(String phone) {
    final key = SmsPlanner.phoneKey(phone);
    var h = 0x811c9dc5;
    for (final c in key.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// `<incident>|<kind letter>|<hash>`.
  static String jobId(String incident, EmergencyTextKind kind, String phone) => '$incident|${kind.letter}|${keyHash(phone)}';

  /// (incident, kind letter, hash) of a job id, or null.
  static (String, String, String)? partsOf(String id) {
    final i = id.lastIndexOf('|');
    if (i <= 0) return null;
    final j = id.lastIndexOf('|', i - 1);
    if (j <= 0) return null;
    return (id.substring(0, j), id.substring(j + 1, i), id.substring(i + 1));
  }
}

/// What the ledger knows of one incident (no numbers: only their hashes).
class _Incident {
  final String id;
  final int at;
  final List<String> hashes;
  bool closed;
  bool safeSent;

  _Incident({required this.id, required this.at, required this.hashes, this.closed = false, this.safeSent = false});

  Map<String, Object> toJson() => {'id': id, 'at': at, 'h': hashes, if (closed) 'c': true, if (safeSent) 's': true};

  static _Incident? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return _Incident(
      id: id,
      at: (j['at'] as num?)?.toInt() ?? 0,
      hashes: [for (final h in (j['h'] as List? ?? const [])) h.toString()],
      closed: j['c'] == true,
      safeSent: j['s'] == true,
    );
  }
}

/// Result of a test text request.
enum EmergencyTestPlan { ok, noContact, dailyCap }

/// The phone's record of emergency texts: which incidents were texted (and to which number
/// hashes), whether "safe now" went, and the send times for the daily cap. Kept with the pending
/// SOS (PendingSosStore's sibling EmergencyTextStore), so a restart never texts an incident twice.
/// No numbers and no text are kept here.
class EmergencyTextLedger {
  EmergencyTextLedger._(this._incidents, this._sends);

  factory EmergencyTextLedger.empty() => EmergencyTextLedger._([], []);

  final List<_Incident> _incidents;
  final List<int> _sends;

  static const Duration keepFor = Duration(hours: 48);
  static const int keepIncidents = 20;
  static const Duration day = Duration(hours: 24);

  /// Texts counted against the cap in the 24 h before [nowMs].
  int sentInLastDay(int nowMs) => _sends.where((t) => t > nowMs - day.inMilliseconds && t <= nowMs).length;

  int remainingToday(int nowMs) {
    final left = EmergencyTextPolicy.dailyCap - sentInLastDay(nowMs);
    return left < 0 ? 0 : left;
  }

  bool hasIncident(String incident) => _find(incident) != null;

  /// The newest texted incident that is not closed yet.
  String? get openIncident {
    for (final i in _incidents.reversed) {
      if (!i.closed && i.hashes.isNotEmpty) return i.id;
    }
    return null;
  }

  /// [openIncident] when it is younger than [followUpWindow] at [nowMs]: a "safe now" never goes
  /// out for an SOS from long ago (the app was killed and the SOS never closed here).
  String? openIncidentAt(int nowMs) {
    final id = openIncident;
    final inc = id == null ? null : _find(id);
    if (inc == null || nowMs - inc.at > followUpWindow.inMilliseconds) return null;
    return id;
  }

  static const Duration followUpWindow = Duration(hours: 24);

  /// [phone] was (or is being) texted for [incident] by the automatic path.
  bool alreadyTexted(String incident, String phone) {
    final i = _find(incident);
    return i != null && i.hashes.contains(EmergencyTexts.keyHash(phone));
  }

  _Incident? _find(String id) {
    for (final i in _incidents) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// The alert texts for a new [incident]: each contact once (by phone key), never [selfPhone],
  /// at most [EmergencyTextPolicy.maxContacts] and within the daily cap. An incident seen before
  /// (resent, relayed, upgraded to a crash, after a restart) gives nothing. The incident is
  /// recorded even when nobody could be texted, so a later call does not try again.
  List<EmergencyTextJob> planAlert({
    required String incident,
    required List<RosterContact> contacts,
    required String body,
    required int nowMs,
    Duration grace = Duration.zero,
    String? selfPhone,
  }) {
    if (incident.isEmpty || hasIncident(incident)) return const [];
    // A new SOS supersedes any older one still open here: its "safe now" can no longer be told apart.
    for (final i in _incidents) {
      i.closed = true;
    }
    final seen = <String>{};
    final self = selfPhone == null ? '' : SmsPlanner.phoneKey(selfPhone);
    if (self.isNotEmpty) seen.add(self);
    final chosen = <String>[];
    for (final c in contacts) {
      final dial = SmsPlanner.dialable(c.phone);
      final key = SmsPlanner.phoneKey(dial);
      if (key.isEmpty || !seen.add(key)) continue;
      chosen.add(dial);
    }
    var limit = EmergencyTextPolicy.maxContacts;
    final left = remainingToday(nowMs);
    if (left < limit) limit = left;
    final picked = chosen.length <= limit ? chosen : chosen.sublist(0, limit);
    final notBefore = nowMs + grace.inMilliseconds;
    final jobs = [
      for (final to in picked)
        EmergencyTextJob(
          id: EmergencyTexts.jobId(incident, EmergencyTextKind.alert, to),
          incident: incident,
          kind: EmergencyTextKind.alert,
          to: to,
          body: body,
          notBeforeMs: notBefore,
        ),
    ];
    _incidents.add(_Incident(id: incident, at: nowMs, hashes: [for (final to in picked) EmergencyTexts.keyHash(to)]));
    for (var i = 0; i < jobs.length; i++) {
      _sends.add(nowMs);
    }
    _prune(nowMs);
    return jobs;
  }

  /// Alert jobs of [incident] still waiting (grace window or a retry): cancelled when the SOS is
  /// closed, so a cancelled SOS texts nobody new.
  List<String> toCancel(String incident, Iterable<EmergencyTextStatus> statuses) => [
        for (final s in statuses)
          if (s.incident == incident && s.kind == EmergencyTextKind.alert && s.state == EmergencyTextState.queued) s.id,
      ];

  /// Closes [incident] and gives the "I'm safe now" texts: only to [contacts] whose alert text
  /// left the phone (sending, sent or delivered, per [statuses]), once per incident. A contact
  /// whose alert was cancelled in time, failed for good or is unknown gets nothing.
  List<EmergencyTextJob> planSafe({
    required String incident,
    required List<RosterContact> contacts,
    required Iterable<EmergencyTextStatus> statuses,
    required String body,
    required int nowMs,
  }) {
    final inc = _find(incident);
    if (inc == null || inc.safeSent) return const [];
    inc.closed = true;
    final reached = <String>{
      for (final s in statuses)
        if (s.incident == incident && s.kind == EmergencyTextKind.alert && s.state.reached) EmergencyTexts.partsOf(s.id)!.$3,
    };
    final seen = <String>{};
    final jobs = <EmergencyTextJob>[];
    for (final c in contacts) {
      final dial = SmsPlanner.dialable(c.phone);
      final hash = EmergencyTexts.keyHash(dial);
      if (SmsPlanner.phoneKey(dial).isEmpty || !reached.contains(hash) || !seen.add(hash)) continue;
      jobs.add(EmergencyTextJob(
        id: EmergencyTexts.jobId(incident, EmergencyTextKind.safe, dial),
        incident: incident,
        kind: EmergencyTextKind.safe,
        to: dial,
        body: body,
        notBeforeMs: nowMs,
      ));
    }
    inc.safeSent = true;
    _prune(nowMs);
    return jobs;
  }

  /// A new SOS that is not texted (texts not allowed, no contact, a test alarm, too old): recorded,
  /// and every older incident is closed, so cancelling this SOS never follows up an older one.
  void recordWithoutTexts(String incident, int nowMs) {
    if (incident.isEmpty || hasIncident(incident)) return;
    for (final i in _incidents) {
      i.closed = true;
    }
    _incidents.add(_Incident(id: incident, at: nowMs, hashes: const [], closed: true));
    _prune(nowMs);
  }

  /// Marks [incident] closed without any follow-up (nothing was texted, or it is unknown).
  void close(String incident) => _find(incident)?.closed = true;

  /// The Safety health test text to the first contact, within the daily cap.
  (EmergencyTestPlan, EmergencyTextJob?) planTest({required List<RosterContact> contacts, required int nowMs, String? selfPhone}) {
    final self = selfPhone == null ? '' : SmsPlanner.phoneKey(selfPhone);
    String? to;
    for (final c in contacts) {
      final dial = SmsPlanner.dialable(c.phone);
      final key = SmsPlanner.phoneKey(dial);
      if (key.isEmpty || key == self) continue;
      to = dial;
      break;
    }
    if (to == null) return (EmergencyTestPlan.noContact, null);
    if (remainingToday(nowMs) <= 0) return (EmergencyTestPlan.dailyCap, null);
    _sends.add(nowMs);
    _prune(nowMs);
    final incident = 'test-$nowMs';
    return (
      EmergencyTestPlan.ok,
      EmergencyTextJob(
        id: EmergencyTexts.jobId(incident, EmergencyTextKind.test, to),
        incident: incident,
        kind: EmergencyTextKind.test,
        to: to,
        body: EmergencyTexts.test,
        notBeforeMs: nowMs,
      ),
    );
  }

  void _prune(int nowMs) {
    _sends.removeWhere((t) => t <= nowMs - day.inMilliseconds);
    _incidents.removeWhere((i) => i.at < nowMs - keepFor.inMilliseconds && i.closed);
    while (_incidents.length > keepIncidents) {
      _incidents.removeAt(0);
    }
  }

  Map<String, Object> toJson() => {'v': 1, 'i': [for (final i in _incidents) i.toJson()], 's': List<int>.of(_sends)};

  static EmergencyTextLedger fromJson(Object? j) {
    if (j is! Map) return EmergencyTextLedger.empty();
    return EmergencyTextLedger._(
      [
        for (final i in (j['i'] as List? ?? const []))
          ?_Incident.fromJson(i),
      ],
      [
        for (final t in (j['s'] as List? ?? const []))
          if (t is num) t.toInt(),
      ],
    );
  }
}

/// One plain status line for the SOS screen and the solo ride card (counts only, never numbers).
class EmergencyTextSummary {
  EmergencyTextSummary._();

  static const String composerFallback =
      'Your contacts were not texted automatically: emergency texts are not allowed on this phone. '
      'Without internet the SOS text opens in your messages app. Allow them in Safety health.';

  /// [statuses]: the alert jobs of one incident (other kinds are ignored).
  static String line(Iterable<EmergencyTextStatus> statuses) {
    final alerts = [for (final s in statuses) if (s.kind == EmergencyTextKind.alert) s];
    if (alerts.isEmpty) return '';
    final total = alerts.length;
    int count(bool Function(EmergencyTextStatus s) f) => alerts.where(f).length;
    final cancelled = count((s) => s.state == EmergencyTextState.cancelled);
    final delivered = count((s) => s.state == EmergencyTextState.delivered);
    final reached = count((s) => s.state == EmergencyTextState.sent || s.state == EmergencyTextState.delivered);
    final failed = count((s) => s.state == EmergencyTextState.failed);
    final retrying = count((s) => s.state == EmergencyTextState.queued && s.attempts > 0);
    final waiting = count((s) => s.state == EmergencyTextState.queued || s.state == EmergencyTextState.sending);
    final who = total == 1 ? 'your emergency contact' : '$total emergency contacts';
    if (cancelled == total) return 'SOS cancelled in time: no texts were sent.';
    if (retrying > 0) return 'No signal yet. The text to $who will be sent again by itself.';
    if (waiting > 0) return 'Texting $who from your phone...';
    if (reached == 0) return 'The text to $who did not go out. Call them or 112.';
    final texted = reached == total ? 'Texted $who from your phone.' : 'Texted $reached of $total emergency contacts from your phone.';
    final del = delivered == 0 ? '' : (delivered == total ? ' Delivered.' : ' $delivered delivered.');
    final fail = failed > 0 ? ' Some texts did not go out.' : '';
    return '$texted$del$fail';
  }
}
