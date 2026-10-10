'use strict';
const crypto = require('crypto');
const { decodePolyline, cumulative, pointToSegment } = require('./geo_math');

// Provider objects stay here; the wire contract uses metres, seconds and epoch ms.
const FILTERS = Object.freeze({
  FUEL: '[amenity=fuel]', FOOD: '[amenity~"^(restaurant|cafe|fast_food)$"]',
  HOSPITAL: '[amenity=hospital]', REPAIR: '[shop=motorcycle]["service:motorcycle:repair"=yes]',
  REST: '[highway=rest_area]', STAY: '[tourism~"^(hotel|motel|hostel|guest_house)$"]',
  PHARMACY: '[amenity=pharmacy]', TYRE: '[shop=tyres]', WASHROOM: '[amenity=toilets]',
  ATM: '[amenity=atm]', POLICE: '[amenity=police]', PARKING: '[amenity=parking]', SCENIC: '[tourism=viewpoint]',
});
class EssentialsError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
function requestOf(body) {
  if (!body || typeof body.polyline !== 'string' || body.polyline.length > 100000 ||
      !Object.hasOwn(FILTERS, body.category) || !Number.isFinite(body.fromM) || body.fromM < 0 || body.approximate === true) {
    throw new EssentialsError(400, 'INVALID_ESSENTIALS_ROUTE');
  }
  const line = decodePolyline(body.polyline, 20000);
  if (!line || line.length < 2 || line.length > 20000 || line.some(p => !Number.isFinite(p.lat) || !Number.isFinite(p.lng) || Math.abs(p.lat) > 85 || Math.abs(p.lng) > 180)) {
    throw new EssentialsError(400, 'INVALID_ESSENTIALS_ROUTE');
  }
  const cum = cumulative(line), length = cum[cum.length - 1];
  if (!(length > 0) || length > 10000000 || body.fromM > length + 100) throw new EssentialsError(400, 'INVALID_ESSENTIALS_ROUTE');
  // Overlapping windows avoid work on each GPS update.
  const fromM = Math.floor(body.fromM / 5000) * 5000;
  const toM = Math.min(length, fromM + 150000);
  const routeKey = crypto.createHash('sha256').update(body.polyline).digest('hex');
  return { line, cum, fromM, toM, routeKey, category: body.category };
}
function pointAt(r, m) {
  let i = 0;
  while (i < r.line.length - 2 && r.cum[i + 1] < m) i++;
  const a = r.line[i], b = r.line[i + 1];
  const t = Math.max(0, Math.min(1, (m - r.cum[i]) / (r.cum[i + 1] - r.cum[i] || 1)));
  return { lat: a.lat + (b.lat - a.lat) * t, lng: a.lng + (b.lng - a.lng) * t };
}
// Each pass of a loop is a separate visit. Never deduplicate by place id alone.
function visits(r, p) {
  const out = []; let best = null;
  const flush = () => { if (best) out.push(best); best = null; };
  for (let i = 0; i < r.line.length - 1; i++) {
    if (r.cum[i + 1] < r.fromM || r.cum[i] > r.toM) continue;
    const hit = pointToSegment(p, r.line[i], r.line[i + 1]);
    const along = r.cum[i] + hit.t * (r.cum[i + 1] - r.cum[i]);
    if (hit.dist > 1500 || along < r.fromM || along > r.toM) { flush(); continue; }
    if (!best || hit.dist < best.offM) best = { routePositionM: along, offM: hit.dist };
  }
  flush(); return out;
}
class OverpassPlacesProvider {
  constructor({ url, fetchImpl = globalThis.fetch }) { this.url = url; this.fetch = fetchImpl; }
  async corridor(r) {
    // Preserve every bend. Bounded query size; never silently simplify across hairpins.
    const pts = [pointAt(r, r.fromM), ...r.line.filter((_, i) => r.cum[i] > r.fromM && r.cum[i] < r.toM), pointAt(r, r.toM)];
    if (pts.length > 4000) throw new EssentialsError(422, 'ESSENTIALS_ROUTE_TOO_DENSE');
    const coords = pts.map(p => `${p.lat.toFixed(5)},${p.lng.toFixed(5)}`).join(',');
    const query = `[out:json][timeout:12];nwr${FILTERS[r.category]}(around:1500,${coords});out center tags 501;`;
    const res = await this.fetch(this.url, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': 'CoRoute route essentials' }, body: `data=${encodeURIComponent(query)}`, signal: AbortSignal.timeout(14000) });
    if (!res.ok) throw new EssentialsError(503, 'ESSENTIALS_PROVIDER_UNAVAILABLE');
    const j = await res.json();
    if (!Array.isArray(j.elements) || j.remark) throw new EssentialsError(503, 'ESSENTIALS_PROVIDER_INCOMPLETE');
    const places = j.elements.slice(0, 500).map(e => ({
      placeId: `osm:${e.type}:${e.id}`, name: String(e.tags?.name || 'Mapped place').slice(0, 120),
      lat: e.lat ?? e.center?.lat, lng: e.lon ?? e.center?.lon, category: r.category,
      openingHours: typeof e.tags?.opening_hours === 'string' ? e.tags.opening_hours.slice(0, 200) : null,
      source: 'OpenStreetMap',
    })).filter(p => Number.isFinite(p.lat) && Number.isFinite(p.lng) && Math.abs(p.lat) <= 85 && Math.abs(p.lng) <= 180);
    return { places, complete: j.elements.length < 501 };
  }
}
class EssentialsService {
  constructor({ repo, places, routing, clock = Date.now, maxCandidates = 12 }) {
    this.repo = repo; this.places = places; this.routing = routing; this.clock = clock;
    this.maxCandidates = maxCandidates; this.inflight = new Map(); this.started = [];
  }
  async query(body) {
    const r = requestOf(body);
    const key = `ess:v2:${r.routeKey}:${r.category}:${r.fromM}`;
    const cached = await this.repo.geoCacheGet(key).catch(() => null);
    const age = this.clock() - (cached?.value?.fetchedAt || 0);
    if (cached?.value && age >= 0 && age < 1800000) return { ...cached.value, stale: false };
    if (this.inflight.has(key)) return this.inflight.get(key);
    const run = this._fetch(r).then(async value => {
      await this.repo.geoCachePut(key, value).catch(() => {}); return value;
    }).catch(e => {
      if (cached?.value && age >= 0 && age < 7 * 86400000) return { ...cached.value, stale: true };
      throw e;
    }).finally(() => this.inflight.delete(key));
    this.inflight.set(key, run); return run;
  }
  async _fetch(r) {
    if (!this.places || !this.routing) throw new EssentialsError(503, 'ESSENTIALS_NOT_CONFIGURED');
    const now = this.clock(); this.started = this.started.filter(t => now - t < 60000);
    if (this.started.length >= 4 || this.inflight.size >= 2) throw new EssentialsError(429, 'ESSENTIALS_BUSY');
    this.started.push(now);
    const found = await this.places.corridor(r);
    const seen = new Set();
    const candidates = found.places.flatMap(p => visits(r, p).map(v => ({ ...p, ...v })))
      .sort((a, b) => a.routePositionM - b.routePositionM).filter(p => {
        const k = `${p.placeId}:${Math.round(p.routePositionM / 100)}`;
        if (seen.has(k)) return false; seen.add(k); return true;
      });
    let complete = found.complete && candidates.length <= this.maxCandidates;
    const places = [];
    let routingFailures = 0;
    for (const p of candidates.slice(0, this.maxCandidates)) {
      if (this.clock() - now > 25000) { complete = false; break; }
      // Compare a visit with the same directed baseline, including the return to the route.
      const entryM = Math.max(r.fromM, p.routePositionM - 1000), exitM = Math.min(r.toM, p.routePositionM + 1000);
      const a = pointAt(r, entryM), b = pointAt(r, exitM);
      try {
        const base = await this.routing([a, b]);
        const via = await this.routing([a, p, b]);
        if (!base || !via || via.approximate || base.approximate || via.legs?.length !== 2) { complete = false; routingFailures++; continue; }
        const numbers = [base.distanceM, base.durationS, via.distanceM, via.durationS, via.legs[0].distanceM];
        if (!numbers.every(n => Number.isFinite(n) && n >= 0)) { complete = false; routingFailures++; continue; }
        // A router choosing a shortcut means these anchors do not represent this route section.
        if (Math.abs(base.distanceM - (exitM - entryM)) > Math.max(200, (exitM - entryM) * 0.15)) { complete = false; routingFailures++; continue; }
        const detourDistanceM = Math.max(0, via.distanceM - base.distanceM);
        if (detourDistanceM > 20000) continue;
        places.push({ ...p, entryM, exitM, accessDistanceM: via.legs[0].distanceM,
          detourDistanceM, detourDurationS: Math.max(0, via.durationS - base.durationS),
          visitId: `${p.placeId}:${Math.round(p.routePositionM)}`, openStatus: 'unknown' });
      } catch (_) { complete = false; routingFailures++; }
    }
    if (candidates.length && !places.length && routingFailures) throw new EssentialsError(503, 'ESSENTIALS_ROAD_ACCESS_UNAVAILABLE');
    return { version: 1, routeKey: r.routeKey, category: r.category, fromM: r.fromM, toM: r.toM,
      complete, stale: false, fetchedAt: this.clock(), places, attribution: '© OpenStreetMap contributors' };
  }
}
module.exports = { EssentialsService, EssentialsError, OverpassPlacesProvider, requestOf, visits, pointAt, FILTERS };
