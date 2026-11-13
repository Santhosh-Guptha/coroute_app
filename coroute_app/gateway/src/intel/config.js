'use strict';
/**
 * Road & safety intelligence settings (docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md). Read from the
 * environment on each call (cheap), so a test can change them between cases.
 *
 * Collection happens only for riders who turned on "Help make roads safer"; warnings are read by everyone.
 */
const num = (env, k, def, lo, hi) => {
  const v = Number(env[k]);
  if (env[k] === undefined || env[k] === '' || !Number.isFinite(v)) return def;
  return Math.min(hi, Math.max(lo, v));
};
const bool = (env, k, def) => {
  const v = String(env[k] ?? '').trim().toLowerCase();
  if (!v) return def;
  return !['0', 'false', 'off', 'no'].includes(v);
};

function intelConfig(env = process.env) {
  const router = String(env.ROUTER_KIND || 'osrm').trim().toLowerCase();
  const mode = String(env.CRASH_BRAIN_MODE || 'shadow').trim().toLowerCase();
  return {
    /** Master switch for collection AND the intel API (warnings answer empty when off). */
    enabled: bool(env, 'INTEL_ENABLED', true),
    /** Emergency kill switch: stops collection and aggregation at once, reads answer empty. */
    killed: bool(env, 'INTEL_KILL', false),
    kMin: Math.round(num(env, 'INTEL_K_MIN', 5, 2, 100)),
    rawDays: Math.round(num(env, 'INTEL_RAW_DAYS', 90, 7, 365)),
    halfLifeDays: num(env, 'INTEL_HALF_LIFE_DAYS', 90, 7, 730),
    trimM: num(env, 'INTEL_TRIM_M', 300, 100, 2000),
    crashBrainMode: ['shadow', 'approved', 'off'].includes(mode) ? mode : 'shadow',
    crashBrainMinLabels: Math.round(num(env, 'CRASH_BRAIN_MIN_LABELS', 200, 200, 100000)), // never below 200
    routerKind: ['osrm', 'valhalla'].includes(router) ? router : 'osrm',
    fuelGapKm: num(env, 'FUEL_GAP_KM', 80, 20, 400),
    etaMin: 0.6,
    etaMax: 1.6,
    maxAccumulators: Math.round(num(env, 'INTEL_MAX_ACCUMULATORS', 500, 10, 20000)),
    maxCellsPerRide: Math.round(num(env, 'INTEL_MAX_CELLS_PER_RIDE', 200, 20, 2000)),
    jobMaxCells: Math.round(num(env, 'INTEL_JOB_MAX_CELLS', 2000, 50, 50000)),
    jobEveryMin: num(env, 'INTEL_JOB_EVERY_MIN', 5, 1, 60),
    cacheTtlMs: Math.round(num(env, 'INTEL_CACHE_TTL_S', 600, 5, 86400) * 1000),
    hashKey: String(env.INTEL_HASH_KEY || '').trim(),
  };
}

/** Collection is allowed (still per rider: consent). */
function collecting(cfg = intelConfig()) { return cfg.enabled && !cfg.killed; }

module.exports = { intelConfig, collecting };
