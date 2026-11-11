'use strict';
// 3.56 map search: pasted map links, coordinates and plus codes (geo_links.js), short-link
// expansion through a fake HTTP layer (no real network), the search fallbacks and budgets.
process.env.NODE_ENV = 'test';
process.env.GEO_PHOTON_URL = 'http://photon.test';
process.env.GEO_SEARCH_URL = 'http://nominatim.test';
process.env.GEO_PHOTON_MIN_INTERVAL_MS = '0';
process.env.GEO_MIN_INTERVAL_MS = '0';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseMapText, parseUrl, decodePlusCode, expandShortLink, expandAllowed, MapLinkResolver } = require('../src/geo_links');
const { GeoProxy } = require('../src/geo');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { boot } = require('./_helpers');

const near = (a, b, eps = 1e-4) => Math.abs(a - b) <= eps;
function pt(r, lat, lng, extra = {}) {
  assert.ok(r, 'parsed');
  assert.ok(near(r.lat, lat) && near(r.lng, lng), `expected ${lat},${lng} got ${r.lat},${r.lng}`);
  for (const [k, v] of Object.entries(extra)) assert.equal(r[k], v, k);
}
function q(r, query) {
  assert.ok(r, 'parsed');
  assert.equal(r.lat, undefined);
  assert.equal(r.query, query);
}

// ------------------------------------------------------------------ parser (mirrors the Dart tests)

test('Google place links: the data pin wins over the view centre, name from the path', () => {
  pt(parseMapText('https://www.google.com/maps/place/Charminar/@17.3615636,78.4720803,17z/data=!3m1!4b1!4m6!3m5!1s0x3bcb978ad7b6f6bd:0x3d5e5b3a1cf2a9b0!8m2!3d17.3615636!4d78.4746552!16zL20vMDJ6bTc?entry=ttu'),
    17.3615636, 78.4746552, { name: 'Charminar', source: 'google', precise: true });
  pt(parseMapText('https://www.google.co.in/maps/place/Nandi+Hills,+Karnataka+562103/@13.3702,77.6835,14z/data=!4m6!3m5!1s0x0:0x0!8m2!3d13.3702!4d77.6835'), 13.3702, 77.6835, { name: 'Nandi Hills, Karnataka 562103' });
  pt(parseMapText('https://www.google.com/maps/place/Lalbagh+Botanical+Garden/@12.9507,77.5848,16z'), 12.9507, 77.5848, { name: 'Lalbagh Botanical Garden' });
  pt(parseMapText("https://www.google.com/maps/place/12%C2%B058'16.0%22N+77%C2%B035'38.0%22E/@12.9711,77.5917,17z/data=!3m1!4b1!4m4!3m3!8m2!3d12.9711111!4d77.5938889"), 12.97111, 77.59389);
  pt(parseMapText('https://www.google.com/maps/place/17.385044,78.486671/@17.385044,78.486671,17z'), 17.385044, 78.486671);
});

test('Google view, ?q=, ?ll=, /search/, /dir/', () => {
  pt(parseMapText('https://www.google.com/maps/@12.9715987,77.5945627,15z?entry=ttu'), 12.9715987, 77.5945627, { precise: false });
  pt(parseMapText('https://maps.google.com/?q=12.9716,77.5946'), 12.9716, 77.5946, { precise: true });
  pt(parseMapText('https://maps.google.com/maps?q=-33.8688,151.2093&z=15'), -33.8688, 151.2093);
  q(parseMapText('https://maps.google.com/?q=Gateway+of+India,+Mumbai'), 'Gateway of India, Mumbai');
  pt(parseMapText('https://www.google.com/maps?q=Golconda+Fort&ftid=0x3bcb9:0x2b&data=!3d17.3833!4d78.4011'), 17.3833, 78.4011, { name: 'Golconda Fort' });
  pt(parseMapText('https://maps.google.com/maps?ll=15.3350,76.4600&z=13&t=m'), 15.335, 76.46);
  q(parseMapText('https://www.google.com/maps/search/petrol+pump+near+Kurnool/@15.82,78.03,13z'), 'petrol pump near Kurnool');
  pt(parseMapText('https://www.google.com/maps/search/12.9716,+77.5946?entry=tts'), 12.9716, 77.5946);
  pt(parseMapText('https://www.google.com/maps/search/?api=1&query=28.6129,77.2295'), 28.6129, 77.2295);
  pt(parseMapText('https://www.google.com/maps/dir/Bengaluru,+Karnataka/Mysore+Palace,+Mysuru/@12.6,76.9,9z/data=!3m1!4b1!4m14!4m13!1m5!1m1!1s0x0:0x0!2m2!1d77.5946!2d12.9716!1m5!1m1!1s0x0:0x0!2m2!1d76.6552!2d12.3052!3e0'),
    12.3052, 76.6552, { name: 'Mysore Palace, Mysuru' });
  pt(parseMapText('https://www.google.com/maps/dir/12.97,77.59/13.3702,77.6835/'), 13.3702, 77.6835);
  pt(parseMapText('https://www.google.com/maps/dir/?api=1&destination=13.0827,80.2707&travelmode=driving'), 13.0827, 80.2707);
  q(parseMapText('https://www.google.com/maps/dir/My+Location/Coorg/'), 'Coorg');
  assert.equal(parseMapText('https://maps.google.com/?q=95.1,77.5'), null);
});

test('short links and shared text', () => {
  assert.deepEqual(parseMapText('https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A'), { shortUrl: 'https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A', source: 'google' });
  assert.equal(parseMapText('https://goo.gl/maps/AbCdEf12345').shortUrl, 'https://goo.gl/maps/AbCdEf12345');
  assert.equal(parseMapText('https://goo.gl/AbCdEf'), null);
  const shared = parseMapText('Charminar\nCharminar Rd, Char Kaman, Ghansi Bazaar, Hyderabad, Telangana 500002\nhttps://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A');
  assert.equal(shared.shortUrl, 'https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A');
  assert.equal(shared.name, 'Charminar');
  assert.equal(shared.query, 'Charminar');
  pt(parseMapText('Meeting point - https://maps.google.com/?q=17.2403,78.4294'), 17.2403, 78.4294, { name: 'Meeting point' });
  pt(parseMapText('Check out this place https://www.google.com/maps/place/Cubbon+Park/@12.9763,77.5929,16z/data=!3d12.9763!4d77.5929.'), 12.9763, 77.5929, { name: 'Cubbon Park' });
});

test('geo:, Apple, OSM, Waze', () => {
  pt(parseMapText('geo:12.9716,77.5946'), 12.9716, 77.5946, { source: 'geo' });
  pt(parseMapText('geo:12.9716,77.5946;u=35?q=Vidhana+Soudha'), 12.9716, 77.5946, { name: 'Vidhana Soudha' });
  pt(parseMapText('geo:0,0?q=17.3616,78.4747(Charminar)'), 17.3616, 78.4747, { name: 'Charminar' });
  q(parseMapText('geo:0,0?q=Hussain+Sagar'), 'Hussain Sagar');
  pt(parseMapText('https://maps.apple.com/?ll=12.9763,77.5929&q=Cubbon%20Park&t=m'), 12.9763, 77.5929, { source: 'apple', name: 'Cubbon Park' });
  pt(parseMapText('https://maps.apple.com/place?coordinate=19.0760,72.8777&name=Mumbai'), 19.076, 72.8777, { name: 'Mumbai' });
  q(parseMapText('https://maps.apple.com/?address=MG%20Road,%20Bengaluru'), 'MG Road, Bengaluru');
  q(parseMapText('https://maps.apple.com/?q=Coffee&sll=12.97,77.59'), 'Coffee');
  pt(parseMapText('https://www.openstreetmap.org/?mlat=12.97160&mlon=77.59460#map=17/12.97160/77.59460'), 12.9716, 77.5946, { source: 'osm', precise: true });
  pt(parseMapText('https://www.openstreetmap.org/#map=15/17.3850/78.4867'), 17.385, 78.4867, { precise: false });
  pt(parseMapText('https://waze.com/ul?ll=12.9716,77.5946&navigate=yes'), 12.9716, 77.5946, { source: 'waze' });
  pt(parseMapText('https://www.waze.com/ul?ll=12.9716%2C77.5946&navigate=yes&zoom=17'), 12.9716, 77.5946);
  pt(parseMapText('https://www.waze.com/live-map/directions?to=ll.13.0827%2C80.2707'), 13.0827, 80.2707);
  q(parseMapText('https://waze.com/ul?q=Ooty%20Lake'), 'Ooty Lake');
});

test('plain coordinates, DMS, plus codes; junk is rejected', () => {
  pt(parseMapText('12.97, 77.59'), 12.97, 77.59, { source: 'coords' });
  pt(parseMapText('12.97 77.59'), 12.97, 77.59);
  pt(parseMapText('(12.9716; 77.5946)'), 12.9716, 77.5946);
  pt(parseMapText('12.9716N, 77.5946E'), 12.9716, 77.5946);
  pt(parseMapText('33.8688 S, 151.2093 E'), -33.8688, 151.2093);
  pt(parseMapText('77.5946E, 12.9716N'), 12.9716, 77.5946);
  pt(parseMapText('lat: 12.9716 lng: 77.5946'), 12.9716, 77.5946);
  pt(parseMapText('12°58\'16"N 77°35\'38"E'), 12.97111, 77.59389, { source: 'dms' });
  pt(parseMapText('7J4VXHFR+2C Bengaluru, Karnataka'), 12.9725625, 77.5910625, { source: 'pluscode', name: 'Bengaluru, Karnataka' });
  assert.deepEqual(decodePlusCode('849VCWC8+R9').map((v) => Math.round(v * 1e7) / 1e7), [37.4220625, -122.0840625]);
  for (const bad of ['95.0, 77.59', '12.97, 190.5', '0.0, 0.0', 'Sector 21 22', 'NH 44 Kurnool', 'Charminar', '', 'https://example.com/?q=12.97,77.59']) {
    assert.equal(parseMapText(bad), null, bad);
  }
  assert.equal(decodePlusCode('7J4V+2C'), null);
});

// ------------------------------------------------------------------ short-link expansion (fake HTTP)

/** Fake fetch: a map of URL -> { status, location }; records every call and its options. */
function fakeHttp(routes, calls = []) {
  const impl = async (url, opts) => {
    calls.push({ url, opts });
    const r = typeof routes === 'function' ? await routes(url, opts) : routes[url];
    if (!r) return { status: 404, headers: new Map(), body: null };
    if (r.throw) throw r.throw;
    const headers = new Map(Object.entries(r.location ? { location: r.location } : {}));
    return { status: r.status, headers: { get: (k) => headers.get(k.toLowerCase()) ?? null }, body: { cancel() { r.cancelled = true; } } };
  };
  impl.calls = calls;
  return impl;
}

const PLACE = 'https://www.google.com/maps/place/Charminar/@17.3615636,78.4720803,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d17.3615636!4d78.4746552?entry=tts';

test('expansion: one redirect to a readable Google URL; manual redirects, no cookies, body never read', async () => {
  const routes = { 'https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A': { status: 302, location: PLACE } };
  const http = fakeHttp(routes);
  const out = await expandShortLink('https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A', { fetchImpl: http, userAgent: 'CoRoute/test' });
  assert.equal(out, PLACE);
  assert.equal(http.calls.length, 1, 'the google.com page itself is never fetched');
  const o = http.calls[0].opts;
  assert.equal(o.redirect, 'manual');
  assert.equal(o.credentials, 'omit');
  assert.equal(o.headers['User-Agent'], 'CoRoute/test');
  assert.equal(o.headers.Cookie, undefined);
  assert.ok(routes['https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A'].cancelled, 'body dropped');
});

test('expansion: goo.gl/maps -> maps.app.goo.gl -> relative and consent hops', async () => {
  const http = fakeHttp({
    'https://goo.gl/maps/AbCdEf12345': { status: 301, location: 'https://maps.app.goo.gl/Zz9' },
    'https://maps.app.goo.gl/Zz9': { status: 302, location: `https://consent.google.com/ml?continue=${encodeURIComponent('https://maps.google.com/?q=12.9716,77.5946')}&gl=IN` },
  });
  assert.equal(await expandShortLink('https://goo.gl/maps/AbCdEf12345', { fetchImpl: http }), 'https://maps.google.com/?q=12.9716,77.5946');
  assert.equal(http.calls.length, 2);
});

test('expansion: refuses other hosts, too many hops, timeouts, non-short starts', async () => {
  await assert.rejects(expandShortLink('https://maps.app.goo.gl/evil', { fetchImpl: fakeHttp({ 'https://maps.app.goo.gl/evil': { status: 302, location: 'https://evil.example/maps?q=1,2' } }) }), { code: 'LINK_NOT_ALLOWED' });
  await assert.rejects(expandShortLink('https://maps.app.goo.gl/x', { fetchImpl: fakeHttp({ 'https://maps.app.goo.gl/x': { status: 302, location: 'http://www.google.com/maps/@1,2,3z' } }) }), { code: 'LINK_NOT_ALLOWED' }, 'plain http refused');
  await assert.rejects(expandShortLink('https://www.google.com/maps/@12,77,3z', { fetchImpl: fakeHttp({}) }), { code: 'LINK_NOT_ALLOWED' }, 'only short links are expanded');
  await assert.rejects(expandShortLink('https://evil.example/x', { fetchImpl: fakeHttp({}) }), { code: 'LINK_NOT_ALLOWED' });
  // A loop between short links: stops after 5 redirects (6 requests).
  const loop = fakeHttp((url) => ({ status: 302, location: url.endsWith('/a') ? 'https://maps.app.goo.gl/b' : 'https://maps.app.goo.gl/a' }));
  await assert.rejects(expandShortLink('https://maps.app.goo.gl/a', { fetchImpl: loop }), { code: 'LINK_TOO_MANY_REDIRECTS' });
  assert.equal(loop.calls.length, 6);
  // (The keep-alive timer stands in for the server's open sockets: AbortSignal.timeout is unref'd.)
  const slow = async (url, opts) => new Promise((_, rej) => {
    const keep = setTimeout(() => {}, 2000);
    opts.signal.addEventListener('abort', () => { clearTimeout(keep); rej(Object.assign(new Error('t'), { name: 'TimeoutError' })); });
  });
  await assert.rejects(expandShortLink('https://maps.app.goo.gl/s', { fetchImpl: slow, timeoutMs: 50 }), { code: 'LINK_TIMEOUT' });
  await assert.rejects(expandShortLink('https://maps.app.goo.gl/n', { fetchImpl: fakeHttp({ 'https://maps.app.goo.gl/n': { status: 404 } }) }), { code: 'LINK_UNREACHABLE' });
  await assert.rejects(expandShortLink('https://maps.app.goo.gl/d', { fetchImpl: fakeHttp({ 'https://maps.app.goo.gl/d': { throw: new Error('ECONNRESET') } }) }), { code: 'LINK_UNREACHABLE' });
  assert.equal(expandAllowed('https://user:pw@www.google.com/maps'), false);
  assert.equal(expandAllowed('https://www.google.com:8443/maps'), false);
  assert.equal(expandAllowed('https://www.google.co.in/maps/place/x'), true);
});

// ------------------------------------------------------------------ resolver

function fakeGeo() {
  const calls = { reverse: 0, search: [] };
  return {
    calls,
    reverse: async () => { calls.reverse++; return 'Char Kaman, Hyderabad'; },
    search: async (query, opts) => { calls.search.push({ query, opts }); return [{ name: query, displayName: 'Hyderabad, Telangana', lat: 17.36, lng: 78.47 }]; },
  };
}

test('resolver: short link -> named place, cached; unnamed points are reverse geocoded; names are searched', async () => {
  const geo = fakeGeo();
  const http = fakeHttp({ 'https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A': { status: 302, location: PLACE } });
  const res = new MapLinkResolver({ geo, fetchImpl: http, logger: { warn() {} } });
  const a = await res.resolve('https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A');
  assert.equal(a.place.name, 'Charminar');
  assert.ok(near(a.place.lat, 17.3615636) && near(a.place.lng, 78.4746552));
  assert.equal(a.expanded, true);
  await res.resolve('Look: https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A');
  assert.equal(http.calls.length, 1, 'expansion cached');
  assert.equal(geo.calls.reverse, 0);

  const b = await res.resolve('12.9716, 77.5946');
  assert.equal(b.place.name, 'Char Kaman, Hyderabad');
  assert.equal(geo.calls.reverse, 1);

  const c = await res.resolve('https://maps.google.com/?q=Golconda+Fort', { lat: 17.4, lng: 78.4 });
  assert.equal(c.query, 'Golconda Fort');
  assert.equal(c.results.length, 1);
  assert.deepEqual(geo.calls.search[0].opts, { lat: 17.4, lng: 78.4 });
});

test('resolver: an unreachable short link with a shared name falls back to a search; without one it fails clearly', async () => {
  const geo = fakeGeo();
  const res = new MapLinkResolver({ geo, fetchImpl: fakeHttp({}), logger: { warn() {} } });
  const a = await res.resolve('Charminar\nhttps://maps.app.goo.gl/dead');
  assert.equal(a.query, 'Charminar');
  await assert.rejects(res.resolve('https://maps.app.goo.gl/dead2'), { status: 502, code: 'LINK_UNREACHABLE' });
  await assert.rejects(res.resolve('hello there'), { status: 422, code: 'LINK_UNSUPPORTED' });
  await assert.rejects(res.resolve('   '), { status: 400, code: 'LINK_EMPTY' });
});

test('resolver logs no link text', async () => {
  const lines = [];
  const logger = { warn: (...a) => lines.push(a.join(' ')) };
  const res = new MapLinkResolver({ geo: fakeGeo(), fetchImpl: fakeHttp({}), logger });
  await res.resolve('My home\nhttps://maps.app.goo.gl/secretCode123').catch(() => {});
  assert.ok(lines.length >= 1);
  assert.ok(lines.every((l) => !l.includes('secretCode123') && !l.includes('My home')));
});

// ------------------------------------------------------------------ search fallbacks

async function proxy(fetchImpl) {
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  return new GeoProxy({ repo, fetchImpl, logger: { warn() {} } });
}

test('search: Nominatim is asked when Photon finds nothing; "nothing" is not cached for a month', async () => {
  const calls = [];
  let nominatimRows = [];
  const geo = await proxy(async (url) => {
    calls.push(url);
    if (url.startsWith('http://photon.test')) return { ok: true, json: async () => ({ features: [] }) };
    return { ok: true, json: async () => nominatimRows };
  });
  const a = await geo.searchResult('Kothur village', { lat: 17.2, lng: 78.4 });
  assert.deepEqual(a, { results: [] });
  assert.ok(calls.some((u) => u.startsWith('http://nominatim.test/search')), 'fallback asked');
  // An hour later the place exists: the empty answer has expired.
  const realNow = Date.now;
  try {
    Date.now = () => realNow() + 2 * 3600000;
    nominatimRows = [{ lat: '17.03', lon: '78.28', name: 'Kothur', address: { village: 'Kothur', state: 'Telangana', country_code: 'in' } }];
    const b = await geo.searchResult('Kothur village', { lat: 17.2, lng: 78.4 });
    assert.equal(b.results.length, 1);
    assert.equal(b.results[0].outside, false);
  } finally { Date.now = realNow; }
});

test('search: every provider down -> SEARCH_UNAVAILABLE (not cached, not "no results")', async () => {
  let down = true;
  const geo = await proxy(async (url) => {
    if (down) return { ok: false, status: 503, json: async () => ({}) };
    if (url.startsWith('http://photon.test')) return { ok: true, json: async () => ({ features: [{ geometry: { coordinates: [78.47, 17.36] }, properties: { name: 'Charminar', countrycode: 'IN', city: 'Hyderabad', state: 'Telangana' } }] }) };
    return { ok: true, json: async () => [] };
  });
  assert.deepEqual(await geo.searchResult('Charminar'), { results: [], error: 'SEARCH_UNAVAILABLE' });
  down = false;
  const r = await geo.searchResult('Charminar');
  assert.equal(r.results[0].name, 'Charminar');
});

test('search: everywhere skips the India pass', async () => {
  const calls = [];
  const geo = await proxy(async (url) => {
    calls.push(url);
    return { ok: true, json: async () => ({ features: [{ geometry: { coordinates: [2.294, 48.858] }, properties: { name: 'Eiffel Tower', countrycode: 'FR', country: 'France' } }] }) };
  });
  const r = await geo.searchResult('Eiffel Tower', { everywhere: true });
  assert.equal(calls.length, 1);
  assert.ok(!new URL(calls[0]).searchParams.has('bbox'));
  assert.equal(r.results[0].outside, true, 'still marked as abroad');
});

// ------------------------------------------------------------------ HTTP endpoints

test('POST /api/geo/link and GET /api/geo/search through the gateway (fake upstreams)', async () => {
  const upstream = [];
  const geoFetch = async (url, opts = {}) => {
    upstream.push(url);
    if (url === 'https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A') {
      return { status: 302, headers: { get: (k) => (k.toLowerCase() === 'location' ? PLACE : null) }, body: null };
    }
    if (url.startsWith('http://photon.test')) {
      return { ok: true, status: 200, json: async () => ({ features: [{ geometry: { coordinates: [78.4746552, 17.3615636] }, properties: { name: 'Charminar', countrycode: 'IN', city: 'Hyderabad', state: 'Telangana' } }] }) };
    }
    if (url.startsWith('http://nominatim.test/reverse')) return { ok: true, status: 200, json: async () => ({ name: 'Vidhana Soudha', address: { city: 'Bengaluru' } }) };
    return { ok: false, status: 404, json: async () => ({}) };
  };
  const { gw, api, register } = await boot({ geoFetch });
  try {
    const u = await register('Mapper', 'mapper356@example.com');
    const t = u.token;
    const a = await api('POST', '/geo/link', { text: 'Charminar\nhttps://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A' }, t);
    assert.equal(a.status, 200, JSON.stringify(a.json));
    assert.equal(a.json.place.name, 'Charminar');
    const b = await api('POST', '/geo/link', { text: '12.9791, 77.5913' }, t);
    assert.equal(b.json.place.name, 'Vidhana Soudha, Bengaluru');
    const c = await api('POST', '/geo/link', { text: 'https://maps.app.goo.gl/xH7rQ9pVbN2kLmT8A' }, t);
    assert.equal(c.status, 200);
    const d = await api('POST', '/geo/link', { text: 'just words' }, t);
    assert.equal(d.status, 422);
    assert.equal(d.json.code, 'LINK_UNSUPPORTED');
    const e = await api('POST', '/geo/link', {}, t);
    assert.equal(e.status, 400);
    const s = await api('GET', `/geo/search?q=${encodeURIComponent('Charminar')}&lat=17.4&lng=78.5`, null, t);
    assert.equal(s.status, 200);
    assert.equal(s.json.results[0].name, 'Charminar');
    assert.ok(s.json.results[0].distanceM > 0);
    // Search has its own budget: 40 searches in a minute are fine even after 30 reverse lookups.
    for (let i = 0; i < 30; i++) await api('GET', `/geo/reverse?lat=12.97&lng=77.${5900 + i}`, null, t);
    let last = null;
    for (let i = 0; i < 40; i++) last = await api('GET', `/geo/search?q=Charminar${i % 3 ? '' : ' Hyderabad'}`, null, t);
    assert.equal(last.status, 200);
    assert.equal(upstream.filter((x) => x.startsWith('https://maps.app.goo.gl')).length, 1, 'short link expanded once');
  } finally {
    await gw.shutdown?.();
    gw.server.close();
  }
});
