/// Reads a place out of whatever a rider pastes or shares into the map search:
/// map links (Google Maps, Apple Maps, OpenStreetMap, Waze), `geo:` URIs,
/// plain or DMS coordinates, full plus codes, and shared text such as
/// "Place Name\nhttps://maps.app.goo.gl/...".
///
/// Pure Dart (no Flutter, no network). Short links (maps.app.goo.gl,
/// goo.gl/maps) cannot be read on the phone: they come back with [MapLinkResult.shortUrl]
/// set and are expanded by the gateway (POST /api/geo/link, gateway/src/geo_links.js,
/// which mirrors this parser).
library;

import '../tracking/coordinate_parser.dart';

/// What [MapLinkParser.parse] found.
class MapLinkResult {
  /// The point, when the input carried one (validated: finite, in range, not 0,0).
  final double? lat;
  final double? lng;

  /// A place label found in the link or in the shared text ("Charminar").
  final String? name;

  /// Text to search for when there is no point ("Nandi Hills" from `?q=Nandi+Hills`).
  final String? query;

  /// A short link (maps.app.goo.gl / goo.gl/maps) the gateway must expand first.
  final String? shortUrl;

  /// google, apple, osm, waze, geo, coords, dms, pluscode.
  final String source;

  /// True for a dropped pin or a place's own point; false for a map view centre
  /// (`/maps/@lat,lng,zoom`, `#map=z/lat/lng`), which is only roughly where the place is.
  final bool precise;

  const MapLinkResult({this.lat, this.lng, this.name, this.query, this.shortUrl, required this.source, this.precise = true});

  bool get hasPoint => lat != null && lng != null;
  bool get needsExpansion => shortUrl != null;

  @override
  String toString() => 'MapLinkResult($source, lat: $lat, lng: $lng, name: $name, query: $query, short: $shortUrl, precise: $precise)';
}

class MapLinkParser {
  MapLinkParser._();

  /// Hosts whose short links the gateway may expand (and nothing else).
  static const Set<String> shortLinkHosts = {'maps.app.goo.gl', 'goo.gl'};

  static final RegExp _urlInText = RegExp(
    r'''(?:https?://|geo:)[^\s<>"]+|\b(?:maps\.app\.goo\.gl|goo\.gl/maps|(?:www\.)?google\.[a-z.]{2,8}/maps|maps\.google\.[a-z.]{2,8}|maps\.apple\.com|(?:www\.)?openstreetmap\.org|(?:www\.)?waze\.com)[^\s<>"]*''',
    caseSensitive: false,
  );
  static final RegExp _trailingJunk = RegExp(r'''[\].,;:!?'"»”]+$''');
  static final RegExp _num = RegExp(r'^[+-]?\d{1,3}(?:\.\d+)?$');
  static final RegExp _pair = RegExp(r'^\s*([+-]?\d{1,2}(?:\.\d+)?)\s*,\s*([+-]?\d{1,3}(?:\.\d+)?)\s*(?:\((.*)\))?\s*$');
  static final RegExp _strictDecimal = RegExp(
    r'^\s*\(?\s*(?:lat(?:itude)?\s*[:=]?\s*)?([+-]?\d{1,2}\.\d+)\s*°?\s*([NSns])?\s*[,;/\s]\s*(?:lo?ng?(?:itude)?\s*[:=]?\s*)?([+-]?\d{1,3}\.\d+)\s*°?\s*([EWew])?\s*\)?\s*$',
  );
  static final RegExp _dmsHint = RegExp(r'''[°'"′″]|\d\s*[NSEWnsew]\b''');
  static final RegExp _plusCode = RegExp(r'^([23456789CFGHJMPQRVWX]{8})\+([23456789CFGHJMPQRVWX]{2,7})\b', caseSensitive: false);
  static final RegExp _data3d4d = RegExp(r'!3d(-?\d{1,2}(?:\.\d+)?)!4d(-?\d{1,3}(?:\.\d+)?)');
  static final RegExp _data1d2d = RegExp(r'!1d(-?\d{1,3}(?:\.\d+)?)!2d(-?\d{1,2}(?:\.\d+)?)');
  static final RegExp _atView = RegExp(r'@(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)');

  /// Reads [input]. Returns null when it holds no map link, coordinates or plus code
  /// (the caller then runs a normal text search).
  static MapLinkResult? parse(String? input) {
    if (input == null) return null;
    final text = input.trim();
    if (text.isEmpty || text.length > 4000) return null;

    final urlMatch = _urlInText.firstMatch(text);
    if (urlMatch != null) {
      final raw = _trimUrl(urlMatch.group(0)!);
      final label = _labelOf(text.replaceRange(urlMatch.start, urlMatch.end, ' '));
      final r = parseUrl(raw);
      if (r != null) {
        if (r.name == null && label != null) {
          return MapLinkResult(lat: r.lat, lng: r.lng, name: label, query: r.query ?? (r.hasPoint ? null : label), shortUrl: r.shortUrl, source: r.source, precise: r.precise);
        }
        return r;
      }
      // A link we cannot read, with a place name next to it: search for the name.
      if (label != null && _isMapHost(raw)) return MapLinkResult(query: label, name: label, source: 'text');
      return null;
    }
    return parseCoordinates(text);
  }

  /// Plain coordinates ("12.97, 77.59", "12.97 77.59", "12.97N 77.59E"), DMS
  /// (12°58'16"N 77°35'38"E) or a full plus code (7J4VXHFR+2C). Null otherwise.
  static MapLinkResult? parseCoordinates(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;
    final m = _strictDecimal.firstMatch(text);
    if (m != null) {
      var a = double.parse(m.group(1)!);
      var b = double.parse(m.group(3)!);
      final ns = m.group(2)?.toUpperCase();
      final ew = m.group(4)?.toUpperCase();
      if (ns == 'S') a = -a.abs();
      if (ew == 'W') b = -b.abs();
      final p = _point(a, b, 'coords');
      if (p != null) return p;
    }
    if (_dmsHint.hasMatch(text)) {
      final c = CoordinateParser.tryParse(text);
      if (c != null) {
        final p = _point(c.$1, c.$2, text.contains('°') || text.contains("'") ? 'dms' : 'coords');
        if (p != null) return p;
      }
    }
    final pc = _plusCode.firstMatch(text.toUpperCase());
    if (pc != null) {
      final d = decodePlusCode('${pc.group(1)}+${pc.group(2)}');
      if (d != null) {
        final rest = _labelOf(text.substring(pc.end));
        return MapLinkResult(lat: d.$1, lng: d.$2, name: rest, source: 'pluscode');
      }
    }
    return null;
  }

  /// One link (no surrounding text). Null when it is not a map link we can read.
  static MapLinkResult? parseUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.toLowerCase().startsWith('geo:')) return _geo(s);
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(s)) s = 'https://$s';
    final Uri u;
    try {
      u = Uri.parse(s);
    } catch (_) {
      return null;
    }
    final host = u.host.toLowerCase();
    if (host == 'maps.app.goo.gl' && u.pathSegments.any((e) => e.isNotEmpty)) {
      return MapLinkResult(shortUrl: u.toString(), source: 'google');
    }
    if (host == 'goo.gl' && u.pathSegments.isNotEmpty && u.pathSegments.first == 'maps' && u.pathSegments.length > 1) {
      return MapLinkResult(shortUrl: u.toString(), source: 'google');
    }
    try {
      if (_isGoogle(host)) return _google(u, s);
      if (host == 'maps.apple.com' || host == 'beta.maps.apple.com') return _apple(u);
      if (host.endsWith('openstreetmap.org') || host == 'osm.org' || host == 'www.osm.org') return _osm(u);
      if (host == 'waze.com' || host == 'www.waze.com' || host == 'ul.waze.com') return _waze(u);
    } catch (_) {
      // Broken percent-encoding somewhere in the link.
    }
    return null;
  }

  // ------------------------------------------------------------------ providers

  static bool _isGoogle(String host) {
    final h = host.startsWith('www.') ? host.substring(4) : host;
    return RegExp(r'^(?:maps\.)?google\.(?:com|co\.[a-z]{2}|com\.[a-z]{2}|[a-z]{2})$').hasMatch(h);
  }

  static bool _isMapHost(String raw) {
    final l = raw.toLowerCase();
    return l.contains('goo.gl') || l.contains('google.') || l.contains('apple.com') || l.contains('openstreetmap') || l.contains('waze') || l.startsWith('geo:');
  }

  static MapLinkResult? _google(Uri u, String rawUrl) {
    final isMaps = u.host.toLowerCase().contains('maps.') || (u.pathSegments.isNotEmpty && u.pathSegments.first == 'maps');
    if (!isMaps) return null;
    final segs = u.pathSegments.where((e) => e.isNotEmpty).toList();
    final kind = segs.length > 1 ? segs[1] : '';
    final qp = _query(u);
    final full = _decodeFull(rawUrl);

    // The place's own pin in the data blob (!3dLAT!4dLNG): the most exact point there is.
    final pins = _data3d4d.allMatches(full).toList();
    final pin = pins.isEmpty ? null : _point(double.parse(pins.last.group(1)!), double.parse(pins.last.group(2)!), 'google');

    if (kind == 'dir') {
      // /maps/dir/<from>/<to>/@...: the destination is the last stop.
      final stops = segs.skip(2).where((e) => !e.startsWith('@') && !e.startsWith('data=') && !e.startsWith('am=')).toList();
      final dest = qp['destination'] ?? qp['daddr'] ?? (stops.isNotEmpty ? _segText(stops.last) : null);
      final wps = _data1d2d.allMatches(full).toList();
      final wpPoint = wps.isEmpty ? null : _point(double.parse(wps.last.group(2)!), double.parse(wps.last.group(1)!), 'google');
      if (dest != null && dest.isNotEmpty) {
        final c = _textPoint(dest);
        if (c != null) return c;
        if (wpPoint != null) return MapLinkResult(lat: wpPoint.lat, lng: wpPoint.lng, name: _clean(dest), source: 'google');
        return MapLinkResult(query: _clean(dest), name: _clean(dest), source: 'google');
      }
      return wpPoint;
    }

    if (kind == 'place' || kind == 'search') {
      final nameSeg = segs.length > 2 && !segs[2].startsWith('@') && !segs[2].startsWith('data=') ? _segText(segs[2]) : (qp['query'] ?? qp['q']);
      final c = nameSeg == null ? null : _textPoint(nameSeg);
      if (c != null) return c; // a dropped pin: the name is its coordinates
      final name = nameSeg == null ? null : _clean(nameSeg);
      if (pin != null) return MapLinkResult(lat: pin.lat, lng: pin.lng, name: name, source: 'google');
      final view = _atView.firstMatch(full);
      if (kind == 'place' && view != null) {
        final p = _point(double.parse(view.group(1)!), double.parse(view.group(2)!), 'google');
        if (p != null) return MapLinkResult(lat: p.lat, lng: p.lng, name: name, source: 'google', precise: name == null ? false : true);
      }
      if (name != null && name.isNotEmpty) return MapLinkResult(query: name, name: name, source: 'google');
    }

    // ?q= / ?query= / ?ll= / ?destination= / ?daddr= / ?center=
    for (final k in const ['q', 'query', 'destination', 'daddr', 'll', 'center', 'sll']) {
      final v = qp[k];
      if (v == null || v.trim().isEmpty) continue;
      final c = _textPoint(v);
      if (c != null) {
        final precise = k != 'center' && k != 'sll';
        return MapLinkResult(lat: c.lat, lng: c.lng, name: c.name, source: 'google', precise: precise);
      }
      if (k == 'll' || k == 'center' || k == 'sll' || _pair.hasMatch(v)) continue; // out-of-range numbers are no name
      final name = _clean(v);
      if (name.isEmpty) continue;
      if (pin != null) return MapLinkResult(lat: pin.lat, lng: pin.lng, name: name, source: 'google');
      return MapLinkResult(query: name, name: name, source: 'google');
    }
    if (pin != null) return pin;

    // /maps/@lat,lng,zoom: only the map view.
    final view = _atView.firstMatch(full);
    if (view != null) {
      final p = _point(double.parse(view.group(1)!), double.parse(view.group(2)!), 'google');
      if (p != null) return MapLinkResult(lat: p.lat, lng: p.lng, source: 'google', precise: false);
    }
    return null;
  }

  static MapLinkResult? _apple(Uri u) {
    final qp = _query(u);
    final rawName = qp['name'] ?? qp['q'];
    final name = rawName != null && _textPoint(rawName) == null && _clean(rawName).isNotEmpty ? _clean(rawName) : null;
    for (final k in const ['coordinate', 'll', 'daddr', 'q']) {
      final v = qp[k];
      if (v == null || v.trim().isEmpty) continue;
      final c = _textPoint(v);
      if (c != null) return MapLinkResult(lat: c.lat, lng: c.lng, name: name, source: 'apple');
    }
    final text = qp['daddr'] ?? qp['address'] ?? name;
    if (text != null && _clean(text).isNotEmpty) return MapLinkResult(query: _clean(text), name: _clean(text), source: 'apple');
    // Only the search area (sll): roughly there.
    final sll = qp['sll'] == null ? null : _textPoint(qp['sll']!);
    if (sll != null) return MapLinkResult(lat: sll.lat, lng: sll.lng, source: 'apple', precise: false);
    return null;
  }

  static MapLinkResult? _osm(Uri u) {
    final qp = _query(u);
    final mlat = double.tryParse(qp['mlat'] ?? ''), mlon = double.tryParse(qp['mlon'] ?? '');
    if (mlat != null && mlon != null) {
      final p = _point(mlat, mlon, 'osm');
      if (p != null) return p;
    }
    final frag = u.fragment;
    final m = RegExp(r'map=\d{1,2}(?:\.\d+)?/(-?\d{1,2}(?:\.\d+)?)/(-?\d{1,3}(?:\.\d+)?)').firstMatch(frag);
    if (m != null) {
      final p = _point(double.parse(m.group(1)!), double.parse(m.group(2)!), 'osm');
      if (p != null) return MapLinkResult(lat: p.lat, lng: p.lng, source: 'osm', precise: false);
    }
    final lat = double.tryParse(qp['lat'] ?? ''), lon = double.tryParse(qp['lon'] ?? '');
    if (lat != null && lon != null) {
      final p = _point(lat, lon, 'osm');
      if (p != null) return MapLinkResult(lat: p.lat, lng: p.lng, source: 'osm', precise: false);
    }
    final q = qp['query'];
    if (q != null && q.trim().isNotEmpty) {
      final c = _textPoint(q);
      if (c != null) return MapLinkResult(lat: c.lat, lng: c.lng, source: 'osm');
      return MapLinkResult(query: _clean(q), name: _clean(q), source: 'osm');
    }
    return null;
  }

  static MapLinkResult? _waze(Uri u) {
    final qp = _query(u);
    for (final k in const ['ll', 'to', 'latlng']) {
      var v = qp[k];
      if (v == null) continue;
      if (v.startsWith('ll.')) v = v.substring(3);
      final c = _textPoint(v);
      if (c != null) return MapLinkResult(lat: c.lat, lng: c.lng, source: 'waze');
    }
    final q = qp['q'];
    if (q != null && _clean(q).isNotEmpty) return MapLinkResult(query: _clean(q), name: _clean(q), source: 'waze');
    return null;
  }

  /// geo:lat,lng[;u=..][?q=...], geo:0,0?q=lat,lng(Label), geo:0,0?q=Name
  static MapLinkResult? _geo(String raw) {
    final body = raw.substring(4);
    final qi = body.indexOf('?');
    final coordPart = (qi >= 0 ? body.substring(0, qi) : body).split(';').first;
    final qs = qi >= 0 ? body.substring(qi + 1) : '';
    String? q;
    for (final part in qs.split('&')) {
      final eq = part.indexOf('=');
      if (eq > 0 && part.substring(0, eq).toLowerCase() == 'q') q = _decode(part.substring(eq + 1));
    }
    if (q != null && q.trim().isNotEmpty) {
      final m = _pair.firstMatch(q);
      if (m != null) {
        final p = _point(double.parse(m.group(1)!), double.parse(m.group(2)!), 'geo');
        if (p != null) {
          final label = m.group(3) == null ? null : _clean(m.group(3)!);
          return MapLinkResult(lat: p.lat, lng: p.lng, name: (label?.isEmpty ?? true) ? null : label, source: 'geo');
        }
      }
    }
    final parts = coordPart.split(',');
    if (parts.length >= 2 && _num.hasMatch(parts[0].trim()) && _num.hasMatch(parts[1].trim())) {
      final p = _point(double.parse(parts[0]), double.parse(parts[1]), 'geo');
      if (p != null) {
        final n = q == null || q.trim().isEmpty ? null : _clean(q);
        return MapLinkResult(lat: p.lat, lng: p.lng, name: n, source: 'geo');
      }
    }
    if (q != null && _clean(q).isNotEmpty) return MapLinkResult(query: _clean(q), name: _clean(q), source: 'geo');
    return null;
  }

  // ------------------------------------------------------------------ plus codes

  static const String _pcAlphabet = '23456789CFGHJMPQRVWX';

  /// Centre of a full (global) Open Location Code such as "7J4VXHFR+2C". Null for
  /// short codes (they need a nearby town) and invalid codes.
  static (double, double)? decodePlusCode(String code) {
    final c = code.toUpperCase().replaceAll('+', '').replaceAll(RegExp(r'0+$'), '');
    if (c.length < 8 || c.length > 15 || code.indexOf('+') != 8 || (c.length < 10 && c.length.isOdd)) return null;
    for (final ch in c.split('')) {
      if (!_pcAlphabet.contains(ch)) return null;
    }
    if (_pcAlphabet.indexOf(c[0]) > 8 || _pcAlphabet.indexOf(c[1]) > 17) return null;
    var lat = -90.0, lng = -180.0;
    var res = 20.0;
    var i = 0;
    for (; i < 10 && i + 1 < c.length; i += 2) {
      lat += _pcAlphabet.indexOf(c[i]) * res;
      lng += _pcAlphabet.indexOf(c[i + 1]) * res;
      if (i + 2 < 10 && i + 3 <= c.length) res /= 20;
    }
    var latRes = res, lngRes = res;
    for (; i < c.length; i++) {
      latRes /= 5;
      lngRes /= 4;
      final d = _pcAlphabet.indexOf(c[i]);
      lat += (d ~/ 4) * latRes;
      lng += (d % 4) * lngRes;
    }
    final out = (lat + latRes / 2, lng + lngRes / 2);
    return _valid(out.$1, out.$2) ? out : null;
  }

  // ------------------------------------------------------------------ helpers

  static bool _valid(double lat, double lng) =>
      lat.isFinite && lng.isFinite && lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180 && !(lat == 0 && lng == 0);

  static MapLinkResult? _point(double lat, double lng, String source) => _valid(lat, lng) ? MapLinkResult(lat: lat, lng: lng, source: source) : null;

  /// "12.97,77.59", "12.97, 77.59 (Label)", DMS: a point; null for a name.
  static MapLinkResult? _textPoint(String v) {
    final t = v.trim();
    final m = _pair.firstMatch(t);
    if (m != null) {
      final p = _point(double.parse(m.group(1)!), double.parse(m.group(2)!), 'coords');
      if (p == null) return null;
      final label = m.group(3) == null ? null : _clean(m.group(3)!);
      return MapLinkResult(lat: p.lat, lng: p.lng, name: (label?.isEmpty ?? true) ? null : label, source: 'coords');
    }
    return parseCoordinates(t);
  }

  static Map<String, String> _query(Uri u) {
    final out = <String, String>{};
    try {
      u.queryParametersAll.forEach((k, v) {
        if (v.isNotEmpty) out[k.toLowerCase()] = v.first;
      });
    } catch (_) {
      // Broken percent-encoding: read it by hand.
      for (final part in u.query.split('&')) {
        final eq = part.indexOf('=');
        if (eq > 0) out[part.substring(0, eq).toLowerCase()] = _decode(part.substring(eq + 1));
      }
    }
    return out;
  }

  /// Drops sentence punctuation after a link; a ")" only when it has no "(" in the link.
  static String _trimUrl(String raw) {
    var s = raw;
    while (true) {
      final before = s;
      s = s.replaceFirst(_trailingJunk, '');
      if (s.endsWith(')') && '('.allMatches(s).length < ')'.allMatches(s).length) s = s.substring(0, s.length - 1);
      if (s == before) return s;
    }
  }

  static String _decodeFull(String s) {
    try {
      return Uri.decodeFull(s);
    } catch (_) {
      return s;
    }
  }

  static String _decode(String s) {
    final plus = s.replaceAll('+', ' ');
    try {
      return Uri.decodeComponent(plus);
    } catch (_) {
      return plus;
    }
  }

  /// A path segment as text: Uri already decoded %xx; Google uses + for spaces.
  static String _segText(String seg) => seg.replaceAll('+', ' ').trim();

  static String _clean(String s) {
    var t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length > 120) t = t.substring(0, 120).trim();
    return t;
  }

  /// The first meaningful line of shared text around a link ("Charminar"), or null.
  static String? _labelOf(String rest) {
    for (final line in rest.split(RegExp(r'[\r\n]+'))) {
      var t = line.replaceAll(RegExp(r'\s+'), ' ').trim();
      t = t.replaceFirst(RegExp(r'^[\-–—:|•·,]+\s*'), '').replaceFirst(RegExp(r'\s*[\-–—:|•·,]+$'), '').trim();
      if (t.isEmpty) continue;
      if (RegExp(r'^(?:shared?|check out|see|view|open)(?: this| location| place)?(?: on| in| with)?(?: google maps| maps)?:?$', caseSensitive: false).hasMatch(t)) continue;
      if (t.length > 100) t = t.substring(0, 100).trim();
      return t;
    }
    return null;
  }
}
