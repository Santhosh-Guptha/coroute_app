'use strict';
/**
 * 3.56 route weather from MET Norway (src/weather_met.js, default WEATHER_PROVIDER): the request
 * their terms ask for (identifying User-Agent, <= 4 decimals, HTTPS path), parsing of a
 * Locationforecast 2.0 `complete` answer (fixture), caching until Expires and for at least
 * 30 minutes per grid cell, If-Modified-Since revalidation, the minute budget and the credit line.
 */
process.env.NODE_ENV = 'test';
process.env.WEATHER_URL = 'http://met.test';
delete process.env.WEATHER_PROVIDER;
delete process.env.WEATHER_MET_URL;
process.env.WEATHER_PER_MIN = '6';
process.env.GEO_MIN_INTERVAL_MS = '0';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const M = require('../src/weather_met');
const fixture = require('./fixtures/metno_locationforecast_complete.json');

const calls = [];
let mode = 'ok';
const hourMs = 3600000;
const hour0 = Math.floor(Date.now() / hourMs) * hourMs;
/** The fixture shifted so its first hour is the current hour. */
function shifted() {
  const base = Date.parse(fixture.properties.timeseries[0].time);
  const j = JSON.parse(JSON.stringify(fixture));
  for (const e of j.properties.timeseries) e.time = new Date(hour0 + (Date.parse(e.time) - base)).toISOString().replace('.000Z', 'Z');
  return j;
}
async function fakeFetch(url, opts = {}) {
  calls.push({ url, headers: opts.headers || {} });
  const headers = new Map([['expires', new Date(Date.now() + 2 * hourMs).toUTCString()], ['last-modified', 'Thu, 12 Nov 2026 06:00:00 GMT']]);
  const h = { get: (k) => headers.get(String(k).toLowerCase()) || null };
  if (mode === 'down') return { ok: false, status: 503, headers: h, json: async () => ({}) };
  if (mode === '304' && opts.headers && opts.headers['If-Modified-Since']) return { ok: false, status: 304, headers: h, json: async () => { throw new Error('no body'); } };
  return { ok: true, status: 200, headers: h, json: async () => shifted() };
}

let t, user;
before(async () => { t = await boot({ geoFetch: fakeFetch }); user = await t.register('Met Rider', 'metrider@coroute.test'); });
after(async () => { await t.gw.shutdown(); });
const post = (points, tok = user.token) => t.api('POST', '/geo/weather', { points }, tok);
const at = (h) => Math.floor((hour0 + h * hourMs) / 1000) + 600;

test('provider choice and request shape', () => {
  assert.equal(M.providerOf({}), 'metno', 'MET Norway is the default');
  assert.equal(M.providerOf({ WEATHER_PROVIDER: 'Open-Meteo' }), 'open-meteo');
  assert.equal(M.providerOf({ WEATHER_PROVIDER: 'something' }), 'metno');
  assert.equal(M.baseOf('https://api.open-meteo.com', {}), 'https://api.met.no', 'the old default URL is never used for MET');
  assert.equal(M.baseOf('', {}), 'https://api.met.no');
  assert.equal(M.baseOf('http://met.test/', {}), 'http://met.test');
  assert.equal(M.baseOf('x', { WEATHER_MET_URL: 'https://proxy.example/' }), 'https://proxy.example');
  assert.equal(M.urlOf('https://api.met.no', 17.4123456, 78.4999), 'https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=17.4&lon=78.5');
  assert.match(M.ATTRIBUTION, /based on data from MET Norway/i);
  assert.match(M.ATTRIBUTION, /CC BY 4\.0/);
});

test('symbol codes and the derived hourly chance of rain', () => {
  const map = { clearsky_day: 0, fair_night: 1, partlycloudy_day: 2, cloudy: 3, fog: 45, lightrain: 61, rain: 63, heavyrain: 65,
    lightrainshowers_day: 80, rainshowers_night: 81, heavyrainshowers_day: 82, rainandthunder: 95, lightrainshowersandthunder_day: 95,
    sleet: 66, heavysleet: 67, snow: 73, lightsnow: 71, heavysnowshowers_day: 86 };
  for (const [k, v] of Object.entries(map)) assert.equal(M.wmoOf(k), v, k);
  assert.equal(M.wmoOf(''), null);
  assert.equal(M.wmoOf('somethingnew'), null);
  assert.equal(M.hourProb(0, 1, 90), 45, 'a dry hour never warns on the 6 hour chance alone');
  assert.equal(M.hourProb(0, 1, 20), 20);
  assert.equal(M.hourProb(0, 1, null), 5);
  assert.equal(M.hourProb(0.2, 61, 30), 60, 'forecast rain in the hour warns');
  assert.equal(M.hourProb(1.4, 63, 30), 80);
  assert.equal(M.hourProb(1.4, 63, 95), 95);
  assert.equal(M.hourProb(null, 95, null), 60);
});

test('fixture: hourly slots, 6 hour steps spread, nothing invented', () => {
  const c = M.cellOf(fixture);
  assert.equal(c.hourlyFrom, Date.parse(fixture.properties.timeseries[0].time) / 1000);
  assert.equal(c.probs.length, c.mm.length);
  assert.equal(c.temps[0], 27.4);
  assert.equal(c.codes[0], 2);
  assert.equal(c.mm[0], 0);
  assert.equal(c.probs[0], 12, 'dry hour: the 6 hour chance (12 %)');
  assert.equal(c.codes[2], 61);
  assert.equal(c.mm[2], 0.3);
  assert.equal(c.probs[2], 64, 'wet hour: at least 60, here the 6 hour chance');
  assert.equal(c.codes[3], 95);
  assert.equal(c.probs[3], 80);
  // The 6-hourly entry at +6 h (3 mm in 6 h) fills its six hours.
  assert.equal(c.mm[6], 0.5);
  assert.equal(c.mm[11], 0.5);
  assert.equal(c.codes[8], 63);
  assert.equal(c.probs.length, 12);
  assert.equal(c.probs[4], null, 'an hour MET did not give stays empty');
  assert.equal(M.cellOf({}), null);
  assert.equal(M.cellOf({ properties: { timeseries: [{ time: 'x' }] } }), null);
  assert.equal(M.expiresMs('nonsense'), 0);
  const now = Date.now();
  assert.equal(M.expiresMs(new Date(now + 48 * hourMs).toUTCString(), now), now + 6 * hourMs, 'capped');
});

test('gateway: one call per cell with the identifying User-Agent; cached; credit line', async () => {
  const pts = [{ lat: 17.41, lng: 78.48, at: at(0) }, { lat: 17.44, lng: 78.52, at: at(2) }, { lat: 17.63, lng: 78.72, at: at(3) }];
  const r = await post(pts);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(calls.length, 2, 'two grid cells, two calls');
  assert.equal(calls[0].url, 'http://met.test/weatherapi/locationforecast/2.0/complete?lat=17.4&lon=78.5');
  const ua = calls[0].headers['User-Agent'];
  assert.match(ua, /^CoRoute\/\d/, 'identifies the application');
  assert.match(ua, /https?:\/\//, 'with a site to contact');
  assert.ok(!/okhttp|Dalvik|Java|node|undici/i.test(ua), 'not a generic client string');
  for (const c of calls) assert.ok(!/\d\.\d{5,}/.test(c.url), 'at most 4 decimals');
  assert.equal(r.json.source, 'MET Norway');
  assert.match(r.json.attribution, /MET Norway/);
  assert.equal(r.json.points[0].precipProb, 12);
  assert.equal(r.json.points[0].tempC, 27.4);
  assert.equal(r.json.points[1].code, 61);
  assert.equal(r.json.points[1].precipMm, 0.3);
  assert.equal(r.json.points[2].code, 95);
  // Same cells again: served from the cache.
  const other = await t.register('Met Two', 'mettwo@coroute.test');
  const r2 = await post([{ lat: 17.39, lng: 78.47, at: at(2) }], other.token);
  assert.equal(r2.status, 200);
  assert.equal(calls.length, 2, 'no repeat within the cache time');
  assert.equal(r2.json.points[0].code, 61);
  // An hour MET did not publish is "no answer", not "dry".
  const r3 = await post([{ lat: 17.39, lng: 78.47, at: at(4) }], other.token);
  assert.equal(r3.json.points[0], null);
});

test('never before Expires; then If-Modified-Since, and a 304 keeps the stored forecast', async () => {
  const geo = t.gw.geo;
  const k = 'wxm:17.4,78.5';
  const mem = geo.weatherCache.get(k);
  assert.ok(mem && mem.value.exp > Date.now() + hourMs, 'Expires was stored');
  assert.equal(mem.value.lm, 'Thu, 12 Nov 2026 06:00:00 GMT');
  // 31 minutes old but Expires is in the future: still no call.
  mem.at = Date.now() - 31 * 60000;
  const before = calls.length;
  await post([{ lat: 17.41, lng: 78.48, at: at(0) }]);
  assert.equal(calls.length, before, 'not repeated before Expires');
  // Past both: revalidated.
  mem.at = Date.now() - 3 * hourMs; mem.value = { ...mem.value, exp: Date.now() - 1000 };
  await t.repo?.geoCachePut?.(k, mem.value);
  geo.repo.geoCacheGet = async () => null;
  mode = '304';
  const r = await post([{ lat: 17.41, lng: 78.48, at: at(2) }]);
  assert.equal(calls.length, before + 1);
  assert.equal(calls[calls.length - 1].headers['If-Modified-Since'], 'Thu, 12 Nov 2026 06:00:00 GMT');
  assert.equal(r.json.points[0].code, 61, 'the stored forecast is kept on 304');
  assert.ok(geo.weatherCache.get(k).value.exp > Date.now(), 'with the new Expires');
  mode = 'ok';
});

test('minute budget counts every upstream call; failure answers null and is retried later', async () => {
  const geo = t.gw.geo;
  geo.weatherTimes = [];
  const u = await t.register('Met Three', 'metthree@coroute.test');
  const before = calls.length;
  // 5 new cells: all fetched (budget 6). Next request with 2 new cells: only 1 fits.
  const five = [1, 2, 3, 4, 5].map((i) => ({ lat: 20 + i * 0.3, lng: 80.05, at: at(0) }));
  const a = await post(five, u.token);
  assert.equal(calls.length - before, 5);
  assert.ok(a.json.points.every(Boolean));
  const b = await post([{ lat: 25.05, lng: 81.05, at: at(0) }, { lat: 26.05, lng: 81.05, at: at(0) }], u.token);
  assert.equal(calls.length - before, 6, 'the budget of 6 calls a minute holds');
  assert.ok(b.json.points[0]);
  assert.equal(b.json.points[1], null);
  geo.weatherTimes = [];
  mode = 'down';
  const c = await post([{ lat: 27.05, lng: 81.05, at: at(0) }], u.token);
  assert.equal(c.status, 200);
  assert.equal(c.json.points[0], null);
  mode = 'ok';
  geo.weatherTimes = [];
  const d = await post([{ lat: 27.05, lng: 81.05, at: at(0) }], u.token);
  assert.ok(d.json.points[0], 'tried again after the failure');
});
