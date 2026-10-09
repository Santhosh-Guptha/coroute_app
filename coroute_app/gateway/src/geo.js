'use strict';
/**
 * GeoProxy: place search, reverse geocoding and routing through free
 * OpenStreetMap services (Nominatim, OSRM), proxied by the gateway so that
 *
 *   - results are cached in Oracle (geo_cache) and shared by every rider,
 *   - the services' usage policies are respected (one queued request at a
 *     time, >= GEO_MIN_INTERVAL_MS apart, proper User-Agent with contact),
 *   - providers can be changed from the environment without an app release.
 */
const crypto = require('crypto');
const config = require('./config');
const { encodePolyline, haversine } = require('./geo_math');

const UA = () => `CoRoute/3.1 (+https://coroute.duckdns.org; ${config.geoContact})`;
const round = (n, d) => Math.round(n * 10 ** d) / 10 ** d;
const hash = (s) => crypto.createHash('sha1').update(s).digest('hex').slice(0, 24);

class GeoProxy {
  constructor({ repo, fetchImpl = globalThis.fetch, logger = console } = {}) {
    this.repo = repo; this.fetch = fetchImpl; this.log = logger;
    this.chain = Promise.resolve();
    this.lastCallAt = 0;
    this.inflight = new Map();
    this.queued = 0; // upstream calls waiting in or running through _queued
    this.tableCache = new Map(); // "lat,lng>lat,lng" (3 dp) -> { at, value } (memory LRU, never in geo_cache)
    // 3.16 weather: grid cell (0.1 deg) -> { at, value } memory LRU in front of geo_cache; upstream calls this minute.
    this.weatherCache = new Map();
    this.weatherTimes = [];
    this.hospitalInflight = new Map();
  }

  get searchEnabled() { return !!config.geoSearchUrl; }
  get routeEnabled() { return !!config.geoRouteUrl; }
  get weatherEnabled() { return !!config.weatherUrl; }

  /** Serialises upstream calls and spaces them out. */
  _queued(fn) {
    this.queued++;
    const run = this.chain.then(async () => {
      const wait = this.lastCallAt + config.geoMinIntervalMs - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      this.lastCallAt = Date.now();
      return fn();
    }).finally(() => { this.queued--; });
    this.chain = run.catch(() => {});
    return run;
  }

  /** Rough time (ms) a new upstream call would wait in the polite queue before it starts. */
  queueWaitMs() {
    const spacing = config.geoMinIntervalMs;
    const own = Math.max(0, this.lastCallAt + spacing - Date.now());
    return own + this.queued * Math.max(spacing, 250);
  }

  async _cached(k, ttlDays, producer) {
    const hit = await this.repo.geoCacheGet(k).catch(() => null);
    if (hit && Date.now() - (hit.createdAt || 0) < ttlDays * 86400000) return hit.value;
    if (this.inflight.has(k)) return this.inflight.get(k);
    const p = (async () => {
      const value = await producer();
      if (value !== null && value !== undefined) await this.repo.geoCachePut(k, value).catch(() => {});
      return value;
    })().finally(() => this.inflight.delete(k));
    this.inflight.set(k, p);
    return p;
  }

  async _getJson(url) {
    const res = await this.fetch(url, { headers: { 'User-Agent': UA(), Accept: 'application/json', 'Accept-Language': 'en' }, signal: AbortSignal.timeout(8000) });
    if (!res.ok) throw new Error(`upstream ${res.status}`);
    return res.json();
  }

  /** Short, human place name for timeline entries ("HP fuel station, Shamshabad"). */
  async reverse(lat, lng) {
    if (!this.searchEnabled) return null;
    const la = round(lat, 4), ln = round(lng, 4);
    return this._cached(`rev:${la},${ln}`, config.geoCacheDays, async () => {
      try {
        const j = await this._queued(() => this._getJson(`${config.geoSearchUrl}/reverse?format=jsonv2&zoom=17&addressdetails=1&lat=${la}&lon=${ln}`));
        return shortName(j);
      } catch (e) { this.log.warn('[geo] reverse failed', e.message); return null; }
    });
  }

  /**
   * Place search for the app's search box.
   *
   * Home country first: places near the rider inside the country, then the
   * rest of the country, and only when the country has nothing, the world
   * (marked outside: true). Uses Photon, which is built for search as you
   * type; falls back to Nominatim if Photon is unavailable.
   */
  async search(q, { lat, lng } = {}) {
    const query = String(q || '').trim().slice(0, 120);
    if (query.length < 3) return [];
    const near = Number.isFinite(lat) && Number.isFinite(lng) && !(lat === 0 && lng === 0) ? { lat: round(lat, 2), lng: round(lng, 2) } : null;
    const k = `q2:${hash(`${query.toLowerCase()}|${near ? `${near.lat},${near.lng}` : ''}|${config.geoCountry}`)}`;
    return (await this._cached(k, config.geoCacheDays, async () => {
      let results = null;
      if (config.geoPhotonUrl) results = await this._photonSearch(query, near).catch((e) => { this.log.warn('[geo] photon failed', e.message); return null; });
      if (results === null && this.searchEnabled) results = await this._nominatimSearch(query, near).catch((e) => { this.log.warn('[geo] search failed', e.message); return null; });
      return results;
    })) || [];
  }

  async _photonGet(params) {
    const run = async () => {
      const wait = (this.lastPhotonAt || 0) + config.geoPhotonMinIntervalMs - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      this.lastPhotonAt = Date.now();
      return this._getJson(`${config.geoPhotonUrl}/api/?${params}`);
    };
    const p = (this.photonChain || Promise.resolve()).then(run);
    this.photonChain = p.catch(() => {});
    return p;
  }

  async _photonSearch(query, near) {
    const base = `q=${encodeURIComponent(query)}&limit=10&lang=en`;
    const bias = near ? `&lat=${near.lat}&lon=${near.lng}&zoom=10&location_bias_scale=0.4` : '';
    const bbox = config.geoCountryBbox.length === 4 && config.geoCountryBbox.every(Number.isFinite) ? `&bbox=${config.geoCountryBbox.join(',')}` : '';
    const home = config.geoCountry.toUpperCase();
    // 1. Inside the home country, nearest first.
    let feats = ((await this._photonGet(base + bias + bbox))?.features || []).filter((f) => !home || f.properties?.countrycode === home);
    let outside = false;
    // 2. Nothing at home: the world.
    if (feats.length === 0) {
      feats = (await this._photonGet(base + bias))?.features || [];
      outside = true;
    }
    return dedupe(feats.map((f) => photonResult(f, near, home)).filter(Boolean).map((r) => ({ ...r, outside: outside || r.outside })));
  }

  async _nominatimSearch(query, near) {
    const bias = near ? `&viewbox=${round(near.lng - 1, 2)},${round(near.lat + 1, 2)},${round(near.lng + 1, 2)},${round(near.lat - 1, 2)}` : '';
    const get = (extra) => this._queued(() => this._getJson(`${config.geoSearchUrl}/search?format=jsonv2&addressdetails=1&limit=8&q=${encodeURIComponent(query)}${bias}${extra}`));
    let rows = config.geoCountry ? await get(`&countrycodes=${config.geoCountry}`) : [];
    let outside = false;
    if (!Array.isArray(rows) || rows.length === 0) { rows = await get(''); outside = true; }
    return dedupe((Array.isArray(rows) ? rows : []).map((r) => {
      const la = Number(r.lat), ln = Number(r.lon);
      if (!Number.isFinite(la) || !Number.isFinite(ln)) return null;
      const a = r.address || {};
      return {
        name: r.name || shortName(r) || r.display_name,
        displayName: indianLine(r.name, a.suburb || a.village || a.town || a.city, a.state_district || a.county, a.state, a.country_code !== config.geoCountry ? a.country : ''),
        lat: la, lng: ln, type: r.type || '',
        distanceM: near ? Math.round(haversine(near.lat, near.lng, la, ln)) : null,
        outside: outside || (a.country_code && a.country_code !== config.geoCountry),
      };
    }).filter(Boolean));
  }

  /** Driving route through 2..25 waypoints. Returns { distanceM, durationS, polyline, legs[] } or null. */
  async route(waypoints) {
    if (!this.routeEnabled || !Array.isArray(waypoints) || waypoints.length < 2 || waypoints.length > 25) return null;
    const wp = waypoints.map((p) => ({ lat: round(Number(p.lat), 5), lng: round(Number(p.lng), 5) }));
    if (wp.some((p) => !(Math.abs(p.lat) <= 90 && Math.abs(p.lng) <= 180))) return null;
    const coords = wp.map((p) => `${p.lng},${p.lat}`).join(';');
    return this._cached(`r:${hash(coords)}`, 7, async () => {
      try {
        const j = await this._queued(() => this._getJson(`${config.geoRouteUrl}/route/v1/driving/${coords}?overview=full&geometries=geojson&steps=false`));
        const r = j?.routes?.[0];
        if (!r) return null;
        const line = (r.geometry?.coordinates || []).map(([x, y]) => ({ lat: y, lng: x }));
        return {
          distanceM: Math.round(r.distance || 0), durationS: Math.round(r.duration || 0), polyline: encodePolyline(line),
          legs: (r.legs || []).map((l) => ({ distanceM: Math.round(l.distance || 0), durationS: Math.round(l.duration || 0) })),
        };
      } catch (e) { this.log.warn('[geo] route failed', e.message); return null; }
    });
  }

  /**
   * Road distance and time from 1 to 3 sources to one destination (OSRM table service), for the
   * safety network's "can they really get there" check. Through the same polite queue, with its
   * own timeout. Answers are kept in a small memory LRU (3 dp keys, NET_OSRM_CACHE_MIN), never in
   * geo_cache. Returns [{distanceM, durationS} | null] per source, or null when routing is
   * disabled or the call failed / timed out.
   */
  async table(sources, dest, { timeoutMs = config.netOsrmTimeoutMs } = {}) {
    if (!this.routeEnabled || !Array.isArray(sources) || sources.length < 1 || sources.length > 3 || !dest) return null;
    const ok = (p) => p && Math.abs(Number(p.lat)) <= 90 && Math.abs(Number(p.lng)) <= 180;
    if (!ok(dest) || !sources.every(ok)) return null;
    const key = (p) => `${round(Number(p.lat), 3)},${round(Number(p.lng), 3)}`;
    const dk = key(dest);
    const ttl = config.netOsrmCacheMin * 60000;
    const out = new Array(sources.length).fill(undefined);
    const missing = [];
    sources.forEach((s, i) => {
      const k = `${key(s)}>${dk}`;
      const hit = this.tableCache.get(k);
      if (hit && Date.now() - hit.at < ttl) {
        this.tableCache.delete(k); this.tableCache.set(k, hit); // LRU touch
        out[i] = hit.value;
      } else {
        missing.push(i);
      }
    });
    if (!missing.length) return out;
    const pts = [...missing.map((i) => sources[i]), dest].map((p) => `${round(Number(p.lng), 5)},${round(Number(p.lat), 5)}`).join(';');
    const srcIdx = missing.map((_, i) => i).join(';');
    const url = `${config.geoRouteUrl}/table/v1/driving/${pts}?sources=${srcIdx}&destinations=${missing.length}&annotations=distance,duration`;
    let j = null;
    try {
      j = await this._queued(async () => {
        const res = await this.fetch(url, { headers: { 'User-Agent': UA(), Accept: 'application/json' }, signal: AbortSignal.timeout(timeoutMs) });
        if (!res.ok) throw new Error(`upstream ${res.status}`);
        return res.json();
      });
    } catch (e) {
      this.log.warn('[geo] table failed', e.message);
      return null;
    }
    if (!j || (j.code && j.code !== 'Ok') || !Array.isArray(j.distances)) return null;
    missing.forEach((srcI, row) => {
      const d = Number(j.distances?.[row]?.[0]);
      const t = Number(j.durations?.[row]?.[0]);
      const value = Number.isFinite(d) && j.distances[row][0] !== null ? { distanceM: Math.round(d), durationS: Number.isFinite(t) ? Math.round(t) : null } : null;
      out[srcI] = value;
      const k = `${key(sources[srcI])}>${dk}`;
      this.tableCache.set(k, { at: Date.now(), value });
      while (this.tableCache.size > config.netOsrmCache) this.tableCache.delete(this.tableCache.keys().next().value);
    });
    return out.map((v) => (v === undefined ? null : v));
  }

  // ---------------------------------------------------------------- 3.16 weather (Open-Meteo)
  /**
   * Hourly rain forecast for 1 to 5 route points ({lat, lng, at}: `at` in epoch seconds). Points
   * are rounded to a 0.1 degree grid (about 10 km) and cached for WEATHER_CACHE_MIN (memory LRU of
   * 500 cells in front of geo_cache), so every rider on the same road shares one forecast. Missing
   * cells go upstream in ONE call, within a global budget of WEATHER_PER_MIN calls a minute; over
   * budget, cached cells are answered and the rest are null. Returns
   * { points: [{lat, lng, at, precipProb, precipMm, code, tempC} | null], source, attribution }
   * or null when disabled. Nothing about the points is logged.
   */
  async weather(points) {
    if (!this.weatherEnabled || !Array.isArray(points) || !points.length) return null;
    const now = Date.now();
    const ttl = config.weatherCacheMin * 60000;
    const keys = points.map((p) => ({ la: round(p.lat, 1), ln: round(p.lng, 1) })).map((g) => ({ ...g, k: `wx:${g.la},${g.ln}` }));
    const cells = new Map(); // k -> stored forecast
    const missing = new Map(); // k -> grid
    for (const g of keys) {
      if (cells.has(g.k) || missing.has(g.k)) continue;
      const mem = this.weatherCache.get(g.k);
      if (mem && now - mem.at < ttl) { this.weatherCache.delete(g.k); this.weatherCache.set(g.k, mem); cells.set(g.k, mem.value); continue; }
      const hit = await this.repo.geoCacheGet(g.k).catch(() => null);
      if (hit && hit.value && now - (hit.createdAt || 0) < ttl) { this._wxRemember(g.k, hit.value, hit.createdAt); cells.set(g.k, hit.value); continue; }
      missing.set(g.k, g);
    }
    if (missing.size) {
      this.weatherTimes = this.weatherTimes.filter((x) => now - x < 60000);
      if (this.weatherTimes.length < config.weatherPerMin) {
        this.weatherTimes.push(now);
        const list = [...missing.values()];
        const fetched = await this._weatherFetch(list);
        if (fetched) {
          list.forEach((g, i) => {
            const v = fetched[i];
            if (!v) return;
            cells.set(g.k, v);
            this._wxRemember(g.k, v, now);
            this.repo.geoCachePut(g.k, v).catch(() => {});
          });
        }
      }
    }
    const out = points.map((p, i) => {
      const f = cells.get(keys[i].k);
      if (!f || !Array.isArray(f.probs)) return null;
      const idx = Math.floor((p.at - f.hourlyFrom) / 3600);
      if (idx < 0 || idx >= f.probs.length) return null;
      const n = (v) => (Number.isFinite(v) ? v : null);
      return { lat: round(p.lat, 5), lng: round(p.lng, 5), at: p.at, precipProb: n(f.probs[idx]), precipMm: n(f.mm[idx]), code: n(f.codes[idx]), tempC: n(f.temps[idx]) };
    });
    return { points: out, source: 'Open-Meteo', attribution: 'Weather data by Open-Meteo.com (CC BY 4.0)' };
  }

  _wxRemember(k, value, at) {
    this.weatherCache.delete(k);
    this.weatherCache.set(k, { at: at || Date.now(), value });
    while (this.weatherCache.size > 500) this.weatherCache.delete(this.weatherCache.keys().next().value);
  }

  /** One Open-Meteo call for several grid cells. Returns one stored forecast per cell (or null), or null when the call failed. */
  async _weatherFetch(cells) {
    const lat = cells.map((g) => g.la).join(','), lng = cells.map((g) => g.ln).join(',');
    const url = `${config.weatherUrl}/v1/forecast?latitude=${lat}&longitude=${lng}&hourly=precipitation_probability,precipitation,weather_code,temperature_2m&forecast_days=3&timezone=UTC`;
    let j;
    try {
      j = await this._queued(() => this._getJson(url));
    } catch (e) {
      this.log.warn('[geo] weather failed', String(e && e.message || e).replace(/[0-9.,-]{6,}/g, 'x'));
      return null;
    }
    const list = Array.isArray(j) ? j : (j && typeof j === 'object' ? [j] : []);
    return cells.map((g, i) => weatherCell(list[i]));
  }

  // ---------------------------------------------------------------- 3.16 nearest hospital
  /**
   * The nearest hospital to a point (Nominatim amenity search, bounded to about 15 km around it),
   * for the incident sheet. One upstream call per 1 km grid cell, cached 30 days; "nothing found"
   * is cached 6 hours so a rural emergency is not retried at every alert. Returns
   * { name, lat, lng, distanceM } or null. Never throws.
   */
  async nearestHospital(lat, lng) {
    if (!this.searchEnabled || !(Math.abs(Number(lat)) <= 90 && Math.abs(Number(lng)) <= 180) || !(lat || lng)) return null;
    const la = round(lat, 2), ln = round(lng, 2);
    const k = `hosp:${la},${ln}`;
    const now = Date.now();
    const hit = await this.repo.geoCacheGet(k).catch(() => null);
    if (hit && hit.value) {
      const age = now - (hit.createdAt || 0);
      if (hit.value.none ? age < 6 * 3600000 : age < config.geoCacheDays * 86400000) return hit.value.none ? null : hit.value;
    }
    if (this.hospitalInflight.has(k)) return this.hospitalInflight.get(k);
    const p = (async () => {
      let value = null;
      try {
        const box = `${round(ln - 0.15, 3)},${round(la + 0.15, 3)},${round(ln + 0.15, 3)},${round(la - 0.15, 3)}`;
        const rows = await this._queued(() => this._getJson(`${config.geoSearchUrl}/search?format=jsonv2&q=hospital&limit=5&bounded=1&viewbox=${box}`));
        let best = null;
        for (const r of Array.isArray(rows) ? rows : []) {
          const y = Number(r.lat), x = Number(r.lon);
          if (!Number.isFinite(y) || !Number.isFinite(x)) continue;
          const d = haversine(la, ln, y, x);
          if (!best || d < best.distanceM) best = { name: String(r.name || shortName(r) || 'Hospital').slice(0, 80), lat: round(y, 5), lng: round(x, 5), distanceM: Math.round(d) };
        }
        value = best;
      } catch (e) {
        this.log.warn('[geo] hospital lookup failed', e.message);
        return null; // not cached: the next alert in this cell may try again
      }
      await this.repo.geoCachePut(k, value || { none: true }).catch(() => {});
      return value;
    })().finally(() => this.hospitalInflight.delete(k));
    this.hospitalInflight.set(k, p);
    return p;
  }
}

/** One Open-Meteo location result reduced to what is stored: { hourlyFrom (epoch s), probs[], mm[], codes[], temps[] }. */
function weatherCell(r) {
  const h = r && r.hourly;
  if (!h || !Array.isArray(h.time) || !h.time.length) return null;
  const t0 = h.time[0];
  const from = typeof t0 === 'number' ? t0 : Math.floor(Date.parse(/[Z+]/.test(String(t0).slice(10)) ? t0 : `${t0}Z`) / 1000);
  if (!Number.isFinite(from)) return null;
  const n = h.time.length;
  const arr = (list, int) => Array.from({ length: n }, (_, i) => {
    const v = Number(Array.isArray(list) ? list[i] : NaN);
    return Number.isFinite(v) ? (int ? Math.round(v) : Math.round(v * 10) / 10) : null;
  });
  return { hourlyFrom: from, probs: arr(h.precipitation_probability, true), mm: arr(h.precipitation, false), codes: arr(h.weather_code, true), temps: arr(h.temperature_2m, false) };
}

/** "Shamshabad, Rangareddy, Telangana": locality, district, state (country only when abroad). */
function indianLine(...parts) {
  const out = [];
  for (const p of parts) {
    const v = String(p || '').trim();
    if (v && !out.some((o) => o.toLowerCase() === v.toLowerCase())) out.push(v);
  }
  return out.join(', ');
}

function photonResult(f, near, home) {
  const c = f?.geometry?.coordinates;
  const p = f?.properties || {};
  if (!Array.isArray(c) || !Number.isFinite(c[0]) || !Number.isFinite(c[1])) return null;
  const lat = c[1], lng = c[0];
  const street = [p.housenumber, p.street].filter(Boolean).join(' ');
  const name = p.name || street || p.locality || p.district || p.city || p.county || p.state;
  if (!name) return null;
  return {
    name: String(name).slice(0, 100),
    displayName: indianLine(p.name ? street : '', p.locality || p.district, p.city || p.county, p.state, p.countrycode !== home ? p.country : '').slice(0, 160) || String(name),
    lat, lng, type: p.osm_value || p.type || '',
    distanceM: near ? Math.round(haversine(near.lat, near.lng, lat, lng)) : null,
    outside: !!home && p.countrycode !== home,
  };
}

/** Same place reported twice (node and way, or two providers): keep the first. */
function dedupe(list) {
  const out = [];
  for (const r of list) {
    if (out.some((o) => o.name.toLowerCase() === r.name.toLowerCase() && haversine(o.lat, o.lng, r.lat, r.lng) < 300)) continue;
    out.push(r);
  }
  return out.slice(0, 8);
}

function shortName(r) {
  if (!r) return null;
  const a = r.address || {};
  const first = r.name || a.amenity || a.shop || a.tourism || a.road || a.hamlet || a.neighbourhood || '';
  const area = a.suburb || a.village || a.town || a.city || a.county || a.state_district || a.state || '';
  const out = [first, area].filter(Boolean).filter((v, i, arr) => arr.indexOf(v) === i).join(', ');
  return (out || r.display_name || '').slice(0, 120) || null;
}

module.exports = { GeoProxy, shortName, indianLine, photonResult, dedupe };
