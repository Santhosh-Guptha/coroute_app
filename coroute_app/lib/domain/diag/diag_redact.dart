// 3.55 diagnostics log: the one place that decides what may be written (privacy by design).
// Pure Dart. Tested in test/diag_log_355_test.dart.
//
// Rules (docs/features_355/diagnostics_logs.md#privacy):
//  * Never message text, names, phone numbers, e-mails, medical info, tokens or addresses. Keys
//    that name such things are dropped whatever their value; free text values are scrubbed
//    (e-mail, JWT, bearer / API tokens, long hex / base64 runs, phone numbers, long digit runs).
//  * Location only as 3 decimals (~100 m) and only during a ride (DiagLog drops lat/lng otherwise).
//  * User ids only as a short salted hash ([hashId]); the salt is random per install.
//  * API paths as templates without ids or query ([pathTemplate]).
//  * Small: at most [maxFields] fields per entry, strings cut to [maxString] characters, no nesting.

class DiagRedact {
  DiagRedact._();

  static const int maxFields = 16;
  static const int maxString = 120;

  // Key words that are never logged (the whole field is dropped). Matched against the
  // camelCase / snake_case words of a key, so 'riderName', 'phone_no', 'bloodGroup' all go.
  static const Set<String> _blockedWords = {
    'name', 'names', 'firstname', 'lastname', 'username', 'nick', 'nickname',
    'phone', 'mobile', 'tel', 'msisdn', 'sms', 'email', 'mail',
    'message', 'msg', 'text', 'body', 'content', 'comment', 'note', 'notes', 'question', 'answer', 'title',
    'medical', 'blood', 'allergy', 'allergies', 'condition', 'conditions', 'medication', 'medications', 'organ', 'dob', 'birth',
    'token', 'jwt', 'bearer', 'password', 'secret', 'auth', 'authorization', 'cookie', 'otp', 'pin', 'key', 'apikey', 'signature',
    'address', 'street', 'home', 'destination', 'place', 'contact', 'contacts', 'emergency', 'guardian',
    'card', 'upi', 'vpa', 'payment', 'imei', 'serial',
  };

  // Words that look blocked but are fine as a key part (e.g. 'textLen', 'tokenOk' count/flag).
  static const Set<String> _allowSuffix = {'len', 'length', 'count', 'ok', 'set', 'present', 'kind', 'type', 'source', 'src', 'ms', 'age'};

  static final RegExp _camel = RegExp(r'([a-z0-9])([A-Z])');
  static List<String> _wordsOf(String k) =>
      k.replaceAllMapped(_camel, (m) => '${m[1]} ${m[2]}').toLowerCase().split(RegExp(r'[\s_\-.]+')).where((w) => w.isNotEmpty).toList();

  /// True when a field with this key must never be written.
  static bool blockedKey(String key) {
    final words = _wordsOf(key);
    if (words.isEmpty) return true;
    if (words.length > 1 && _allowSuffix.contains(words.last)) return false;
    return words.any(_blockedWords.contains);
  }

  // ---------------------------------------------------------------- free text
  static final RegExp _email = RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}');
  static final RegExp _jwt = RegExp(r'eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}');
  static final RegExp _bearer = RegExp(r'(?:bearer|token|key|secret|password|pwd|otp|auth)\s*[:=]?\s*\S+', caseSensitive: false);
  static final RegExp _url = RegExp(r'https?://[^\s?#]+(?:\?[^\s#]*)?', caseSensitive: false);
  static final RegExp _longHex = RegExp(r'\b[A-Fa-f0-9]{24,}\b');
  static final RegExp _longB64 = RegExp(r'[A-Za-z0-9_\-+/]{32,}={0,2}');
  // Phone numbers: +91 98765 43210, (020) 1234-5678, 9876543210 ... at least 9 digits overall.
  static final RegExp _phone = RegExp(r'\+?\(?\d[\d\s()\-]{7,}\d');
  static final RegExp _digits = RegExp(r'\d{7,}');
  static final RegExp _nonDigit = RegExp(r'\D');
  static final RegExp _hasDigit = RegExp(r'\d');
  static final RegExp _hasUpper = RegExp(r'[A-Z]');
  static final RegExp _hasLower = RegExp(r'[a-z]');
  static final RegExp _ctl = RegExp(r'[\u0000-\u001f\u007f]+');
  // Coordinates written as text: 17.385044, 78.486671 (5+ decimals) -> rounded.
  static final RegExp _coord = RegExp(r'-?\d{1,3}\.\d{4,}');

  /// Free text made safe: secrets and personal patterns replaced, control characters removed,
  /// cut to [max] characters.
  static String text(String input, {int max = maxString}) {
    var s = input.replaceAll(_ctl, ' ');
    s = s.replaceAll(_jwt, '<jwt>');
    s = s.replaceAllMapped(_url, (m) {
      final u = m[0]!;
      final q = u.indexOf('?');
      return q < 0 ? u : u.substring(0, q);
    });
    s = s.replaceAll(_email, '<email>');
    s = s.replaceAll(_bearer, '<secret>');
    s = s.replaceAllMapped(_longHex, (m) => m[0]!.contains(_hasDigit) ? '<hex>' : m[0]!);
    s = s.replaceAllMapped(_longB64, (m) {
      final t = m[0]!;
      // Base64 / API tokens mix digits with upper and lower case; file paths and words do not.
      final mixed = t.contains(_hasDigit) && t.contains(_hasUpper) && t.contains(_hasLower);
      return mixed ? '<token>' : t;
    });
    s = s.replaceAllMapped(_coord, (m) {
      final v = double.tryParse(m[0]!);
      return v == null ? '<n>' : coord(v).toString();
    });
    s = s.replaceAllMapped(_phone, (m) {
      final t = m[0]!;
      final n = t.replaceAll(_nonDigit, '').length;
      // A bare digit run longer than 12 is an epoch / id (handled below), not a phone number.
      final bare = n == t.length;
      return n >= 9 && n <= (bare ? 12 : 15) ? '<phone>' : t;
    });
    s = s.replaceAll(_digits, '<num>');
    s = s.trim();
    if (s.length > max) s = '${s.substring(0, max - 1)}…';
    return s;
  }

  // ---------------------------------------------------------------- values
  /// A coordinate rounded to 3 decimals (~110 m at the equator).
  static double coord(double v) => v.isFinite ? (v * 1000).roundToDouble() / 1000 : 0;

  /// A number kept small: integers as they are, doubles to 2 decimals (3 for coordinates).
  static num number(num v) {
    if (v is int) return v;
    final d = v.toDouble();
    if (!d.isFinite) return 0;
    if (d == d.roundToDouble() && d.abs() < 1e15) return d.toInt();
    return (d * 100).roundToDouble() / 100;
  }

  /// Fields made safe: blocked keys dropped, strings scrubbed, numbers rounded, nesting flattened
  /// to a short summary, at most [maxFields]. Keys `lat` / `lng` are rounded to 3 decimals
  /// (DiagLog removes them outside a ride).
  static Map<String, Object?> fields(Map<String, Object?>? input) {
    if (input == null || input.isEmpty) return const {};
    final out = <String, Object?>{};
    for (final e in input.entries) {
      if (out.length >= maxFields) break;
      final k = _key(e.key);
      if (k.isEmpty || blockedKey(k)) continue;
      final v = e.value;
      if (v == null) continue;
      if (k == 'lat' || k == 'lng' || k == 'lon') {
        if (v is num) out[k] = coord(v.toDouble());
        continue;
      }
      if (v is bool) {
        out[k] = v;
      } else if (v is num) {
        out[k] = number(v);
      } else if (v is Enum) {
        out[k] = v.name;
      } else if (v is Duration) {
        out[k] = v.inMilliseconds;
      } else if (v is Iterable) {
        out[k] = v.length; // only how many, never the items
      } else if (v is Map) {
        out[k] = v.length;
      } else {
        final s = text(v.toString());
        if (s.isNotEmpty) out[k] = s;
      }
    }
    return out;
  }

  static final RegExp _keyBad = RegExp(r'[^A-Za-z0-9_]');
  static String _key(String k) {
    final s = k.replaceAll(_keyBad, '_');
    return s.length > 32 ? s.substring(0, 32) : s;
  }

  static final RegExp _eventBad = RegExp(r'[^a-z0-9_.]');
  /// Event names: lower case words, digits, '_' and '.', at most 48 characters.
  static String event(String e) {
    final s = e.toLowerCase().replaceAll(_eventBad, '_');
    if (s.isEmpty) return 'event';
    return s.length > 48 ? s.substring(0, 48) : s;
  }

  // ---------------------------------------------------------------- ids
  /// A short salted hash of an id (10 hex characters), the same for the same id and salt.
  /// Two rounds of 64-bit FNV-1a over salt + id; the salt is random per install, so the hash
  /// cannot be matched against ids from another phone or a list of user ids without the salt.
  static String hashId(String id, String salt) {
    if (id.isEmpty) return '';
    int fnv(String s, int seed) {
      // 64-bit FNV-1a done in two 32-bit halves (no BigInt, JS-safe).
      var hi = 0xcbf29ce4 ^ seed, lo = 0x84222325;
      for (final c in s.codeUnits) {
        lo ^= c & 0xff;
        // multiply (hi,lo) by FNV prime 0x100000001b3 = (1 << 40) + 0x1b3
        final loMul = lo * 0x1b3;
        final hiMul = hi * 0x1b3 + lo * 256;
        lo = loMul & 0xffffffff;
        hi = (hiMul + (loMul ~/ 0x100000000)) & 0xffffffff;
      }
      return (hi ^ lo) & 0xffffffff;
    }

    final a = fnv('$salt|$id', 0x5bd1e995).toRadixString(16).padLeft(8, '0');
    final b = fnv('$id|$salt', 0x1b873593).toRadixString(16).padLeft(8, '0');
    return '$a${b.substring(0, 2)}';
  }

  // ---------------------------------------------------------------- stacks
  static final RegExp _frame = RegExp(r'^#\d+\s+(\S+)\s+\((.+?):(\d+)(?::\d+)?\)');

  /// The top [frames] frames of a stack as "Class.method file.dart:12 | ..." (file names only,
  /// never full paths or arguments). Empty for no stack.
  static String stackTop(Object? stack, {int frames = 5}) {
    if (stack == null) return '';
    final out = <String>[];
    for (final line in stack.toString().split('\n')) {
      final m = _frame.firstMatch(line.trim());
      if (m == null) continue;
      final file = m[2]!.split('/').last;
      out.add('${m[1]} $file:${m[3]}');
      if (out.length >= frames) break;
    }
    return text(out.join(' | '), max: 400);
  }

  // ---------------------------------------------------------------- paths
  static const Set<String> _idParents = {
    'friends', 'users', 'profiles', 'profile', 'crews', 'polls', 'invites', 'requests', 'convoys', 'groups', 'trips',
    'places', 'reviews', 'photos', 'alerts', 'tracks', 'riders', 'rides', 'tokens', 'join', 'live', 'e', 'u', 'avatars',
    'vehicles', 'bikes', 'garage', 'hazards', 'warnings', 'diagnostics', 'diag-logs', 'coupons', 'orders',
  };
  static const Set<String> _actions = {
    'accept', 'decline', 'block', 'unblock', 'feedback', 'photos', 'join', 'leave', 'polls', 'members', 'invites', 'vote', 'close',
    'status', 'summary', 'list', 'requests', 'me', 'mine', 'cancel', 'resolve', 'ack', 'download', 'view', 'request',
    'username-available', 'score', 'stats', 'avatar', 'picture', 'search', 'nearby', 'chunks', 'gpx', 'end', 'start',
  };
  static final RegExp _plainWord = RegExp(r'^[a-z][a-z_\-]{0,23}$');

  /// An API path without ids or query: '/friends/raj_rides/accept?x=1' -> '/friends/:id/accept',
  /// '/trips/G-12AB/feedback' -> '/trips/:id/feedback'.
  static String pathTemplate(String path) {
    var p = path;
    final q = p.indexOf('?');
    if (q >= 0) p = p.substring(0, q);
    final h = p.indexOf('#');
    if (h >= 0) p = p.substring(0, h);
    final segs = p.split('/');
    final out = <String>[];
    String? prev;
    for (final raw in segs) {
      if (raw.isEmpty) {
        if (out.isEmpty) out.add('');
        continue;
      }
      String seg;
      if (!_plainWord.hasMatch(raw)) {
        seg = ':id';
      } else if (prev != null && _idParents.contains(prev) && !_actions.contains(raw)) {
        seg = ':id';
      } else {
        seg = raw;
      }
      out.add(seg);
      prev = seg == ':id' ? null : seg;
      if (out.length > 12) break;
    }
    final s = out.join('/');
    return s.isEmpty ? '/' : s;
  }
}
