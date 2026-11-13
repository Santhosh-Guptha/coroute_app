'use strict';
/** Small shared maths for the intelligence: buckets, decay, distances. Pure. */
const DAY = 86400000;
const IST = 330 * 60000;
const R = 6371000;
const rad = (d) => (d * Math.PI) / 180;

function haversine(aLat, aLng, bLat, bLng) {
  const dLat = rad(bLat - aLat), dLng = rad(bLng - aLng);
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(rad(aLat)) * Math.cos(rad(bLat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(x)));
}

function bearing(aLat, aLng, bLat, bLng) {
  const y = Math.sin(rad(bLng - aLng)) * Math.cos(rad(bLat));
  const x = Math.cos(rad(aLat)) * Math.sin(rad(bLat)) - Math.sin(rad(aLat)) * Math.cos(rad(bLat)) * Math.cos(rad(bLng - aLng));
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}

function angleDiff(a, b) {
  const d = (((a - b) % 360) + 360) % 360;
  return d > 180 ? 360 - d : d;
}

/** 8 heading buckets of 45 degrees (0 = north ±22.5); -1 when unknown. */
function headingBucket(deg) {
  const d = Number(deg);
  if (!Number.isFinite(d) || d < 0) return -1;
  return Math.round((d % 360) / 45) % 8;
}

/** Coarse speed buckets: 0 <20, 1 20-40, 2 40-60, 3 60-80, 4 >=80 km/h. */
function speedBucket(kmh) {
  const v = Number(kmh);
  if (!Number.isFinite(v) || v < 0) return -1;
  return Math.min(4, Math.floor(v / 20));
}

/** India local time parts (all intelligence buckets use IST: the riders are in India). */
function istParts(t) {
  const d = new Date(Number(t) + IST);
  return { dow: d.getUTCDay(), hour: d.getUTCHours() };
}

/** 0..167, Monday 00:00 IST = 0. */
function hourOfWeek(t) {
  const { dow, hour } = istParts(t);
  return ((dow + 6) % 7) * 24 + hour;
}

/** 'w' weekday, 'e' weekend (Sat/Sun). */
function dayType(t) {
  const { dow } = istParts(t);
  return dow === 0 || dow === 6 ? 'e' : 'w';
}

/** 12 coarse ETA buckets: 6 four-hour blocks × weekday/weekend. */
function timeBucket(t) {
  const { hour } = istParts(t);
  return (dayType(t) === 'e' ? 6 : 0) + Math.floor(hour / 4);
}

/** Value decayed from time `from` to time `to` with a half-life in days (never grows for to < from). */
function decay(value, from, to, halfLifeDays) {
  const v = Number(value) || 0;
  if (!v) return 0;
  const dt = Math.max(0, Number(to) - Number(from));
  return v * 2 ** (-dt / (halfLifeDays * DAY));
}

/** India month key 'YYYY-MM' (hash rotation and k-anonymity window). */
function monthKey(t) {
  const d = new Date(Number(t) + IST);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
}

/** The month keys of the last `n` months ending with t's month (for delete-my-contributions). */
function recentMonths(t, n) {
  const d = new Date(Number(t) + IST);
  const out = [];
  let y = d.getUTCFullYear(), m = d.getUTCMonth();
  for (let i = 0; i < n; i++) {
    out.push(`${y}-${String(m + 1).padStart(2, '0')}`);
    m--; if (m < 0) { m = 11; y--; }
  }
  return out;
}

/** Bounded insertion-ordered map with LRU touch on get. */
class Lru {
  constructor(max) { this.max = max; this.map = new Map(); }
  get size() { return this.map.size; }
  get(k) { const v = this.map.get(k); if (v !== undefined) { this.map.delete(k); this.map.set(k, v); } return v; }
  peek(k) { return this.map.get(k); }
  has(k) { return this.map.has(k); }
  set(k, v) {
    this.map.delete(k); this.map.set(k, v);
    const evicted = [];
    while (this.map.size > this.max) { const [ek, ev] = this.map.entries().next().value; this.map.delete(ek); evicted.push([ek, ev]); }
    return evicted;
  }
  delete(k) { return this.map.delete(k); }
  clear() { this.map.clear(); }
  keys() { return this.map.keys(); }
  values() { return this.map.values(); }
  entries() { return this.map.entries(); }
}

/** Gives the event loop a turn (live traffic first). */
const yieldNow = () => new Promise((r) => setImmediate(r));

module.exports = { DAY, IST, haversine, bearing, angleDiff, headingBucket, speedBucket, hourOfWeek, dayType, timeBucket, istParts, decay, monthKey, recentMonths, Lru, yieldNow };
