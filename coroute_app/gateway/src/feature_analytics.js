 'use strict';
const { EventEmitter } = require('events');
const FEATURES = ['essentials', 'guardian', 'weather', 'route', 'places', 'trips', 'voice', 'safety', 'configuration'];
/** Process-local operational counters. No user IDs, paths, coordinates or payloads. */
class FeatureAnalytics extends EventEmitter {
  constructor(clock = Date.now) { super(); this.clock = clock; this.startedAt = clock(); this.rows = new Map(); }
  record(feature, success, elapsedMs = 0) {
    if (!FEATURES.includes(feature)) return;
    const row = this.rows.get(feature) || { requests: 0, succeeded: 0, failed: 0, totalMs: 0, lastAt: 0 };
    row.requests++; row[success ? 'succeeded' : 'failed']++;
    row.totalMs += Number.isFinite(elapsedMs) ? Math.max(0, Math.min(elapsedMs, 120000)) : 0;
    row.lastAt = this.clock(); this.rows.set(feature, row); this.emit('change');
  }
  snapshot() {
    return { generatedAt: this.clock(), startedAt: this.startedAt, scope: 'this_gateway_process',
      features: FEATURES.map(feature => { const r = this.rows.get(feature);
        return { feature, measured: !!r, requests: r?.requests || 0, succeeded: r?.succeeded || 0,
          failed: r?.failed || 0, averageMs: r ? Math.round(r.totalMs / r.requests) : null, lastAt: r?.lastAt || null }; }) };
  }
}
module.exports = { FeatureAnalytics };
