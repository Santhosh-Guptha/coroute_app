'use strict';
/**
 * 3.56 route weather from MET Norway (api.met.no Locationforecast 2.0), the default WEATHER_PROVIDER.
 *
 * Why: Open-Meteo's free API is for non-commercial use only (open-meteo.com/en/terms: "You may only
 * use the free API services for non-commercial purposes"; apps with subscriptions count as
 * commercial). MET Norway publishes its data under NLOD 2.0 and CC BY 4.0, free to use, with credit.
 *
 * The rules of api.met.no/doc/TermsOfService this module (and src/geo.js around it) follows:
 *  - an identifying User-Agent with a contact (config.providerUserAgent: site + support address);
 *  - HTTPS only; coordinates with at most 4 decimals (we send the 0.1 degree grid cell: 1 decimal);
 *  - never repeat a request before its `Expires` time, and send If-Modified-Since when we hold an
 *    older copy (geo.js keeps every cell at least WEATHER_CACHE_MIN, 30 minutes, and until Expires);
 *  - well below 20 requests a second in total (WEATHER_PER_MIN upstream calls a minute, default 20);
 *  - phones never call MET directly: the gateway is the proxy the terms ask for;
 *  - credit: "Based on data from MET Norway" + licence (shown in the app and on the website).
 *
 * Pure functions only (no network): geo.js does the call with its own fetch, queue and logging.
 */
const DEFAULT_BASE = 'https://api.met.no';
const SOURCE = 'MET Norway';
const ATTRIBUTION = 'Weather: based on data from MET Norway (api.met.no), licence CC BY 4.0 / NLOD 2.0';
const MAX_HOURS = 72;

/** The provider in use: 'metno' (default) | 'open-meteo'. */
function providerOf(env = process.env) {
  const v = String(env.WEATHER_PROVIDER || '').trim().toLowerCase();
  return v === 'open-meteo' || v === 'openmeteo' ? 'open-meteo' : 'metno';
}

/** Base URL for MET: WEATHER_MET_URL, else the configured WEATHER_URL when it is not Open-Meteo's. */
function baseOf(weatherUrl, env = process.env) {
  const own = String(env.WEATHER_MET_URL || '').trim().replace(/\/+$/, '');
  if (own) return own;
  const u = String(weatherUrl || '').trim().replace(/\/+$/, '');
  return u && !/open-meteo/i.test(u) ? u : DEFAULT_BASE;
}

/** `complete` carries probability_of_precipitation (6 hour windows); 1 decimal = the grid cell. */
function urlOf(base, la, ln) {
  const f = (v) => String(Math.round(Number(v) * 10) / 10);
  return `${base}/weatherapi/locationforecast/2.0/complete?lat=${f(la)}&lon=${f(ln)}`;
}

/** MET symbol_code ("lightrainshowers_day", "heavyrainandthunder") -> the WMO code the apps read. */
function wmoOf(symbol) {
  const s = String(symbol || '').toLowerCase().replace(/_(day|night|polartwilight)$/, '');
  if (!s) return null;
  if (s.includes('thunder')) return 95;
  const heavy = s.startsWith('heavy'), light = s.startsWith('light');
  if (s.includes('sleet')) return heavy ? 67 : 66;
  if (s.includes('snow')) return s.includes('showers') ? (heavy ? 86 : 85) : heavy ? 75 : light ? 71 : 73;
  if (s.includes('rainshowers')) return heavy ? 82 : light ? 80 : 81;
  if (s.includes('rain')) return heavy ? 65 : light ? 61 : 63;
  if (s === 'fog') return 45;
  if (s === 'cloudy') return 3;
  if (s === 'partlycloudy') return 2;
  if (s === 'fair') return 1;
  if (s === 'clearsky') return 0;
  return null;
}
const isWet = (code) => code != null && ((code >= 51 && code <= 67) || (code >= 80 && code <= 82) || code >= 95);

/**
 * Chance of rain for ONE hour. MET gives a probability only for 6 hour windows, so this is derived
 * (and the credit says "based on"): an hour with forecast rain is at least 60, a dry hour is at
 * most 45 even when the 6 hour window is likely wet (the apps warn from 50).
 */
function hourProb(mm, code, p6) {
  const wet = (Number.isFinite(mm) && mm >= 0.1) || isWet(code);
  const p = Number.isFinite(p6) ? Math.max(0, Math.min(100, Math.round(p6))) : null;
  if (wet) return Math.max(p == null ? 0 : p, Number.isFinite(mm) && mm >= 0.5 ? 80 : 60);
  return p == null ? 5 : Math.min(p, 45);
}

/**
 * One Locationforecast answer reduced to what geo.js stores per cell:
 * { hourlyFrom (epoch s), probs[], mm[], codes[], temps[] } (hourly slots, up to 72), or null.
 * Hours given only as 6 hour steps are spread over their six slots.
 */
function cellOf(json) {
  const ts = json && json.properties && Array.isArray(json.properties.timeseries) ? json.properties.timeseries : null;
  if (!ts || !ts.length) return null;
  const t0 = Date.parse(ts[0] && ts[0].time);
  if (!Number.isFinite(t0)) return null;
  const from = Math.floor(t0 / 3600000) * 3600;
  const probs = [], mm = [], codes = [], temps = [];
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const put = (i, p, m, c, t) => {
    if (i < 0 || i >= MAX_HOURS || probs[i] !== undefined) return;
    probs[i] = p; mm[i] = m == null ? null : Math.round(m * 10) / 10; codes[i] = c; temps[i] = t == null ? null : Math.round(t * 10) / 10;
  };
  for (const e of ts) {
    const at = Date.parse(e && e.time);
    const d = e && e.data;
    if (!Number.isFinite(at) || !d) continue;
    const i = Math.round((at / 1000 - from) / 3600);
    const temp = num(d.instant && d.instant.details && d.instant.details.air_temperature);
    const h1 = d.next_1_hours, h6 = d.next_6_hours;
    const p6 = num(h6 && h6.details && h6.details.probability_of_precipitation);
    if (h1) {
      const m = num(h1.details && h1.details.precipitation_amount);
      const c = wmoOf(h1.summary && h1.summary.symbol_code);
      const p1 = num(h1.details && h1.details.probability_of_precipitation);
      put(i, p1 != null ? Math.round(p1) : hourProb(m, c, p6), m, c, temp);
    } else if (h6) {
      const total = num(h6.details && h6.details.precipitation_amount);
      const m = total == null ? null : total / 6;
      const c = wmoOf(h6.summary && h6.summary.symbol_code);
      for (let k = 0; k < 6; k++) put(i + k, hourProb(m, c, p6), m, c, temp);
    }
  }
  const n = probs.length;
  if (!n) return null;
  const fill = (a) => Array.from({ length: n }, (_, i) => (a[i] === undefined ? null : a[i]));
  return { hourlyFrom: from, probs: fill(probs), mm: fill(mm), codes: fill(codes), temps: fill(temps) };
}

/** `Expires` header -> epoch ms, at most 6 hours ahead (a broken header never pins a cell), or 0. */
function expiresMs(header, now = Date.now()) {
  const t = Date.parse(String(header || ''));
  if (!Number.isFinite(t) || t <= now) return 0;
  return Math.min(t, now + 6 * 3600 * 1000);
}

module.exports = { DEFAULT_BASE, SOURCE, ATTRIBUTION, MAX_HOURS, providerOf, baseOf, urlOf, wmoOf, hourProb, cellOf, expiresMs };
