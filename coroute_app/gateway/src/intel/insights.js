'use strict';
/**
 * v3.62 intelligence insights (docs/intelligence/INSIGHTS_v3.62.md). Built from the k-anonymous cells and the 90-day
 * raw rows the round 4 engine already keeps; nothing new is collected and the privacy rules stay the same:
 *
 *   corridors       popular roads: chains of neighbouring geohash-6 road cells, each seen by >= max(5, INTEL_K_MIN)
 *                   distinct riders, ranked by ridden km (decayed); weekend share from the time buckets
 *   route difficulty  Easy / Moderate / Challenging for a planned line from twistiness, rough road, hazard density and
 *                   the night share of the ride, with reasons (cells under k-min are ignored)
 *   stop demand     where and when riders stop per geohash-4 area (fuel / food / other, 6 four-hour slots), k-min cells
 *   trends          monthly counters (km, riding hours, events by type) bumped while rows are folded: no raw scans
 *   rider risk      admin only. Aggregate: how many riders fall in low / medium / high event rates per 100 km (shown
 *                   only when the group has >= k riders). One rider: MASTER_ADMIN only, audited, computed on demand
 *                   from that rider's own raw rows (<= 90 days); never shown to riders, never stored per rider.
 *
 * Jobs: 'intel-insights' (job lease, daily) writes the results to `intel_insights` (one document per insight).
 * Caps: at most INTEL_INSIGHTS_MAX_CELLS cells per layer walk (default 20,000) and 20,000 raw rows for the risk view.
 */
const gh = require('./geohash');
const M = require('./math');

const COLL = 'intel_insights';
const RAW = 'intel_raw';
const CELLS = 'intel_cells';
const RISK_TYPES = new Set(['hard_brake', 'swerve', 'skid']);
const r5 = (x) => Math.round(x * 1e5) / 1e5;

function neighbours(cell) {
  const c = gh.center(cell);
  if (!c) return [];
  const { dLat, dLng } = gh.cellSize(cell.length);
  const out = [];
  for (const a of [-1, 0, 1]) for (const b of [-1, 0, 1]) {
    if (!a && !b) continue;
    const lat = c.lat + a * dLat, lng = c.lng + b * dLng;
    if (Math.abs(lat) < 90 && Math.abs(lng) < 180) out.push(gh.encode(lat, lng, cell.length));
  }
  return out;
}

/** Orders a component's cells into a walkable line: start at an end (fewest neighbours), then nearest unvisited. */
function orderPath(cells, adj) {
  if (cells.length <= 2) return cells.slice();
  let start = cells[0];
  for (const c of cells) if ((adj.get(c) || []).length < (adj.get(start) || []).length) start = c;
  const left = new Set(cells); left.delete(start);
  const path = [start];
  let cur = gh.center(start);
  while (left.size) {
    let best = null, bd = Infinity;
    for (const c of left) { const p = gh.center(c); const d = M.haversine(cur.lat, cur.lng, p.lat, p.lng); if (d < bd) { bd = d; best = c; } }
    left.delete(best); path.push(best); cur = gh.center(best);
  }
  return path;
}

/** Pure: corridors from road cells [{cell, km, riders, weekend, total}] (already filtered to k). */
function corridorsOf(cells, { minCells = 3, minKm = 5, top = 20, maxPoints = 60 } = {}) {
  const by = new Map(cells.filter((c) => c.km >= minKm).map((c) => [c.cell, c]));
  const adj = new Map();
  for (const c of by.keys()) adj.set(c, neighbours(c).filter((n) => by.has(n)));
  const seen = new Set(), out = [];
  for (const c of by.keys()) {
    if (seen.has(c)) continue;
    const comp = [], q = [c]; seen.add(c);
    while (q.length) { const x = q.pop(); comp.push(x); for (const n of adj.get(x)) if (!seen.has(n)) { seen.add(n); q.push(n); } }
    if (comp.length < minCells) continue;
    const km = comp.reduce((a, x) => a + by.get(x).km, 0);
    const wk = comp.reduce((a, x) => a + by.get(x).weekend, 0), tot = comp.reduce((a, x) => a + by.get(x).total, 0);
    const path = orderPath(comp, adj);
    const step = Math.max(1, Math.ceil(path.length / maxPoints));
    const pts = path.filter((_, i) => i % step === 0 || i === path.length - 1).map((x) => { const p = gh.center(x); return [r5(p.lat), r5(p.lng)]; });
    let len = 0;
    for (let i = 1; i < pts.length; i++) len += M.haversine(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]);
    out.push({ id: `${path[0]}-${path[path.length - 1]}`, region: path[0].slice(0, 4), cells: comp.length, lengthKm: Math.round(len / 100) / 10,
      riddenKm: Math.round(km), minRiders: Math.min(...comp.map((x) => by.get(x).riders)), weekendShare: tot > 0 ? Math.round((wk / tot) * 100) : 0,
      start: pts[0], end: pts[pts.length - 1], path: pts });
  }
  return out.sort((a, b) => b.riddenKm - a.riddenKm).slice(0, top);
}

/** Pure: difficulty label from measured parts. */
function difficultyOf({ km, twistyKm, ghatKm, roughKm, hazards, nightShare }) {
  const reasons = [];
  let pts = 0;
  const twShare = km > 0 ? twistyKm / km : 0;
  if (ghatKm >= 5 || twShare >= 0.25) { pts += 2; reasons.push(ghatKm >= 5 ? `${Math.round(ghatKm)} km of ghat roads` : `${Math.round(twShare * 100)}% twisty roads`); } else if (twShare >= 0.1) { pts += 1; reasons.push(`${Math.round(twShare * 100)}% twisty roads`); }
  const roughShare = km > 0 ? roughKm / km : 0;
  if (roughShare >= 0.15) { pts += 2; reasons.push(`${Math.round(roughShare * 100)}% rough road`); } else if (roughShare >= 0.05) { pts += 1; reasons.push(`some rough road (${Math.round(roughKm)} km)`); }
  const hz100 = km > 0 ? (hazards / km) * 100 : 0;
  if (hz100 >= 3) { pts += 2; reasons.push(`${hazards} hazard spots riders reported`); } else if (hz100 >= 1) { pts += 1; reasons.push(`${hazards} hazard spot${hazards === 1 ? '' : 's'} riders reported`); }
  if (nightShare >= 0.4) { pts += 2; reasons.push(`${Math.round(nightShare * 100)}% of the ride after dark`); } else if (nightShare >= 0.15) { pts += 1; reasons.push(`part of the ride after dark (${Math.round(nightShare * 100)}%)`); }
  if (km >= 400) { pts += 1; reasons.push(`long day (${Math.round(km)} km)`); }
  const level = pts >= 5 ? 'challenging' : pts >= 2 ? 'moderate' : 'easy';
  return { level, label: { easy: 'Easy', moderate: 'Moderate', challenging: 'Challenging' }[level], points: pts, reasons: reasons.slice(0, 4) };
}

/** Pure: night share of a ride starting at `startMs` lasting `hours` (IST; night 19:00 to 06:00). */
function nightShareOf(startMs, hours) {
  if (!Number.isFinite(startMs) || !(hours > 0)) return 0;
  const steps = Math.max(1, Math.round(hours * 4));
  let night = 0;
  for (let i = 0; i < steps; i++) {
    const h = M.istParts(startMs + ((i + 0.5) / steps) * hours * 3600000).hour;
    if (h >= 19 || h < 6) night++;
  }
  return night / steps;
}

/** Pure: risk bucket from events and km. */
function riskBucket(events, km) {
  if (!(km >= 50)) return null;
  const rate = (events / km) * 100;
  return { rate: Math.round(rate * 10) / 10, bucket: rate >= 6 ? 'high' : rate >= 2 ? 'medium' : 'low' };
}

class IntelInsights {
  constructor({ engine, soda, logger = console, clock = Date.now }) {
    Object.assign(this, { engine, soda, log: logger, clock });
  }

  get maxCells() { return Math.max(1000, Math.min(200000, Number(process.env.INTEL_INSIGHTS_MAX_CELLS) || 20000)); }
  get k() { return Math.max(5, this.engine.cfg.kMin); }

  async init() {
    await this.soda.ensureCollection(COLL);
    await this.soda.ensureIndex(COLL, { name: `${COLL}_id_ux`, unique: true, fields: [{ path: 'id' }] });
  }

  async get(id) { const r = await this.soda.findOne(COLL, { id }); return r ? r.value : null; }
  async put(id, value) { await this.soda.upsertBy(COLL, { id }, { ...value, id, computedAt: this.clock() }); }

  async _walk(layer, fn, signal) {
    let n = 0;
    for (let page = 0; n < this.maxCells; page++) {
      const rows = await this.soda.query(CELLS, { layer }, { limit: 1000, offset: page * 1000 });
      for (const r of rows) { fn(r.value); n++; }
      if (rows.length < 1000 || signal?.aborted) break;
      await M.yieldNow();
    }
    return n;
  }

  // ------------------------------------------------------------------ trends (bumped by the engine while folding)
  /** `tally`: { 'YYYY-MM': { km, hours, ev: { type: n } } } from one aggregate run. Merged into the trends doc. */
  async addTrends(tally) {
    const months = Object.keys(tally || {});
    if (!months.length) return;
    const cur = (await this.get('trends')) || { months: {} };
    const all = { ...(cur.months || {}) };
    for (const m of months) {
      const a = all[m] || { km: 0, hours: 0, ev: {} };
      const b = tally[m];
      a.km = Math.round((a.km + (b.km || 0)) * 10) / 10;
      a.hours = Math.round((a.hours + (b.hours || 0)) * 10) / 10;
      for (const [t, n] of Object.entries(b.ev || {})) a.ev[t] = (a.ev[t] || 0) + n;
      all[m] = a;
    }
    const keep = Object.keys(all).sort().slice(-24);
    await this.put('trends', { months: Object.fromEntries(keep.map((m) => [m, all[m]])) });
  }

  // ------------------------------------------------------------------ the daily job
  async run({ signal, now = this.clock() } = {}) {
    const out = {};
    out.corridors = (await this.computeCorridors({ signal, now })).length;
    if (!signal?.aborted) out.stopAreas = (await this.computeStopDemand({ signal, now })).length;
    if (!signal?.aborted) out.risk = await this.computeRisk({ signal, now });
    return out;
  }

  async computeCorridors({ signal, now = this.clock() } = {}) {
    const e = this.engine, k = this.k, H = e.cfg.halfLifeDays;
    const cells = [];
    await this._walk('rd', (v) => {
      if (e.riders(v, now) < k) return;
      const f = M.decay(1, v.at || now, now, H);
      const st = (v.st || []).map((x) => x * f);
      cells.push({ cell: v.cell, km: ((v.dist || 0) * f) / 1000, riders: e.riders(v, now), weekend: st.slice(6).reduce((a, b) => a + b, 0), total: st.reduce((a, b) => a + b, 0) });
    }, signal);
    const list = corridorsOf(cells);
    await this.put('corridors', { k, list });
    return list;
  }

  async computeStopDemand({ signal, now = this.clock() } = {}) {
    const e = this.engine, k = this.k, H = e.cfg.halfLifeDays;
    const areas = new Map();
    await this._walk('st', (v) => {
      if (e.riders(v, now) < k) return;
      const f = M.decay(1, v.at || now, now, H);
      const n = (v.n || 0) * f;
      if (n < 0.5) return;
      const g4 = v.g4 || String(v.cell).slice(0, 4);
      const a = areas.get(g4) || { area: g4, stops: 0, fuel: 0, food: 0, other: 0, tod: [0, 0, 0, 0, 0, 0], places: 0 };
      a.stops += n; a.places++;
      const cat = v.place?.cat;
      if (cat === 'fuel') a.fuel += n; else if (cat === 'food' || cat === 'restaurant' || cat === 'cafe') a.food += n; else a.other += n;
      (v.tod || []).forEach((x, i) => { if (i < 6) a.tod[i] += x * f; });
      areas.set(g4, a);
    }, signal);
    const list = [...areas.values()].map((a) => {
      const c = gh.center(a.area);
      const peak = a.tod.indexOf(Math.max(...a.tod));
      return { area: a.area, lat: c.lat, lng: c.lng, places: a.places, stops: Math.round(a.stops), fuel: Math.round(a.fuel), food: Math.round(a.food), other: Math.round(a.other),
        bySlot: a.tod.map((x) => Math.round(x)), peak: peak >= 0 ? `${peak * 4}:00-${peak * 4 + 4}:00` : null };
    }).sort((a, b) => b.stops - a.stops).slice(0, 50);
    await this.put('stopDemand', { k, list });
    return list;
  }

  /** Per rider hash over the last 30 days of raw rows: events / km. Stores counts per bucket only. */
  async computeRisk({ signal, now = this.clock() } = {}) {
    const since = now - 30 * M.DAY;
    const per = new Map();
    let scanned = 0;
    for (let page = 0; page < 20; page++) {
      const rows = await this.soda.query(RAW, { t: { $gte: since } }, { limit: 1000, offset: page * 1000 });
      for (const r of rows) {
        const v = r.value;
        if (!v || !v.rh || v.p === 2) continue;
        const x = per.get(v.rh) || { ev: 0, km: 0 };
        if (v.k === 'evs') for (const e of (v.d?.e || [])) { if (RISK_TYPES.has(e[0])) x.ev++; }
        else if (v.k === 'ride') for (const c of (v.d?.c || [])) x.km += (Number(c[2]) || 0) / 1000;
        per.set(v.rh, x);
        scanned++;
      }
      if (rows.length < 1000 || signal?.aborted) break;
      await M.yieldNow();
    }
    const counts = { low: 0, medium: 0, high: 0 };
    let riders = 0;
    for (const x of per.values()) { const b = riskBucket(x.ev, x.km); if (!b) continue; counts[b.bucket]++; riders++; }
    const k = this.k;
    const doc = riders >= k ? { k, riders, counts, windowDays: 30, scanned } : { k, riders: 0, counts: null, windowDays: 30, scanned, note: `Fewer than ${k} riders with 50 km or more: not shown.` };
    await this.put('risk', doc);
    return riders;
  }

  /** One rider (MASTER_ADMIN, audited by the caller): from that rider's own raw rows of the last 90 days. */
  async riderRisk(userId, { now = this.clock() } = {}) {
    const rows = await this.engine.exportContributions(userId, { now });
    let ev = 0, km = 0, sos = 0, crash = 0;
    const byType = {};
    for (const r of rows) {
      if (r.kind === 'evs') for (const e of (r.data?.e || [])) { byType[e[0]] = (byType[e[0]] || 0) + 1; if (RISK_TYPES.has(e[0])) ev++; if (e[0] === 'sos') sos++; if (e[0] === 'crash') crash++; }
      else if (r.kind === 'ride') for (const c of (r.data?.c || [])) km += (Number(c[2]) || 0) / 1000;
    }
    const b = riskBucket(ev, km);
    return { windowDays: this.engine.cfg.rawDays, km: Math.round(km), events: ev, byType, sos, crash, rate: b ? b.rate : null, bucket: b ? b.bucket : 'not enough riding',
      note: 'Only rides with "Help make roads safer" on. A signal for a conversation, never an automatic action.' };
  }

  // ------------------------------------------------------------------ route difficulty (any signed-in rider)
  async routeDifficulty(line, { departAt = this.clock(), avgKmh = 40, now = this.clock() } = {}) {
    const e = this.engine, k = e.cfg.kMin, H = e.cfg.halfLifeDays;
    let km = 0;
    for (let i = 1; i < line.length; i++) km += M.haversine(line[i - 1].lat, line[i - 1].lng, line[i].lat, line[i].lng) / 1000;
    // Sample about every 1 km (at most 1500 samples).
    const samples = [];
    const stepKm = Math.max(1, km / 1500);
    let acc = stepKm;
    for (let i = 1; i < line.length; i++) {
      acc += M.haversine(line[i - 1].lat, line[i - 1].lng, line[i].lat, line[i].lng) / 1000;
      if (acc >= stepKm) { samples.push(line[i]); acc = 0; }
    }
    if (line.length) samples.unshift(line[0]);
    const tiles = new Set(samples.map((p) => gh.encode(p.lat, p.lng, 4)));
    const rd = new Map(), rq = new Map(), hz = new Map();
    if (tiles.size <= 400) {
      for (const t of tiles) {
        for (const v of await e._tile('rd', t)) if (e.riders(v, now) >= k) rd.set(v.cell, v);
        for (const v of await e._tile('rq', t)) if (e.riders(v, now) >= k) rq.set(v.cell, v);
        for (const v of await e._tile('hz', t)) if (e.riders(v, now) >= k) hz.set(v.cell, v);
      }
    }
    let twistyKm = 0, ghatKm = 0, roughKm = 0;
    const hzSeen = new Set();
    for (const p of samples) {
      const r = rd.get(gh.encode(p.lat, p.lng, 6));
      const tw = r ? e.twistScore(r, now) : null;
      if (tw && tw.score >= 30) twistyKm += stepKm;
      if (tw && tw.score >= 50) ghatKm += stepKm;
      const g7 = gh.encode(p.lat, p.lng, 7);
      const q = rq.get(g7);
      if (q && e._scored(q, now).total >= 2) roughKm += stepKm;
      const h = hz.get(g7);
      if (h && e._scored(h, now).total >= 3) hzSeen.add(g7);
    }
    void H;
    const hours = km / avgKmh;
    const nightShare = nightShareOf(Number(departAt), hours);
    const d = difficultyOf({ km, twistyKm, ghatKm, roughKm, hazards: hzSeen.size, nightShare });
    return { ...d, km: Math.round(km), parts: { twistyKm: Math.round(twistyKm), ghatKm: Math.round(ghatKm), roughKm: Math.round(roughKm), hazards: hzSeen.size, nightShare: Math.round(nightShare * 100) },
      basedOn: 'CoRoute riders (anonymous, k-anonymous cells)', coverage: rd.size ? 'riders' : 'little data yet' };
  }
}

module.exports = { IntelInsights, corridorsOf, difficultyOf, nightShareOf, riskBucket, neighbours, COLL };
