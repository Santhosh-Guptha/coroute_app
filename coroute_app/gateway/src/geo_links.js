'use strict';
/**
 * 3.56 map links: reads a place out of a pasted or shared map link, and expands Google short
 * links (maps.app.goo.gl, goo.gl/maps), which the phone cannot read on its own.
 *
 * Mirrors lib/domain/geo/map_link_parser.dart (same formats, same answers):
 *   Google Maps  /maps/place/Name/@lat,lng,z/data=...!3dLAT!4dLNG, /maps/@lat,lng,z, ?q=lat,lng,
 *                ?q=Name, ?ll=, /maps/search/..., /maps/dir/.../<destination>, short links
 *   geo:lat,lng?q=..., geo:0,0?q=lat,lng(Label)
 *   Apple Maps   ?ll=&q=, ?coordinate=&name=, ?address=
 *   OpenStreetMap ?mlat=&mlon=, #map=z/lat/lng
 *   Waze         /ul?ll=lat,lng, ?to=ll.lat,lng, ?q=
 *   plain "12.97, 77.59", "12.97 77.59", DMS, full plus codes
 *
 * Short-link expansion follows redirects by hand (redirect: 'manual'), only between allowlisted
 * Google hosts, at most 5 hops, 5 s in all, with no cookies, and never reads a response body.
 * Nothing about the link is logged.
 */

const SHORT_HOSTS = new Set(['maps.app.goo.gl', 'goo.gl']);
/** Hosts a short link may redirect through (and nothing else is ever fetched). */
const EXPAND_HOSTS = new Set([
  'maps.app.goo.gl', 'goo.gl',
  'www.google.com', 'google.com', 'maps.google.com',
  'www.google.co.in', 'google.co.in', 'maps.google.co.in',
]);
const MAX_REDIRECTS = 5;
const EXPAND_TIMEOUT_MS = 5000;

const URL_IN_TEXT = /(?:https?:\/\/|geo:)[^\s<>"]+|\b(?:maps\.app\.goo\.gl|goo\.gl\/maps|(?:www\.)?google\.[a-z.]{2,8}\/maps|maps\.google\.[a-z.]{2,8}|maps\.apple\.com|(?:www\.)?openstreetmap\.org|(?:www\.)?waze\.com)[^\s<>"]*/i;
const TRAILING_JUNK = /[\].,;:!?'"»”]+$/;
const NUM = /^[+-]?\d{1,3}(?:\.\d+)?$/;
const PAIR = /^\s*([+-]?\d{1,2}(?:\.\d+)?)\s*,\s*([+-]?\d{1,3}(?:\.\d+)?)\s*(?:\((.*)\))?\s*$/;
const STRICT_DECIMAL = /^\s*\(?\s*(?:lat(?:itude)?\s*[:=]?\s*)?([+-]?\d{1,2}\.\d+)\s*°?\s*([NSns])?\s*[,;/\s]\s*(?:lo?ng?(?:itude)?\s*[:=]?\s*)?([+-]?\d{1,3}\.\d+)\s*°?\s*([EWew])?\s*\)?\s*$/;
const DMS = /(\d{1,2})[°\s]+(\d{1,2})['`′\s]+(\d{1,2}(?:\.\d+)?)["″\s]*([NSEWnsew])[\s,;]+(\d{1,3})[°\s]+(\d{1,2})['`′\s]+(\d{1,2}(?:\.\d+)?)["″\s]*([NSEWnsew])/;
const LETTERED = /^[^\d+-]*([+-]?\d{1,3}(?:\.\d+)?)\s*°?\s*([NSEWnsew])[\s,;]+([+-]?\d{1,3}(?:\.\d+)?)\s*°?\s*([NSEWnsew])[^\d]*$/;
const PLUS_CODE = /^([23456789CFGHJMPQRVWX]{8})\+([23456789CFGHJMPQRVWX]{2,7})\b/i;
const DATA_3D4D = /!3d(-?\d{1,2}(?:\.\d+)?)!4d(-?\d{1,3}(?:\.\d+)?)/g;
const DATA_1D2D = /!1d(-?\d{1,3}(?:\.\d+)?)!2d(-?\d{1,2}(?:\.\d+)?)/g;
const AT_VIEW = /@(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)/;

const valid = (lat, lng) => Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180 && !(lat === 0 && lng === 0);
const point = (lat, lng, source, extra = {}) => (valid(lat, lng) ? { lat, lng, source, precise: true, ...extra } : null);
const clean = (s) => String(s || '').replace(/\s+/g, ' ').trim().slice(0, 120).trim();
const safeDecode = (s) => { try { return decodeURIComponent(s); } catch { return s; } };
const segText = (s) => safeDecode(String(s).replace(/\+/g, ' ')).trim();

function trimUrl(raw) {
  let s = raw;
  for (;;) {
    const before = s;
    s = s.replace(TRAILING_JUNK, '');
    if (s.endsWith(')') && (s.match(/\(/g) || []).length < (s.match(/\)/g) || []).length) s = s.slice(0, -1);
    if (s === before) return s;
  }
}

function labelOf(rest) {
  for (const line of String(rest || '').split(/[\r\n]+/)) {
    let t = line.replace(/\s+/g, ' ').trim();
    t = t.replace(/^[-–—:|•·,]+\s*/, '').replace(/\s*[-–—:|•·,]+$/, '').trim();
    if (!t) continue;
    if (/^(?:shared?|check out|see|view|open)(?: this| location| place)?(?: on| in| with)?(?: google maps| maps)?:?$/i.test(t)) continue;
    return t.slice(0, 100).trim();
  }
  return null;
}

function query(u) {
  const out = {};
  try {
    for (const [k, v] of u.searchParams) if (v !== '' && !(k.toLowerCase() in out)) out[k.toLowerCase()] = v;
  } catch { /* unreadable query */ }
  return out;
}

/** Full Open Location Code ("7J4VXHFR+2C") to its centre [lat, lng], or null. */
function decodePlusCode(code) {
  const A = '23456789CFGHJMPQRVWX';
  const up = String(code || '').toUpperCase();
  const c = up.replace('+', '').replace(/0+$/, '');
  if (c.length < 8 || c.length > 15 || up.indexOf('+') !== 8 || (c.length < 10 && c.length % 2)) return null;
  if ([...c].some((ch) => !A.includes(ch))) return null;
  if (A.indexOf(c[0]) > 8 || A.indexOf(c[1]) > 17) return null;
  let lat = -90, lng = -180, res = 20, i = 0;
  for (; i < 10 && i + 1 < c.length; i += 2) {
    lat += A.indexOf(c[i]) * res;
    lng += A.indexOf(c[i + 1]) * res;
    if (i + 2 < 10 && i + 3 <= c.length) res /= 20;
  }
  let latRes = res, lngRes = res;
  for (; i < c.length; i++) {
    latRes /= 5; lngRes /= 4;
    const d = A.indexOf(c[i]);
    lat += Math.floor(d / 4) * latRes;
    lng += (d % 4) * lngRes;
  }
  const out = [lat + latRes / 2, lng + lngRes / 2];
  return valid(out[0], out[1]) ? out : null;
}

/** Plain decimal, lettered, DMS coordinates or a full plus code. */
function parseCoordinates(input) {
  const text = String(input || '').trim();
  if (!text) return null;
  let m = STRICT_DECIMAL.exec(text);
  if (m) {
    let a = Number(m[1]), b = Number(m[3]);
    if ((m[2] || '').toUpperCase() === 'S') a = -Math.abs(a);
    if ((m[4] || '').toUpperCase() === 'W') b = -Math.abs(b);
    const p = point(a, b, 'coords');
    if (p) return p;
  }
  m = DMS.exec(text);
  if (m) {
    const v = (d, mi, s, dir) => { const x = Number(d) + Number(mi) / 60 + Number(s) / 3600; return /[SW]/i.test(dir) ? -x : x; };
    const a = v(m[1], m[2], m[3], m[4]), b = v(m[5], m[6], m[7], m[8]);
    const latFirst = /[NS]/i.test(m[4]);
    const p = point(latFirst ? a : b, latFirst ? b : a, 'dms');
    if (p) return p;
  }
  m = LETTERED.exec(text);
  if (m) {
    const sign = (n, dir) => (/[SW]/i.test(dir) ? -Math.abs(Number(n)) : Math.abs(Number(n)));
    const a = sign(m[1], m[2]), b = sign(m[3], m[4]);
    const latFirst = /[NS]/i.test(m[2]);
    const p = point(latFirst ? a : b, latFirst ? b : a, 'coords');
    if (p) return p;
  }
  m = PLUS_CODE.exec(text.toUpperCase());
  if (m) {
    const d = decodePlusCode(`${m[1]}+${m[2]}`);
    if (d) return { lat: d[0], lng: d[1], source: 'pluscode', precise: true, ...(labelOf(text.slice(m[0].length)) ? { name: labelOf(text.slice(m[0].length)) } : {}) };
  }
  return null;
}

function textPoint(v) {
  const t = String(v || '').trim();
  const m = PAIR.exec(t);
  if (m) {
    const p = point(Number(m[1]), Number(m[2]), 'coords');
    if (!p) return null;
    const label = m[3] ? clean(m[3]) : '';
    return label ? { ...p, name: label } : p;
  }
  return parseCoordinates(t);
}

const isGoogleHost = (host) => /^(?:maps\.)?google\.(?:com|co\.[a-z]{2}|com\.[a-z]{2}|[a-z]{2})$/.test(host.replace(/^www\./, ''));
const isMapHost = (raw) => /goo\.gl|google\.|apple\.com|openstreetmap|waze|^geo:/i.test(raw);

function lastMatch(re, s) { let last = null; for (const m of s.matchAll(re)) last = m; return last; }

function google(u, rawUrl) {
  const segs = u.pathname.split('/').filter(Boolean);
  const isMaps = u.hostname.includes('maps.') || segs[0] === 'maps';
  if (!isMaps) return null;
  const kind = segs[1] || '';
  const qp = query(u);
  const full = safeDecode(rawUrl);
  const pm = lastMatch(DATA_3D4D, full);
  const pin = pm ? point(Number(pm[1]), Number(pm[2]), 'google') : null;
  const out = (o) => ({ source: 'google', precise: true, ...o });

  if (kind === 'dir') {
    const stops = segs.slice(2).filter((e) => !e.startsWith('@') && !e.startsWith('data=') && !e.startsWith('am='));
    const dest = qp.destination || qp.daddr || (stops.length ? segText(stops[stops.length - 1]) : null);
    const wm = lastMatch(DATA_1D2D, full);
    const wp = wm ? point(Number(wm[2]), Number(wm[1]), 'google') : null;
    if (dest) {
      const c = textPoint(dest);
      if (c) return c;
      if (wp) return out({ lat: wp.lat, lng: wp.lng, name: clean(dest) });
      return out({ query: clean(dest), name: clean(dest) });
    }
    return wp;
  }

  if (kind === 'place' || kind === 'search') {
    const nameSeg = segs.length > 2 && !segs[2].startsWith('@') && !segs[2].startsWith('data=') ? segText(segs[2]) : (qp.query || qp.q || null);
    const c = nameSeg ? textPoint(nameSeg) : null;
    if (c) return c;
    const name = nameSeg ? clean(nameSeg) : null;
    if (pin) return out({ lat: pin.lat, lng: pin.lng, ...(name ? { name } : {}) });
    const view = AT_VIEW.exec(full);
    if (kind === 'place' && view) {
      const p = point(Number(view[1]), Number(view[2]), 'google');
      if (p) return out({ lat: p.lat, lng: p.lng, ...(name ? { name } : {}), precise: !!name });
    }
    if (name) return out({ query: name, name });
  }

  for (const k of ['q', 'query', 'destination', 'daddr', 'll', 'center', 'sll']) {
    const v = qp[k];
    if (!v || !v.trim()) continue;
    const c = textPoint(v);
    if (c) return out({ lat: c.lat, lng: c.lng, ...(c.name ? { name: c.name } : {}), precise: k !== 'center' && k !== 'sll' });
    if (k === 'll' || k === 'center' || k === 'sll' || PAIR.test(v)) continue;
    const name = clean(v);
    if (!name) continue;
    if (pin) return out({ lat: pin.lat, lng: pin.lng, name });
    return out({ query: name, name });
  }
  if (pin) return pin;
  const view = AT_VIEW.exec(full);
  if (view) {
    const p = point(Number(view[1]), Number(view[2]), 'google');
    if (p) return out({ lat: p.lat, lng: p.lng, precise: false });
  }
  return null;
}

function apple(u) {
  const qp = query(u);
  const rawName = qp.name || qp.q;
  const name = rawName && !textPoint(rawName) && clean(rawName) ? clean(rawName) : null;
  for (const k of ['coordinate', 'll', 'daddr', 'q']) {
    const v = qp[k];
    if (!v || !v.trim()) continue;
    const c = textPoint(v);
    if (c) return { lat: c.lat, lng: c.lng, source: 'apple', precise: true, ...(name ? { name } : {}) };
  }
  const text = qp.daddr || qp.address || name;
  if (text && clean(text)) return { query: clean(text), name: clean(text), source: 'apple', precise: true };
  const sll = qp.sll ? textPoint(qp.sll) : null;
  if (sll) return { lat: sll.lat, lng: sll.lng, source: 'apple', precise: false };
  return null;
}

function osm(u) {
  const qp = query(u);
  if (qp.mlat && qp.mlon) {
    const p = point(Number(qp.mlat), Number(qp.mlon), 'osm');
    if (p) return p;
  }
  const m = /map=\d{1,2}(?:\.\d+)?\/(-?\d{1,2}(?:\.\d+)?)\/(-?\d{1,3}(?:\.\d+)?)/.exec(u.hash || '');
  if (m) {
    const p = point(Number(m[1]), Number(m[2]), 'osm', { precise: false });
    if (p) return p;
  }
  if (qp.lat && qp.lon) {
    const p = point(Number(qp.lat), Number(qp.lon), 'osm', { precise: false });
    if (p) return p;
  }
  if (qp.query && qp.query.trim()) {
    const c = textPoint(qp.query);
    if (c) return { lat: c.lat, lng: c.lng, source: 'osm', precise: true };
    return { query: clean(qp.query), name: clean(qp.query), source: 'osm', precise: true };
  }
  return null;
}

function waze(u) {
  const qp = query(u);
  for (const k of ['ll', 'to', 'latlng']) {
    let v = qp[k];
    if (!v) continue;
    if (v.startsWith('ll.')) v = v.slice(3);
    const c = textPoint(v);
    if (c) return { lat: c.lat, lng: c.lng, source: 'waze', precise: true };
  }
  if (qp.q && clean(qp.q)) return { query: clean(qp.q), name: clean(qp.q), source: 'waze', precise: true };
  return null;
}

function geoUri(raw) {
  const body = raw.slice(4);
  const qi = body.indexOf('?');
  const coordPart = (qi >= 0 ? body.slice(0, qi) : body).split(';')[0];
  const qs = qi >= 0 ? body.slice(qi + 1) : '';
  let q = null;
  for (const part of qs.split('&')) {
    const eq = part.indexOf('=');
    if (eq > 0 && part.slice(0, eq).toLowerCase() === 'q') q = safeDecode(part.slice(eq + 1).replace(/\+/g, ' '));
  }
  if (q && q.trim()) {
    const m = PAIR.exec(q);
    if (m) {
      const p = point(Number(m[1]), Number(m[2]), 'geo');
      if (p) return m[3] && clean(m[3]) ? { ...p, name: clean(m[3]) } : p;
    }
  }
  const parts = coordPart.split(',');
  if (parts.length >= 2 && NUM.test(parts[0].trim()) && NUM.test(parts[1].trim())) {
    const p = point(Number(parts[0]), Number(parts[1]), 'geo');
    if (p) return q && clean(q) ? { ...p, name: clean(q) } : p;
  }
  if (q && clean(q)) return { query: clean(q), name: clean(q), source: 'geo', precise: true };
  return null;
}

/** One link. Returns { lat, lng, name?, source, precise } | { query, name, source } | { shortUrl, source } | null. */
function parseUrl(raw) {
  let s = String(raw || '').trim();
  if (!s) return null;
  if (/^geo:/i.test(s)) return geoUri(s);
  if (!/^https?:\/\//i.test(s)) s = `https://${s}`;
  let u;
  try { u = new URL(s); } catch { return null; }
  const host = u.hostname.toLowerCase();
  const segs = u.pathname.split('/').filter(Boolean);
  if (host === 'maps.app.goo.gl' && segs.length) return { shortUrl: u.toString(), source: 'google' };
  if (host === 'goo.gl' && segs[0] === 'maps' && segs.length > 1) return { shortUrl: u.toString(), source: 'google' };
  try {
    if (isGoogleHost(host)) return google(u, s);
    if (host === 'maps.apple.com' || host === 'beta.maps.apple.com') return apple(u);
    if (host.endsWith('openstreetmap.org') || host === 'osm.org' || host === 'www.osm.org') return osm(u);
    if (host === 'waze.com' || host === 'www.waze.com' || host === 'ul.waze.com') return waze(u);
  } catch { /* unreadable link */ }
  return null;
}

/** Shared text or a link: see the file comment. Null when there is no map link or coordinates. */
function parseMapText(input) {
  const text = String(input || '').trim();
  if (!text || text.length > 4000) return null;
  const m = URL_IN_TEXT.exec(text);
  if (m) {
    const raw = trimUrl(m[0]);
    const label = labelOf(text.slice(0, m.index) + ' ' + text.slice(m.index + m[0].length));
    const r = parseUrl(raw);
    if (r) {
      if (!r.name && label) {
        const hasPoint = Number.isFinite(r.lat);
        return { ...r, name: label, ...(hasPoint ? {} : { query: r.query || label }) };
      }
      return r;
    }
    if (label && isMapHost(raw)) return { query: label, name: label, source: 'text', precise: true };
    return null;
  }
  return parseCoordinates(text);
}

/** True when [url] may be fetched while expanding a short link. */
function expandAllowed(url) {
  try {
    const u = new URL(url);
    return u.protocol === 'https:' && EXPAND_HOSTS.has(u.hostname.toLowerCase()) && !u.username && !u.password && (!u.port || u.port === '443');
  } catch { return false; }
}

/**
 * Follows a short link's redirects (HEAD-like: the body is never read) until it lands on a Google
 * Maps URL we can parse. Returns the final URL, or throws { code: 'LINK_NOT_ALLOWED' |
 * 'LINK_TOO_MANY_REDIRECTS' | 'LINK_UNREACHABLE' | 'LINK_TIMEOUT' }.
 */
async function expandShortLink(url, { fetchImpl = globalThis.fetch, userAgent = 'CoRoute', timeoutMs = EXPAND_TIMEOUT_MS, maxRedirects = MAX_REDIRECTS } = {}) {
  const fail = (code) => Object.assign(new Error(code), { code });
  let current = String(url || '');
  if (!expandAllowed(current) || !SHORT_HOSTS.has(new URL(current).hostname.toLowerCase())) throw fail('LINK_NOT_ALLOWED');
  const deadline = Date.now() + timeoutMs;
  for (let hop = 0; hop <= maxRedirects; hop++) {
    const left = deadline - Date.now();
    if (left <= 0) throw fail('LINK_TIMEOUT');
    let res;
    try {
      res = await fetchImpl(current, {
        method: 'GET', redirect: 'manual', credentials: 'omit',
        headers: { 'User-Agent': userAgent, Accept: 'text/html,application/xhtml+xml' },
        signal: AbortSignal.timeout(left),
      });
    } catch (e) {
      throw fail(e && (e.name === 'TimeoutError' || e.name === 'AbortError') ? 'LINK_TIMEOUT' : 'LINK_UNREACHABLE');
    }
    try { res.body?.cancel?.(); } catch { /* nothing to drop */ }
    const status = Number(res.status);
    if (status >= 300 && status < 400) {
      const loc = res.headers?.get?.('location');
      if (!loc) throw fail('LINK_UNREACHABLE');
      let next;
      try { next = new URL(loc, current).toString(); } catch { throw fail('LINK_UNREACHABLE'); }
      // EU consent wall: the real link is in ?continue= (never fetched).
      try {
        const nu = new URL(next);
        if (nu.hostname === 'consent.google.com' && nu.searchParams.get('continue')) next = nu.searchParams.get('continue');
      } catch { /* keep next */ }
      if (!expandAllowed(next)) throw fail('LINK_NOT_ALLOWED');
      const parsed = parseUrl(next);
      if (parsed && !parsed.shortUrl) return next; // readable: no need to fetch google.com itself
      current = next;
      continue;
    }
    if (status >= 200 && status < 300) {
      if (current !== url) return current;
      throw fail('LINK_UNREACHABLE');
    }
    throw fail('LINK_UNREACHABLE');
  }
  throw fail('LINK_TOO_MANY_REDIRECTS');
}

/**
 * Resolves pasted text to a place for POST /api/geo/link:
 *   { place: { lat, lng, name, source, precise } }           a point (named by the link, or reverse geocoded)
 *   { query, results: [...] }                                 only a name: a search for it
 *   throws { status, code } when there is nothing to read.
 */
class MapLinkResolver {
  constructor({ geo, fetchImpl = globalThis.fetch, userAgent = 'CoRoute', logger = console, cacheSize = 500, cacheMs = 24 * 3600000 } = {}) {
    this.geo = geo; this.fetch = fetchImpl; this.userAgent = userAgent; this.log = logger;
    this.cache = new Map(); this.cacheSize = cacheSize; this.cacheMs = cacheMs;
  }

  async _expand(url) {
    const hit = this.cache.get(url);
    if (hit && Date.now() - hit.at < this.cacheMs) return hit.value;
    const value = await expandShortLink(url, { fetchImpl: this.fetch, userAgent: typeof this.userAgent === 'function' ? this.userAgent() : this.userAgent });
    this.cache.set(url, { at: Date.now(), value });
    while (this.cache.size > this.cacheSize) this.cache.delete(this.cache.keys().next().value);
    return value;
  }

  async resolve(text, { lat, lng } = {}) {
    const err = (status, code) => Object.assign(new Error(code), { status, code });
    const t = String(text || '').trim();
    if (!t) throw err(400, 'LINK_EMPTY');
    if (t.length > 2000) throw err(400, 'LINK_TOO_LONG');
    let r = parseMapText(t);
    if (!r) throw err(422, 'LINK_UNSUPPORTED');
    let expanded = false;
    if (r.shortUrl) {
      const label = r.name || null;
      let finalUrl;
      try {
        finalUrl = await this._expand(r.shortUrl);
      } catch (e) {
        this.log.warn?.('[geo] short link expansion failed', e.code || 'error');
        if (label) r = { query: label, name: label, source: 'text', precise: true };
        else throw err(e.code === 'LINK_NOT_ALLOWED' ? 422 : 502, e.code || 'LINK_UNREACHABLE');
      }
      if (finalUrl) {
        const p = parseUrl(finalUrl);
        if (!p || p.shortUrl) {
          if (!label) throw err(422, 'LINK_UNSUPPORTED');
          r = { query: label, name: label, source: 'text', precise: true };
        } else {
          r = { ...p, ...(p.name ? {} : label ? { name: label } : {}) };
          expanded = true;
        }
      }
    }
    if (Number.isFinite(r.lat) && Number.isFinite(r.lng)) {
      let name = r.name || null;
      if (!name && this.geo?.reverse) name = await this.geo.reverse(r.lat, r.lng).catch(() => null);
      return { place: { lat: Math.round(r.lat * 1e6) / 1e6, lng: Math.round(r.lng * 1e6) / 1e6, name: name || null, source: r.source, precise: r.precise !== false }, expanded };
    }
    const q = clean(r.query || r.name);
    if (!q) throw err(422, 'LINK_UNSUPPORTED');
    const results = this.geo?.search ? await this.geo.search(q, { lat, lng }) : [];
    return { query: q, results: Array.isArray(results) ? results : [], expanded };
  }
}

module.exports = { parseMapText, parseUrl, parseCoordinates, decodePlusCode, expandShortLink, expandAllowed, MapLinkResolver, EXPAND_HOSTS, SHORT_HOSTS };
