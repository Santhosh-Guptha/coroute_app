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
const { encodePolyline } = require('./geo_math');

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

  async search(q, { lat, lng, countryCodes } = {}) {
    const query = String(q || '').trim().slice(0, 120);
    if (!this.searchEnabled || query.length < 3) return [];
    const bias = Number.isFinite(lat) && Number.isFinite(lng) ? `&viewbox=${round(lng - 1, 2)},${round(lat + 1, 2)},${round(lng + 1, 2)},${round(lat - 1, 2)}` : '';
    const cc = /^[a-z]{2}(,[a-z]{2})*$/.test(countryCodes || '') ? `&countrycodes=${countryCodes}` : '';
    const k = `q:${hash(`${query.toLowerCase()}|${bias}|${cc}`)}`;
    return (await this._cached(k, config.geoCacheDays, async () => {
      try {
        const j = await this._queued(() => this._getJson(`${config.geoSearchUrl}/search?format=jsonv2&addressdetails=1&limit=8&q=${encodeURIComponent(query)}${bias}${cc}`));
        return (Array.isArray(j) ? j : []).map((r) => ({ name: shortName(r) || r.display_name, displayName: r.display_name, lat: Number(r.lat), lng: Number(r.lon), type: r.type || '' }))
          .filter((r) => Number.isFinite(r.lat) && Number.isFinite(r.lng));
      } catch (e) { this.log.warn('[geo] search failed', e.message); return null; }
    })) || [];
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

function shortName(r) {
  if (!r) return null;
  const a = r.address || {};
  const first = r.name || a.amenity || a.shop || a.tourism || a.road || a.hamlet || a.neighbourhood || '';
  const area = a.suburb || a.village || a.town || a.city || a.county || a.state_district || a.state || '';
  const out = [first, area].filter(Boolean).filter((v, i, arr) => arr.indexOf(v) === i).join(', ');
  return (out || r.display_name || '').slice(0, 120) || null;
}

module.exports = { GeoProxy, shortName };
