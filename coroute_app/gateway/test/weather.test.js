'use strict';
/**
 * 3.16 weather proxy (Open-Meteo through the gateway): one upstream call for up to 5 points, a 0.1 degree
 * grid cache shared by everyone for 30 minutes, the global and per-user budgets, validation, and no
 * coordinates in the logs.
 */
process.env.NODE_ENV = 'test';
process.env.WEATHER_URL = 'http://wx.test';
process.env.WEATHER_PER_MIN = '2';
process.env.GEO_MIN_INTERVAL_MS = '0';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');

const logged = [];
const logger = { info: (...a) => logged.push(a.join(' ')), warn: (...a) => logged.push(a.join(' ')), error: (...a) => logged.push(a.join(' ')) };

const calls = [];
let failNext = false;
/** Fake Open-Meteo: 72 hourly rows per location from today 00:00 UTC; rain (70 %) for latitude >= 17.6; temperature = 20 + hour of day. */
async function fakeFetch(url) {
  calls.push(url);
  if (failNext) { failNext = false; return { ok: false, status: 503, json: async () => ({}) }; }
  const u = new URL(url);
  const lats = u.searchParams.get('latitude').split(',').map(Number);
  const day0 = Math.floor(Date.now() / 86400000) * 86400;
  const body = lats.map((lat) => {
    const time = [], prob = [], mm = [], code = [], temp = [];
    for (let h = 0; h < 72; h++) {
      time.push(new Date((day0 + h * 3600) * 1000).toISOString().slice(0, 16));
      const rain = lat >= 17.6;
      prob.push(rain ? 70 : 10); mm.push(rain ? 1.2 : 0); code.push(rain ? 61 : 1); temp.push(20 + (h % 24));
    }
    return { latitude: lat, hourly: { time, precipitation_probability: prob, precipitation: mm, weather_code: code, temperature_2m: temp } };
  });
  return { ok: true, status: 200, json: async () => (body.length === 1 ? body[0] : body) };
}

let t, user;
before(async () => {
  t = await boot({ geoFetch: fakeFetch, logger });
  user = await t.register('Weather Rider', 'weather@coroute.test');
});
after(async () => { await t.gw.shutdown(); });

const nowS = () => Math.floor(Date.now() / 1000);
const post = (points, tok = user.token) => t.api('POST', '/geo/weather', { points }, tok);

test('5 points: one upstream call, grid rounding dedupes, per-point hour, cached within 30 minutes', async () => {
  const day0 = Math.floor(Date.now() / 86400000) * 86400;
  const h0 = Math.floor((nowS() - day0) / 3600); // the current hour slot
  // Three distinct 0.1 degree cells among five points; the ETA of each point picks its hour.
  const at = (h) => day0 + h * 3600 + 600;
  const pts = [
    { lat: 17.41, lng: 78.48, at: at(h0) }, { lat: 17.44, lng: 78.52, at: at(h0 + 1) }, // same cell (17.4, 78.5)
    { lat: 17.52, lng: 78.61, at: at(h0 + 1) }, // cell (17.5, 78.6), dry
    { lat: 17.63, lng: 78.72, at: at(h0 + 2) }, { lat: 17.64, lng: 78.73, at: at(h0 + 3) }, // cell (17.6, 78.7), rain
  ];
  const before = calls.length;
  const r = await post(pts);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(calls.length - before, 1, 'one upstream call for all five points');
  const url = calls[calls.length - 1];
  assert.ok(url.startsWith('http://wx.test/v1/forecast?'));
  assert.equal(new URL(url).searchParams.get('latitude'), '17.4,17.5,17.6', 'rounded, deduped cells');
  assert.equal(new URL(url).searchParams.get('longitude'), '78.5,78.6,78.7');
  assert.match(r.headers.get('cache-control'), /private/);
  assert.equal(r.json.source, 'Open-Meteo');
  assert.match(r.json.attribution, /Open-Meteo/);
  assert.equal(r.json.points.length, 5);
  assert.equal(r.json.points[0].precipProb, 10);
  assert.equal(r.json.points[2].precipProb, 10);
  assert.equal(r.json.points[3].precipProb, 70);
  assert.equal(r.json.points[3].code, 61);
  assert.equal(r.json.points[3].precipMm, 1.2);
  assert.equal(r.json.points[3].at, at(h0 + 2));
  assert.equal(r.json.points[4].precipProb, 70);
  assert.equal(r.json.points[1].lat, 17.44);
  // Each point reads the hour its ETA falls in.
  assert.equal(r.json.points[0].tempC, 20 + (h0 % 24));
  assert.equal(r.json.points[1].tempC, 20 + ((h0 + 1) % 24));
  assert.equal(r.json.points[4].tempC, 20 + ((h0 + 3) % 24));
  // Same cells again (another rider, another point in the cell): no upstream call.
  const other = await t.register('Weather Two', 'weather2@coroute.test');
  const r2 = await post([{ lat: 17.43, lng: 78.46, at: at(h0 + 1) }, { lat: 17.61, lng: 78.74, at: at(h0 + 4) }], other.token);
  assert.equal(r2.status, 200);
  assert.equal(calls.length - before, 1, 'cache hit within 30 minutes');
  assert.equal(r2.json.points[1].precipProb, 70);
  // The 48 hour limit: a point far in the future is clamped, a point beyond the forecast is null.
  const beforeClamp = nowS();
  const r3 = await post([{ lat: 17.41, lng: 78.48, at: nowS() + 3600 }, { lat: 17.41, lng: 78.48, at: nowS() + 10 * 86400 }]);
  assert.equal(r3.status, 200);
  assert.ok(r3.json.points[0] && Number.isFinite(r3.json.points[0].precipProb));
  const afterClamp = nowS();
  assert.ok(r3.json.points[1].at >= beforeClamp + 48 * 3600 &&
    r3.json.points[1].at <= afterClamp + 48 * 3600, 'clamped to 48 h at request processing time');
});

test('global budget exhausted: cached cells answered, new cells null; upstream failure answers nulls', async () => {
  const day0 = nowS();
  // WEATHER_PER_MIN is 2: the first test used one; this is the second.
  const a = await post([{ lat: 18.01, lng: 79.01, at: day0 + 3600 }]);
  assert.equal(a.status, 200);
  assert.ok(a.json.points[0]);
  const before = calls.length;
  const b = await post([{ lat: 18.01, lng: 79.01, at: day0 + 3600 }, { lat: 18.51, lng: 79.51, at: day0 + 3600 }]);
  assert.equal(b.status, 200);
  assert.equal(calls.length, before, 'over budget: no upstream call');
  assert.ok(b.json.points[0], 'the cached cell is answered');
  assert.equal(b.json.points[1], null, 'the new cell is null');
  // Budget reset, upstream down: nulls, no error, nothing cached.
  t.gw.geo.weatherTimes = [];
  failNext = true;
  const c = await post([{ lat: 18.91, lng: 79.91, at: day0 + 3600 }]);
  assert.equal(c.status, 200);
  assert.equal(c.json.points[0], null);
  t.gw.geo.weatherTimes = [];
  const d = await post([{ lat: 18.91, lng: 79.91, at: day0 + 3600 }]);
  assert.ok(d.json.points[0], 'tried again after the failure');
});

test('per-user limiter: the 7th call in a minute is 429; bad points 422; coordinates never reach the logs', async () => {
  const u = await t.register('Weather Limit', 'weatherlimit@coroute.test');
  t.gw.geo.weatherTimes = [];
  let last;
  for (let i = 0; i < 7; i++) last = await post([{ lat: 17.41, lng: 78.48 }], u.token);
  assert.equal(last.status, 429);
  assert.equal(last.json.code, 'RATE_LIMITED');
  const bads = [[], 'x', [{ lat: 'a', lng: 1 }], [{ lat: 0, lng: 0 }], [{ lat: 95, lng: 1 }], [{ lat: 17, lng: 78, at: 'soon' }], Array(6).fill({ lat: 17, lng: 78 }), [null], undefined];
  let v = await t.register('Weather Bad A', 'weatherbada@coroute.test');
  for (let i = 0; i < bads.length; i++) {
    if (i === 5) v = await t.register('Weather Bad B', 'weatherbadb@coroute.test'); // 6 per minute per rider
    const r = await t.api('POST', '/geo/weather', bads[i] === undefined ? {} : { points: bads[i] }, v.token);
    assert.equal(r.status, 422, JSON.stringify(bads[i]));
  }
  assert.equal((await t.api('POST', '/geo/weather', { points: [{ lat: 17, lng: 78 }] })).status, 401, 'auth required');
  // The fake fetch failed once above and the limiter answered: the logs name neither cell nor point.
  for (const line of logged) {
    assert.ok(!/17\.4|78\.4|18\.9|79\.9|latitude/.test(line), `coordinates in the log: ${line}`);
  }
});

test('disabled (empty WEATHER_URL): 503 WEATHER_OFF', async () => {
  const config = require('../src/config');
  const saved = config.weatherUrl;
  config.weatherUrl = '';
  try {
    const u = await t.register('Weather Off', 'weatheroff@coroute.test');
    const r = await post([{ lat: 17.41, lng: 78.48 }], u.token);
    assert.equal(r.status, 503);
    assert.equal(r.json.code, 'WEATHER_OFF');
    assert.equal(await t.gw.geo.weather([{ lat: 17.41, lng: 78.48, at: nowS() }]), null);
  } finally { config.weatherUrl = saved; }
});
