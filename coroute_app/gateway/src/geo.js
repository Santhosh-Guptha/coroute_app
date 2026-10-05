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
  }

  get searchEnabled() { return !!config.geoSearchUrl; }
  get routeEnabled() { return !!config.geoRouteUrl; }

  /** Serialises upstream calls and spaces them out. */
  _queued(fn) {
    const run = this.chain.then(async () => {
      const wait = this.lastCallAt + config.geoMinIntervalMs - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      this.lastCallAt = Date.now();
      return fn();
    });
    this.chain = run.catch(() => {});
    return run;
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
