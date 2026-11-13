'use strict';
/**
 * Round 8 compact position frames, protocol 'pos2' (HIGH_TRAFFIC_PLAN_v3.57 item 4). Versioned like 'posbatch1':
 * the gateway lists 'pos2' in HELLO.features; an app that understands it
 *   - sends its positions as P2 frames instead of TELEMETRY JSON, and
 *   - announces 'pos2' in its JOIN caps, so the position fan-out to that socket is RU2 frames.
 * Old apps never see either (they keep TELEMETRY / RIDER_UPDATE / RIDER_UPDATES exactly as before).
 *
 * Phone -> gateway (JSON text frame, short keys, integers only):
 *   { "t":"P2", "q":seq, "a":lat*1e5, "o":lng*1e5, "v":speed dm/s, "h":heading deg, "b":battery %,
 *     "c":1 (charging), "sr":statusReason, "sm":statusMessage, "ss":seconds stopped, "fu":[usableKm, confirmedAt s],
 *     "fl":fatigue 0..3 }
 *   Optional deltas: a frame may carry "k":<seq of the last full fix> with "da"/"do" (lat/lng minus that fix's a/o)
 *   instead of a/o. The gateway keeps the last full fix per socket; a delta whose k is not that fix is ignored
 *   (the phone sends a full fix at least every 10 frames, after every (re)JOIN and on any jump > ~500 m).
 *   Full-state semantics, like the app's TELEMETRY: a missing sr/sm/ss/c/fu means ''/''/0/false/none.
 *   A missing b or fl means "unchanged".
 *
 * Gateway -> phone (only to sockets with the 'pos2' cap):
 *   { "type":"RU2", "ts":serverTime, "r":[ { "u":userId, "a", "o", "v", "h", "b", "c"?, "sr"?, "sm"?, "ss"?, "t":last seen (server
 *     epoch ms, like RIDER_UPDATE.lastSeenEpochMs), "fu"?, "fl"? }, ... ] }
 *   Telemetry fields only: names, roles, bikes and contact fields come with SNAPSHOT / roster events as before, and the
 *   app merges an RU2 entry into the rider it already knows (an unknown rider is skipped until the next SNAPSHOT).
 *
 * Sizes (measured, docs/quality/ROUND8_REALTIME_NOTES.md): a RIDER_UPDATE is ~700 bytes (the whole public rider:
 * name, bike, contact fields), an RU2 entry ~85 bytes (a one-rider RU2 frame ~125); the app's TELEMETRY ~240 bytes,
 * a P2 ~65. Deltas save nothing in JSON once the coordinates are integers (the "k" key costs what "da"/"do" save),
 * so the app sends full fixes; the delta form stays accepted for a future binary encoding.
 */

const POS2_CAP = 'pos2';
const E5 = 1e5;
const KMH_PER_DMS = 0.36; // 1 dm/s = 0.36 km/h

const isInt = (v) => typeof v === 'number' && Number.isInteger(v);
const clampInt = (v, lo, hi) => Math.max(lo, Math.min(hi, Math.round(v)));

/**
 * One P2 frame -> a telemetry patch for ConvoyManager.patchRider, using and updating `state` (per socket:
 * { k, a, o } = the last full fix). Returns { patch } | { miss: true } (delta without its base) | null (invalid).
 */
function decodeP2(m, state = {}, now = Date.now()) {
  if (!m || typeof m !== 'object') return null;
  const q = isInt(m.q) && m.q >= 0 ? m.q : null;
  let a; let o;
  if (isInt(m.a) && isInt(m.o)) {
    a = m.a; o = m.o;
    if (Math.abs(a) > 90 * E5 || Math.abs(o) > 180 * E5) return null;
    if (q !== null) { state.k = q; state.a = a; state.o = o; } else { state.k = null; }
  } else if (isInt(m.da) && isInt(m.do) && isInt(m.k)) {
    if (state.k === undefined || state.k === null || state.k !== m.k) return { miss: true };
    a = state.a + m.da; o = state.o + m.do;
    if (Math.abs(a) > 90 * E5 || Math.abs(o) > 180 * E5) return null;
  } else {
    return null;
  }
  const patch = { lat: a / E5, lng: o / E5 };
  if (m.v !== undefined) { if (typeof m.v !== 'number' || !Number.isFinite(m.v)) return null; patch.speedKmh = Math.round(clampInt(m.v, 0, 1000) * KMH_PER_DMS * 10) / 10; }
  if (m.h !== undefined) { if (typeof m.h !== 'number' || !Number.isFinite(m.h)) return null; patch.heading = ((Math.round(m.h) % 360) + 360) % 360; }
  if (m.b !== undefined && m.b !== null) { if (typeof m.b !== 'number' || !Number.isFinite(m.b)) return null; patch.batteryLevel = clampInt(m.b, 0, 100); }
  patch.isCharging = m.c === 1 || m.c === true;
  patch.statusReason = typeof m.sr === 'string' ? m.sr.slice(0, 24) : '';
  patch.statusMessage = typeof m.sm === 'string' ? m.sm.slice(0, 140) : '';
  patch.stoppedSince = typeof m.ss === 'number' && Number.isFinite(m.ss) && m.ss > 0 ? Math.max(0, now - Math.round(Math.min(m.ss, 7 * 86400)) * 1000) : 0;
  if (Array.isArray(m.fu) && m.fu.length === 2 && Number.isFinite(m.fu[0]) && Number.isFinite(m.fu[1])) {
    patch.fuelEstimate = { usableKm: m.fu[0], confirmedAt: Math.round(m.fu[1]) * 1000 };
  } else {
    patch.fuelEstimate = null;
  }
  if (isInt(m.fl)) patch.fatigueLevel = m.fl;
  return { patch };
}

/** Phone side (reference / tests / tool/load): a telemetry object -> P2 frame (full fix). */
function encodeP2(p, seq = 0, now = Date.now()) {
  const f = { t: 'P2', q: seq >>> 0, a: Math.round(Number(p.lat) * E5), o: Math.round(Number(p.lng) * E5) };
  f.v = clampInt((Number(p.speedKmh) || 0) / KMH_PER_DMS, 0, 1000);
  f.h = ((Math.round(Number(p.heading) || 0) % 360) + 360) % 360;
  if (p.batteryLevel !== undefined && p.batteryLevel !== null) f.b = clampInt(Number(p.batteryLevel), 0, 100);
  if (p.isCharging) f.c = 1;
  if (p.statusReason) f.sr = String(p.statusReason).slice(0, 24);
  if (p.statusMessage) f.sm = String(p.statusMessage).slice(0, 140);
  if (Number(p.stoppedSince) > 0) f.ss = Math.max(0, Math.round((now - Number(p.stoppedSince)) / 1000));
  if (p.fuelEstimate && Number.isFinite(p.fuelEstimate.usableKm)) f.fu = [Math.floor(p.fuelEstimate.usableKm), Math.round((p.fuelEstimate.confirmedAt || 0) / 1000)];
  if (Number.isInteger(p.fatigueLevel)) f.fl = p.fatigueLevel;
  return f;
}

/** Phone side: a delta frame against the full fix `key` ({ q, a, o }). */
function encodeP2Delta(p, seq, key, now = Date.now()) {
  const full = encodeP2(p, seq, now);
  const d = { ...full, k: key.q, da: full.a - key.a, do: full.o - key.o };
  delete d.a; delete d.o;
  return d;
}

/** A public rider (publicRider()) -> one RU2 entry (string, ready to join). */
function riderEntry(r, ts = Date.now()) {
  const e = {
    u: r.userId,
    a: Math.round((Number(r.lat) || 0) * E5),
    o: Math.round((Number(r.lng) || 0) * E5),
    v: clampInt((Number(r.speedKmh) || 0) / KMH_PER_DMS, 0, 1000),
    h: ((Math.round(Number(r.heading) || 0) % 360) + 360) % 360,
    b: r.batteryLevel ?? 100,
  };
  if (r.isCharging) e.c = 1;
  if (r.statusReason) e.sr = r.statusReason;
  if (r.statusMessage) e.sm = r.statusMessage;
  if (Number(r.stoppedSince) > 0) e.ss = Math.max(0, Math.round((ts - Number(r.stoppedSince)) / 1000));
  // Absolute (server time): an entry built now may go out in a later flush (coalescing, interest refresh).
  e.t = Number(r.lastSeenEpochMs) || ts;
  if (r.fuelEstimate && Number.isFinite(r.fuelEstimate.usableKm)) e.fu = [r.fuelEstimate.usableKm, Math.round((r.fuelEstimate.confirmedAt || 0) / 1000)];
  if (r.fatigueLevel) e.fl = r.fatigueLevel;
  return JSON.stringify(e);
}

/** RU2 frame from entry strings. */
function ru2Frame(entries, ts = Date.now()) { return `{"type":"RU2","ts":${ts},"r":[${entries.join(',')}]}`; }

/** Phone side (reference / tests): RU2 entry merged into the rider the app already knows. */
function applyEntry(known, e, ts) {
  if (!known || !e) return null;
  const out = { ...known, lat: e.a / E5, lng: e.o / E5, speedKmh: Math.round(e.v * KMH_PER_DMS * 10) / 10, heading: e.h };
  if (e.b !== undefined) out.batteryLevel = e.b;
  out.isCharging = e.c === 1;
  out.statusReason = e.sr || '';
  out.statusMessage = e.sm || '';
  out.stoppedSince = e.ss ? ts - e.ss * 1000 : 0;
  out.lastSeenEpochMs = Number.isFinite(e.t) ? e.t : ts;
  out.fuelEstimate = Array.isArray(e.fu) ? { usableKm: e.fu[0], confirmedAt: e.fu[1] * 1000, updatedAt: out.lastSeenEpochMs } : null;
  out.fatigueLevel = e.fl || 0;
  return out;
}

module.exports = { POS2_CAP, decodeP2, encodeP2, encodeP2Delta, riderEntry, ru2Frame, applyEntry, E5, KMH_PER_DMS };
