'use strict';
/**
 * Shared helpers for the round 4 intelligence tests (test/intel_*_356.test.js): an IntelEngine on MemorySoda with a
 * hand-driven clock, consenting riders, and synthetic rides (straight, zig-zag, with stops). Not a test file.
 */
const { MemorySoda } = require('../src/oracle/memory_soda');
const { IntelEngine } = require('../src/intel/engine');

const quiet = { info() {}, warn() {}, error() {} };
const T0 = Date.UTC(2026, 10, 10, 4, 30); // Tue 10 Nov 2026, 10:00 IST

function makeEngine(opts = {}) {
  const soda = opts.soda || new MemorySoda();
  const clock = { now: opts.t0 || T0 };
  const engine = new IntelEngine({ soda, logger: quiet, clock: () => clock.now, jwtSecret: 'test-secret-test-secret-test-secret-1234', ...opts.engine });
  return { soda, clock, engine };
}

/** Moves `meters` from (lat,lng) on bearing `deg` (flat earth; fine for test distances). */
function move(lat, lng, deg, meters) {
  const r = (deg * Math.PI) / 180;
  return { lat: lat + (Math.cos(r) * meters) / 111320, lng: lng + (Math.sin(r) * meters) / (111320 * Math.cos((lat * Math.PI) / 180)) };
}

/**
 * Feeds a ride to engine.onTelemetry: legs = [{ deg, km, kmh, wiggle? }, { stopMin }...], one fix every stepS seconds.
 * wiggle: degrees of alternating heading change (zig-zag = twisty road). Returns the end position.
 */
function ride(env, { gid = 'G1', userId, start = { lat: 12.9716, lng: 77.5946 }, legs, stepS = 2 }) {
  let p = { ...start };
  let i = 0;
  const send = () => env.engine.onTelemetry(gid, { userId, lat: p.lat, lng: p.lng, speedKmh: 0 });
  send();
  for (const leg of legs) {
    if (leg.stopMin) {
      const n = Math.round((leg.stopMin * 60) / 30);
      for (let k = 0; k < n; k++) { env.clock.now += 30000; send(); } // a parked phone reports every 30 s
      continue;
    }
    const stepM = (leg.kmh / 3.6) * stepS;
    const steps = Math.round((leg.km * 1000) / stepM);
    for (let k = 0; k < steps; k++) {
      const deg = leg.deg + (leg.wiggle ? (i++ % 2 === 0 ? leg.wiggle : -leg.wiggle) : 0);
      p = move(p.lat, p.lng, deg, stepM);
      env.clock.now += stepS * 1000;
      send();
    }
  }
  return p;
}

async function consentAll(env, ids, on = true) { for (const id of ids) await env.engine.consent.set(id, on); }

module.exports = { makeEngine, ride, move, consentAll, quiet, T0 };
